#!/bin/bash

#
# https://github.com/svamberg/check_smart_all_disks
#


SMARTCHECK=/usr/local/lib/nagios/plugins/check_smart.zcu.pl
DEBUG=0
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
	PERFORMANCE="$PERFORMANCE $perf"
	
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
	for i in `sudo /usr/sbin/megaclisas-status  | awk '/Drive Model/{y=1;next}y' | awk -F '|' '{print $9}'`; do
		check_disk $1 megaraid $i
	done

}

# ---------------------------------------------------------------------

megaraid_run=0
while IFS= read i; do
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: input line: $i"
	device=`awk -F ':' '{print $1}' <<< $i`
	drivers=`awk -F ':' '{print $2}' <<< $i`
	
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: device: $device"
	[ $DEBUG -ne 0 ] && echoerr "DEBUG: drivers: $drivers"
	case "$drivers" in
		*megaraid*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is megaraid"
			if [ $megaraid_run -eq 0 ] ; then
				device_megaraid $device
				megaraid_run=1
			fi
			;;
		*ahci*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is ahci"
			check_disk $device sat
			;;
		*qla2xxx*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is fibrechannel"
			# preskakujeme, na FC nema smysl kontrolovat SMART
			;;
		*mptsas*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is mptsas"
			check_disk $device scsi
			;;
		*)
			[ $DEBUG -ne 0 ] && echoerr "DEBUG: $device is UNKNOWN"
			echo "$device: unknown drivers: '$driver'"
			NAG_RETURN=4
			;;
	esac

done <<< `/usr/sbin/hwinfo --disk | grep -E 'Device File:|Driver:' | awk 'NR%2{printf "%s =",$0;next;}1' | sed -r 's/\(.*\)//g' | sed -r 's/"//g' | awk -F ':|=' '{print $4":"$2}'`

# printing output

[ $DEBUG -ne 0 ] && echoerr "RETURN CODE: $NAG_RETURN"
[ $DEBUG -ne 0 ] && echoerr "INFO LINE: $OUTPUT"
[ $DEBUG -ne 0 ] && echoerr "PERFORMANCE: $PERFORMANCE"

echo "$OUTPUT | $PERFORMANCE"
exit $NAG_RETURN


