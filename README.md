# check_smart_all_disks.sh

## Requirements
Needs `blkid`, `udevadm`, `sudo`, `smartctl`, `grep`, `bash` and `awk`.

Debian:
`apt-get install util-linux udev sudo smartmontools grep bash awk`

### If you used megaraid controller
You need also megaraid tools `megacli` and `megaclisas-status`.

Debian:
Set APT sources list by http://hwraid.le-vert.net/wiki/DebianPackages
```
apt-get update
apt-get install megacli megaclisas-status
```

## Install
```
cd /tmp
git clone https://github.com/svamberg/check_smart_all_disks
cp /tmp/check_smart_all_disks/check* /usr/local/lib/nagios/plugins/
```

## Setup
```
cat <<EOF > /etc/sudoers.d/check_smart
nagios ALL=(root) NOPASSWD: /usr/sbin/megaclisas-status
nagios ALL=(root) NOPASSWD: /usr/sbin/smartctl
EOF 
chmod 0440 /etc/sudoers.d/check_smart`
```
  
## Usage
Use as plugin in Icinga/Nagios and call as nagios user (or change sudo):
`/usr/local/lib/nagios/plugins/check_smart_all_disks.sh`

You can pass aditional option to `check_smart.zcu.pl`,
please use `-h` option for full help and examples.

## Examples
On megaraid device /dev/sdd with RAID5 from 4 disks:
```
$ /usr/local/lib/nagios/plugins/check_smart_all_disks.sh
sdd-0 OK: no SMART errors detected.
sdd-1 OK: no SMART errors detected.
sdd-2 WARNING: No health status line found, Checksum failure
sdd-3 WARNING: No health status line found, Checksum failure | sdd-0:defect_list=44 sdd-0:sent_blocks=1055518705 sdd-0:temperature=36;;68 sdd-1:defect_list=18 sdd-1:sent_blocks=1823481300 sdd-1:temperature=36;;68
```

On mptsas controller with 2 single disks:
```
sda OK: no SMART errors detected.
sdb OK: no SMART errors detected. | sda:defect_list=156 sda:sent_blocks=1917395206 sda:temperature=25;;68 sdb:defect_list=118 sdb:sent_blocks=399633625 sdb:temperature=26;;68
```

# check_smart.zcu.pl
```
Usage:
check_smart.zcu.pl --device=<device> --interface=(ata|sat|scsi|[sat+]megaraid,N) [--realloc=<num>] [--pending=<num>] [--checksum] [--log] [--failure] [--debug] [--version] [--help]

  -d/--device     a device to be SMART monitored, eg. /dev/sda
  -i/--interface  ata, sat, scsi, megaraid, depending upon the device's interface type
  -r/--realloc    minimum of accepted reallocated sectors (actual value: 0)
  -p/--pending    minimum of accepted pending sectors (actual value: 0)
  -c/--checksum   disable checksum log structure (default: enable)
  -l/--log        disable check of SMART logs (default: enable)
  -f/--failure    disable warning when disk may be close to failure)
     --debug      show debugging information
  -h/--help       this help
  -v/--version    show version of this plugin

Examples:
  check_smart.zcu.pl --device=/dev/sda --interface=sat --realloc=10
  check_smart.zcu.pl -d /dev/sdb -i megaraid,2 -p 1 -l
```
