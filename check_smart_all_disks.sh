#!/bin/bash

#
# https://github.com/svamberg/check_smart_all_disks
#


SMARTCHECK=/usr/local/lib/nagios/plugins/check_smart.zcu.pl
DEBUG=1
OPTIONS=$@
NAG_RETURN=0 # default OK
OUTPUT=""
PERFORMANCE=""

echoerr() { echo "$@" 1>&2; }

check_disk() {
	device=$1
	subdisk=$3
	interface=$2
	if [ -z "$subdisk" ] ; then
		shortdev=`awk -F '/' '{print $NF}' <<< $1`
		smartcmd="$SMARTCHECK -i $interface -d $device $OPTIONS"
	else
		shortdev=`awk -F '/' '{print $NF"-'$subdisk'"}' <<< $1`
		smartcmd="$SMARTCHECK -i $interface,$subdisk -d $device $OPTIONS"
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
	serial=`lsblk --nodeps -o serial -n $device`
	status=`sudo /usr/sbin/megaclisas-status`

	if grep -q "$serial" <<< $status ; then 
		for i in `echo $status | awk '/Drive Model/{y=1;next}y' | awk -F '|' '{print $9}' | grep -v 'Unknown'`; do
			check_disk $device megaraid $i
		done
	else
		# this device is JBOD
		check_disk $device scsi
	fi
}

# ---------------------------------------------------------------------

while IFS='#' read -d '#' -r i; do
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: input line: $i"
	device=`awk -F ':' '{print $1}' <<< $i`
	drivers=`awk -F ':' '{print $2}' <<< $i`
	shortdev=`awk -F '/' '{print $NF}' <<< $device`
	
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: device: $device"
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: drivers: $drivers"
	case "$drivers" in
		*megaraid*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is megaraid (test all connected devices)"
			if egrep -q "^$shortdev(,\\d+)? OK" <<< $OUTPUT ; then
				[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device checked before, skipping"
			else
				# this device is not checked,  
				device_megaraid $device
			fi
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
		*usb-storage*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is usb-storage (skipping)"
			# skipping - smart is not exists on this device
			;;
		*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is UNKNOWN"
			echo "$device has unknown drivers: $drivers"
			NAG_RETURN=4
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

echo "$OUTPUT | $PERFORMANCE"
exit $NAG_RETURN


