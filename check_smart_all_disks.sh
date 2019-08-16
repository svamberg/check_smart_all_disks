#!/bin/bash

#
# https://github.com/svamberg/check_smart_all_disks
#


SMARTCHECK=/usr/local/lib/nagios/plugins/check_smart.zcu.pl
#SMARTCHECK=./check_smart.zcu.pl
DEBUG=0
NAG_RETURN=0 # default OK
OUTPUT=""
PERFORMANCE=""

echoerr() { echo "$@" 1>&2; }


# ---------------------------------------------------------------------
format_options() {
	in=$1
	out=""

#	echo "DEBUG in=$in" >&2
	while IFS='#' read -d '#' -r i; do
#		echo "DEBUG: i=$i" >&2
		case $i in
			[di]:*|"")
				# matchs or empty options => skips	
				;;
			[rp]:*)
				# formating options with arguments
				i_tr=$(echo "$i" | tr ':' ' ');
				out="$out -$i_tr"
				;;
			[clf])
				# formating options without arguments
				out="$out -$i"
				;;
			*)
				echo "Unknown format of option -o with value '$1'." >&2
				exit 3
				;;
		esac
	done <<< $in
	echo $out 
}

parse_option() {
	device=$1
	subdisk=$3
	interface=$2
	smart_opts=""
	
	for i in ${opt_o[*]}; do
		#echo "DEBUG: $i - $device - $interface - $subdisk" >&2
		# d:device && (i:interface || i:interface,subdisk)
		if [[ $i =~ "#d:${device}#" ]] && { [[ $i =~ "#i:${interface}#" ]] || [[ $i =~ "#i:${interface},${subdisk}#" ]] ; } ; then
			smart_opts="${smart_opts} $(format_options ${i})"
		fi
		# d:device (not defined interface)
		if [[ $i =~ "#d:${device}#" ]] && [[ ! $i =~ "#i:".*"#" ]] ;  then
		#	echo "DEBUG: add $(format_options ${i}) from $i (dev: $device)" >&2
			smart_opts="${smart_opts} $(format_options ${i})"
		fi
		# i:interface (not defined device)
		if [[ ! $i =~ "#d:".*"#" ]] && { [[ $i =~ "#i:${interface}#" ]] || [[ $i =~ "#i:${interface},${subdisk}#" ]] ; } ; then
			smart_opts="${smart_opts} $(format_options ${i})"
		fi
	done

	# return string as options to smartctl
	echo $smart_opts
}


check_disk() {
	device=$1
	subdisk=$3
	interface=$2

	# get parameters from option -o
	args=$( parse_option $device $interface $subdisk )
	#echo -e "DEBUG: return \n$args"

	if [ -z "$subdisk" ] ; then
		shortdev=`awk -F '/' '{print $NF}' <<< $1`
		smartcmd="$SMARTCHECK -i $interface -d $device $args"
	else
		shortdev=`awk -F '/' '{print $NF"-'$subdisk'"}' <<< $1`
		smartcmd="$SMARTCHECK -i $interface,$subdisk -d $device $args"
	fi

	[ $DEBUG -ne 0 ] && echoerr "DEBUG: run smart: $smartcmd"
	out=`$smartcmd`
	ret=$?

	[ $DEBUG -ne 0 ] && echoerr "DEBUG: return value for $device on interface $interface,$subdisk is $ret"
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: return line: $out"
	
	[ "$ret" -gt "$NAG_RETURN" ] && NAG_RETURN=$ret


	perf=`echo "$out" | awk -F '|' '{print $2}' | awk 'BEGIN {ORS=" "}{for (fn=1;fn<=NF;fn++) {print "'$shortdev':"$fn}}'`
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: performance line: $perf"
	if [ -z "$PERFORMANCE" ] ; then
		PERFORMANCE="$perf"
	else
		PERFORMANCE="$PERFORMANCE$perf"
	fi
	
	info=`echo "$out" | awk -F '|' '{print $1}'`
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: info line: $shortdev $info"
	if [ -z "$OUTPUT" ]; then
		OUTPUT=`echo -e "$shortdev $info"`
	else
		OUTPUT=`echo -e "$OUTPUT\n$shortdev $info"`
	fi
		
}

# megaraid
device_megaraid() {
	device=$1
	shortdev=`awk -F '/' '{print $NF}' <<< $device`
	serial=`lsblk --nodeps -o serial -n $device`
	status=`sudo /usr/sbin/megaclisas-status`
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: serial on $device: $serial"
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: status on $device: $status"

	# at first check megaraid devices
	echo "$OUTPUT" | grep -q -P "^$shortdev(-[0-9]+)?\s+"
	if [ $? -eq 0 ]; then
		[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device checked before, skipping"
	else
		for i in `echo "$status" | awk '/Drive Model/{y=1;next}y' | tr -d ' ' | awk -F '|' '{print $1":"$9}' | grep -v 'Unknown'`; do
			id=${i%%:*} # disc ID, ex. c0u2p7
			lsi=${i##*:} # LSI ID of disc, ex. 25
			dev=`echo "$status" | grep $device | awk -F '|' '{print $1}' | tr -d ' '` # ID of
			if [[ $id =~ $dev ]]; then 
				check_disk $device megaraid $lsi
			fi
		done
	fi
	#if this device is JBOD (not found in OUTPUT again)
	echo "$OUTPUT" | grep -q -P "^$shortdev(-[0-9]+)?\s+"
	if [ $? -eq 0 ] ; then
		[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device checked before, skipping"
	else
		# SAT or SAS ?
		/usr/bin/sudo /usr/sbin/smartctl -i $device | grep -q 'SATA'
		if [ $? -eq 0 ] ; then
			check_disk $device sat
		else
			check_disk $device scsi
		fi
	fi

}

# usage
usage() {
	echo "$0 [-h] [-o 'device_options' [-o 'device_options']]"
	echo "  -h ... help"
	echo "  -o devices_option ... set specific device values"
	echo "     devices_option = <opt_char>:<value>[#<opt_char>:<value>[#...]]"
	echo "       opt_char: option from check_smart.zcu.pl"
        echo "       value:    value for option from check_smart.zcu.pl"
	echo "Notes:"
	echo "       Match options 'd' and 'i' control what disk mean for value settings."
        echo "       When using 'd:/dev/sda' (without 'i' option) then values matching to"
        echo "       to all disks mapped on /dev/sda (megaraid,0 ; megaraid,1 ; ...)"
	echo "Examples:"
	echo "  $0 -o 'd:/dev/sda#i:megaraid,2#r:4"
	echo "     sets minimum reallocated sectors to 4 on megaraid device /dev/sda at disk 2"
	echo "  $0 -o 'd:/dev/sdb#l#p:3"
	echo "     disable checking log and sets minimum pending sectors to 3 at device /dev/sdb"
	echo "  $0 -o 'd:/dev/sdc#c' -o 'd:/dev/sdd#f'"
	echo "     disabling checksum on /dev/sdc and disabling check of failure on /dev/sdd"
	echo "  $0 -o 'd:/dev/sdd#l' -o 'd:/dev/sdd#i:megaraid,2#c'"
	echo "     disabling logs on all disks at /dev/sdd plus disable checksum on megaraid,2 disk"
}

# --- read options ----------------------------------------------------
opt_o=()
while getopts "h:o:" opt; do
  case $opt in
    o)
	opt_o+=("#$OPTARG#")
      ;;
    h)
	echo "-h was triggered $OPTARG" >&2
	usage
	exit 0
      ;;
  esac
done

# ---------------------------------------------------------------------

while IFS='#' read -d '#' -r i; do
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: input line: $i"
	device=`awk -F ':' '{print $1}' <<< $i`
	drivers=`awk -F ':' '{print $2}' <<< $i`
	
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: device: $device"
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: drivers: $drivers"
	case "$drivers" in
		*megaraid*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is megaraid (test all connected devices)"
			device_megaraid $device
			;;
		*ahci*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is ahci (sat)"
			check_disk $device sat
			;;
		*aic7xxx*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is aic7xxx (scsi)"
			check_disk $device scsi
			;;
		*ata_piix*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is ata_piix (sat)"
			check_disk $device sat
			;;
		*floppy*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is floppy (skipping)"
			# skipping - this device has not SMART
			;;
		*qla2xxx*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is fibrechannel (skipping)"
			# skipping - smart is not exists on this device
			;;
		*mmcblk*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is mmcblk (skipping)"
			# skipping - smart is not exists on this device
			;;
		*mptsas*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is mptsas (scsi)"
			check_disk $device scsi
			;;
		*mpt2sas*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is mpt2sas (scsi)"
			check_disk $device scsi
			;;
		*mpt3sas*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is mpt3sas (scsi)"
			check_disk $device scsi
			;;
		*nvme*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is nvme (pcieport)"
			check_disk ${device::-3} nvme # delete last two chars: nvme0n1 -> nvme0
			;;
		*usb-storage*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is usb-storage (skipping)"
			# skipping - smart is not exists on this device
			;;
		*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is UNKNOWN"
			if [ ! -z $drivers ] ; then
				echo "$device has unknown drivers: '$drivers'"
				NAG_RETURN=4
			fi
			;;
	esac
# output format: device_name1 : driver1[,driver2[,driver3[, ...]]] # [... : ... #]
#       example: /dev/sdf : qla2xxx,sd # /dev/sdd : qla2xxx,sd # /dev/sdb : qla2xxx,sd # /dev/sdk : mptsas,sd #
#done <<< `/usr/sbin/hwinfo --disk | grep -E 'Device File:|Driver:' | awk 'NR%2{printf "%s =",$0;next;}1' | sed -r 's/\(.*\)//g' | sed -r 's/"//g' | awk -F ':|=' '{print $4":"$2}' | tr '\n' '#'`
done <<< `for i in \`lsblk -o KNAME,TYPE | grep disk | cut -d' ' -f 1\` ; do echo -n "/dev/$i : " ; udevadm info -a -n /dev/$i | grep -oP 'DRIVERS?=="\K[^"]+' | tr '\n' ',' ; echo -n ' # '  ;done`

# printing output

[ $DEBUG -ne 0 ] && echoerr "RETURN CODE: $NAG_RETURN"
[ $DEBUG -ne 0 ] && echoerr "INFO LINE: $OUTPUT"
[ $DEBUG -ne 0 ] && echoerr "PERFORMANCE: $PERFORMANCE"

if [ -t 1 ] ; then
	OUTPUT_FMT="$OUTPUT"
else
	#OUTPUT_FMT=`echo "$OUTPUT" | sed ':a;N;$!ba;s/\n/<br>/g'`
	OUTPUT_FMT="$OUTPUT"
fi

echo "$OUTPUT_FMT | $PERFORMANCE"
exit $NAG_RETURN


