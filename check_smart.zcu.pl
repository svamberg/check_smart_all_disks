#!/usr/bin/perl -w
# Check SMART status of ATA/SCSI disks, returning any usable metrics as perfdata.
# For usage information, run ./check_smart -h
#
# This script was created under contract for the US Government and is therefore Public Domain
#
# Add this line to /etc/sudoers: "nagios        ALL=(root) NOPASSWD: /usr/sbin/smartctl"
#
# Changes and Modifications
# =========================
# 1.0.0 Feb 3, 2009: Kurt Yoder
#       - initial version of script 1.0
# 1.0.1 Jan 27, 2010: Philippe Genonceaux
#       -  modifications for compatibility with megaraid, use smartmontool version >= 5.39 
# 1.0.2 Nov 26, 2012: Michal Svamberg
#       -  add support for 'sat' device type and some optimalizations for zcu.cz
# 1.0.3 - Feb 12, 2013: Unknown (very sorry)
#       - add documentation in POD format
# 1.0.4 May 3, 2014: Michal Svamberg 
#       - add check for reallocated sectors with limit (option -r)
#	- change parameter of smartctl from -A to -a (now get correct return code).
#       - fix return code: need divide return code from system() by 256 (or bits move '>> 8'), see example at 'perldoc -f system'
#	- new option -c disabling return code 0x04 for checksum of data structure
#       - new option -l disabling return code 0x40 with message 'Error log contains errors'
#       - add support interface 'sat+megaraid,N'
# 1.0.5 Jun 18, 2014: Michal Svamberg
#       - change default value of accepted reallocated sectors to 0 (zero)
#       - append inform messages if used -l, -r or -c option
# 1.0.6 Jun 7, 2015: Michal Svamberg
#       - add -p option as minimum of pending sectors 
# 1.0.7 Jun 29, 2015: Michal Svamberg
#       - add -f option to disable 'Disk may be close to failure' 


use strict;
use Getopt::Long;

use File::Basename qw(basename);
my $basename = basename($0);

my $revision = '1.0.7';

use lib '/usr/lib/nagios/plugins/';
use utils qw(%ERRORS &print_revision &support &usage);

$ENV{'PATH'}='/bin:/usr/bin:/sbin:/usr/sbin';
$ENV{'BASH_ENV'}=''; 
$ENV{'ENV'}='';

# global variables
use vars qw($opt_d $opt_debug $opt_h $opt_i $opt_n $opt_v $opt_realloc $opt_pending $opt_checksum $opt_log $opt_failure);
my $smart_command = '/usr/bin/sudo /usr/sbin/smartctl';
my @error_messages = qw//;
my $exit_status = 'OK';

# default values
$opt_realloc = "0"; 
$opt_pending = "0"; 

Getopt::Long::Configure('bundling');
GetOptions(
	                  "debug"       => \$opt_debug,
	"d=s" => \$opt_d, "device=s"    => \$opt_d,
	"h"   => \$opt_h, "help"        => \$opt_h,
	"i=s" => \$opt_i, "interface=s" => \$opt_i,
	"n=s" => \$opt_n, "number=s"	=> \$opt_n,
	"r=i" => \$opt_realloc, "realloc=i" => \$opt_realloc,
	"p=i" => \$opt_pending, "pending=i" => \$opt_pending,
	"c"   => \$opt_checksum, "checksum" => \$opt_checksum,
	"f"   => \$opt_failure,  "failure" => \$opt_failure,
	"l"   => \$opt_log, "log" => \$opt_log,
	"v"   => \$opt_v, "version"     => \$opt_v,
);

if ($opt_v) {
	print_revision($basename,$revision);
	exit $ERRORS{'OK'};
}

if ($opt_h) {
	print_help(); 
	exit $ERRORS{'OK'};
}

if ($opt_log) {
        push(@error_messages, 'Check of logs is disabled by -l option');
}

if ($opt_realloc) {
        push(@error_messages, "Used option -r=$opt_realloc (limit of reallocated sectors, default=0)");
}

if ($opt_pending) {
        push(@error_messages, "Used option -p=$opt_pending (limit of pending sectors, default=0)");
}

if ($opt_checksum) {
        push(@error_messages, 'Disabled checksum of internal SMART data structure (used option -c)');
}

if ($opt_failure) {
        push(@error_messages, 'Disabled warning when disk may be close to failure (used option -f)');
}

my ($device, $interface, $number) = qw//;
if ($opt_d) {
	unless($opt_i){
		print "must specify an interface for $opt_d using -i/--interface!\n\n";
		print_help();
		exit $ERRORS{'UNKNOWN'};
	}

	if (-b $opt_d){
		$device = $opt_d;
	}
	else{
		print "$opt_d is not a valid block device!\n\n";
		print_help();
		exit $ERRORS{'UNKNOWN'};
	}

	if(grep { $opt_i =~ /$_/ } ('ata','sat', 'scsi', 'megaraid,[0-9]+', 'sat+megaraid,[0-9]')){
		$interface = $opt_i;
#                if($interface eq 'megaraid'){
#                    if(defined($opt_n)){
#                        $number = $opt_n;
#                        $interface = $opt_i.",".$number;
#                    }
#                    else{
#                        print "must specify a physical disk number within the MegaRAID controller!\n\n";
#                        print_help();
#                        exit $ERRORS{'UNKNOWN'};
#                    }
#                }
	}
	else{
		print "invalid interface $opt_i for $opt_d!\n\n";
		print_help();
		exit $ERRORS{'UNKNOWN'};
	}
}
else{
	print "must specify a device!\n\n";
	print_help();
	exit $ERRORS{'UNKNOWN'};
}

warn "###########################################################\n" if $opt_debug;
warn "(debug) CHECK 1: getting overall SMART health status\n" if $opt_debug;
warn "###########################################################\n\n\n" if $opt_debug;

my $full_command = "$smart_command -d $interface -H $device";
warn "(debug) executing:\n$full_command\n\n" if $opt_debug;

my @output = `$full_command`;
warn "(debug) output:\n@output\n\n" if $opt_debug;

# parse ata output, looking for "health status: passed"
my $found_status = 0;
my $line_str = 'SMART overall-health self-assessment test result: '; # ATA SMART line
my $ok_str = 'PASSED'; # ATA SMART OK string
my $output_as_sat = 0;

if (!defined($number)) { $number = 0; }
if (($interface =~ /^megaraid,\d+$/) or ($interface eq 'scsi')){
	$line_str = 'SMART Health Status: '; # SCSI OR MEGARAID SMART line
	$ok_str = 'OK'; #SCSI OR MEGARAID SMART OK string
}

foreach my $line (@output){
        if ($line =~ /Device open changed type from 'megaraid(,\d+)?' to 'sat(\+megaraid(,\d+)?)?'/) {
                $line_str = 'SMART overall-health self-assessment test result: '; # ATA SMART line
                $ok_str = 'PASSED'; # ATA SMART OK string
                $output_as_sat = 1;
        }
	if($line =~ /$line_str(.+)/){
		$found_status = 1;
		warn "(debug) parsing line:\n$line\n\n" if $opt_debug;
		if ($1 eq $ok_str) {
			warn "(debug) found string '$ok_str'; status OK\n\n" if $opt_debug;
		}
		else {
			warn "(debug) no '$ok_str' status; failing\n\n" if $opt_debug;
			push(@error_messages, "Health status: $1");
			escalate_status('CRITICAL');
		}
	}
}

unless ($found_status) {
	push(@error_messages, 'No health status line found');
	escalate_status('UNKNOWN');
}


warn "###########################################################\n" if $opt_debug;
warn "(debug) CHECK 2: getting silent SMART health check\n" if $opt_debug;
warn "###########################################################\n\n\n" if $opt_debug;

#$full_command = "$smart_command -d $interface -q silent -A $device"; # -A return zero at any time
$full_command = "$smart_command -d $interface -q silent -a $device";
warn "(debug) executing:\n$full_command\n\n" if $opt_debug;

system($full_command);
my $return_code = ($? >> 8);

warn "(debug) exit code:\n$return_code\n\n" if $opt_debug;

if ($return_code & 0x01) {
	push(@error_messages, 'Command line parse failure');
	escalate_status('UNKNOWN');
}
if ($return_code & 0x02) {
	push(@error_messages, 'Device could not be opened');
	escalate_status('UNKNOWN');
}
if (($return_code & 0x04) && (!$opt_checksum)) {
	push(@error_messages, 'Checksum failure');
	escalate_status('WARNING');
}
if ($return_code & 0x08) {
	push(@error_messages, 'Disk is failing');
	escalate_status('CRITICAL');
}
if ($return_code & 0x10) {
	push(@error_messages, 'Disk is in prefail');
	escalate_status('WARNING');
}
if (($return_code & 0x20) && (!$opt_failure)) {
	push(@error_messages, 'Disk may be close to failure');
	escalate_status('WARNING');
}
if (($return_code & 0x40) && (!$opt_log)) {
	push(@error_messages, 'Error log contains errors');
	escalate_status('WARNING');
}
if ($return_code & 0x80) {
	push(@error_messages, 'Self-test log contains errors');
	escalate_status('WARNING');
}
if ($return_code && !$exit_status) {
	push(@error_messages, 'Unknown return code');
	escalate_status('CRITICAL');
}

if ($return_code) {
	warn "(debug) non-zero exit code, generating error condition\n\n" if $opt_debug;
}
else {
	warn "(debug) zero exit code, status OK\n\n" if $opt_debug;
}


warn "###########################################################\n" if $opt_debug;
warn "(debug) CHECK 3: getting detailed statistics\n" if $opt_debug;
warn "(debug) information contains a few more potential trouble spots\n" if $opt_debug;
warn "(debug) plus, we can also use the information for perfdata/graphing\n" if $opt_debug;
warn "###########################################################\n\n\n" if $opt_debug;

$full_command = "$smart_command -d $interface -A $device";
warn "(debug) executing:\n$full_command\n\n" if $opt_debug;
@output = `$full_command`;
warn "(debug) output:\n@output\n\n" if $opt_debug;
my @perfdata = qw//;

# separate metric-gathering and output analysis for ATA vs SCSI SMART output
if (($interface eq 'ata') or ($interface =~ /sat.*/) or $output_as_sat){
	foreach my $line(@output){
		# get lines that look like this:
		#    9 Power_On_Minutes        0x0032   241   241   000    Old_age   Always       -       113h+12m
		#    5 Reallocated_Sector_Ct   0x0033   100   100   036    Pre-fail  Always       -       16
		next unless $line =~ /^\s*\d+\s(\S+)\s+(?:\S+\s+){6}(\S+)\s+(\d+)/;
		my ($attribute_name, $when_failed, $raw_value) = ($1, $2, $3);
		if ($when_failed ne '-'){
			push(@error_messages, "Attribute $attribute_name failed at $when_failed");
			escalate_status('WARNING') if !$opt_failure;
			warn "(debug) parsed SMART attribute $attribute_name with error condition:\n$when_failed\n\n" if $opt_debug;
		}
		# some attributes produce questionable data; no need to graph them
		if (grep {$_ eq $attribute_name} ('Unknown_Attribute', 'Power_On_Minutes') ){
			next;
		}
		push (@perfdata, "$attribute_name=$raw_value");

		# do some manual checks
		if ( (($attribute_name eq 'Current_Pending_Sector') && $raw_value) && ($raw_value > $opt_pending) ) {
			push(@error_messages, "Sectors pending re-allocation = $raw_value (greater then $opt_pending)");
			escalate_status('WARNING');
			warn "(debug) Current_Pending_Sector is greater then $opt_pending ($raw_value)\n\n" if $opt_debug;
		}
		if ( (($attribute_name eq 'Reallocated_Sector_Ct') && $raw_value) && ($raw_value > $opt_realloc) ) {
			push(@error_messages, "Sectors re-allocation = $raw_value (greater then $opt_realloc)");
			escalate_status('WARNING');
			warn "(debug) Reallocated_Sector_Ct is greater then $opt_realloc ($raw_value)\n\n" if $opt_debug;
		}
	
	}
}
else{
	my ($current_temperature, $max_temperature, $current_start_stop, $max_start_stop) = qw//;
	foreach my $line(@output){
		if ($line =~ /Current Drive Temperature:\s+(\d+)/){
			$current_temperature = $1;
		}
		elsif ($line =~ /Drive Trip Temperature:\s+(\d+)/){
			$max_temperature = $1;
		}
		elsif ($line =~ /Current start stop count:\s+(\d+)/){
			$current_start_stop = $1;
		}
		elsif ($line =~ /Recommended maximum start stop count:\s+(\d+)/){
			$max_start_stop = $1;
		}
		elsif ($line =~ /Elements in grown defect list:\s+(\d+)/){
			push (@perfdata, "defect_list=$1");
		}
		elsif ($line =~ /Blocks sent to initiator =\s+(\d+)/){
			push (@perfdata, "sent_blocks=$1");
		}
	}
	if($current_temperature){
		if($max_temperature){
			push (@perfdata, "temperature=$current_temperature;;$max_temperature");
			if($current_temperature > $max_temperature){
				warn "(debug) Disk temperature is greater than max ($current_temperature > $max_temperature)\n\n" if $opt_debug;
				push(@error_messages, 'Disk temperature is higher than maximum');
				escalate_status('CRITICAL');
			}
		}
		else{
			push (@perfdata, "temperature=$current_temperature");
		}
	}
	if($current_start_stop){
		if($max_start_stop) {
			push (@perfdata, "start_stop=$current_start_stop;$max_start_stop");
			if($current_start_stop > $max_start_stop){
				warn "(debug) Disk start_stop is greater than max ($current_start_stop > $max_start_stop)\n\n" if $opt_debug;
				push(@error_messages, 'Disk start_stop is higher than maximum');
				escalate_status('WARNING');
			}
		}
		else{
			push (@perfdata, "start_stop=$current_start_stop");
		}
	}
}
warn "(debug) gathered perfdata:\n@perfdata\n\n" if $opt_debug;
my $perf_string = join(' ', @perfdata);

warn "###########################################################\n" if $opt_debug;
warn "(debug) FINAL STATUS: $exit_status\n" if $opt_debug;
warn "###########################################################\n\n\n" if $opt_debug;

warn "(debug) final status/output:\n" if $opt_debug;

my $status_string = '';

if($exit_status ne 'OK'){
	$status_string = "$exit_status: ".join(', ', @error_messages);
}
else {
	$status_string = "OK: no SMART errors detected";
        if ($opt_log) {
                $status_string = "$status_string, used option -l (disabled check of logs)";
        }
        if ($opt_realloc) {
                $status_string = "$status_string, used option -r=$opt_realloc (limit of realloc. sectors, default=0)";
        }
        if ($opt_pending) {
                $status_string = "$status_string, used option -p=$opt_pending (limit of pending sectors, default=0)";
        }
        if ($opt_checksum) {
                $status_string = "$status_string, used option -c (disabled check of internal SMART data structure)";
        }
        if ($opt_failure) {
                $status_string = "$status_string, " .join(': ',@error_messages);
        }
        $status_string = $status_string . ".";
}

print "$status_string|$perf_string\n";
exit $ERRORS{$exit_status};

sub print_help {
	print_revision($basename,$revision);
	print "Usage:\n$basename --device=<device> --interface=(ata|sat|scsi|[sat+]megaraid,N) [--realloc=<num>] [--pending=<num>] [--checksum] [--log] [--failure] [--debug] [--version] [--help]\n\n";
	print "  -d/--device     a device to be SMART monitored, eg. /dev/sda\n";
	print "  -i/--interface  ata, sat, scsi, megaraid, depending upon the device's interface type\n";
#        print "  -n/--number     where in the argument megaraid, it is the physical disk number within the MegaRAID controller\n";
        print "  -r/--realloc    minimum of accepted reallocated sectors (actual value: $opt_realloc)\n";
        print "  -p/--pending    minimum of accepted pending sectors (actual value: $opt_pending)\n";
	print "  -c/--checksum   disable checksum log structure (default: enable)\n";
	print "  -l/--log        disable check of SMART logs (default: enable)\n";
	print "  -f/--failure    disable warning when disk may be close to failure)\n";
	print "     --debug      show debugging information\n";
	print "  -h/--help       this help\n";
	print "  -v/--version    show version of this plugin\n";
	print "\nExamples:\n";
	print "  $basename --device=/dev/sda --interface=sat --realloc=10\n";
	print "  $basename -d /dev/sdb -i megaraid,2 -p 1 -l\n";
	support();
}

# escalate an exit status IFF it's more severe than the previous exit status
sub escalate_status {
	my $requested_status = shift;
	# no test for 'CRITICAL'; automatically escalates upwards
	if ($requested_status eq 'WARNING') {
		return if $exit_status eq 'CRITICAL';
	}
	if ($requested_status eq 'UNKNOWN') {
		return if $exit_status eq 'WARNING';
		return if $exit_status eq 'CRITICAL';
	}
	$exit_status = $requested_status;
}

__END__

=pod

=head1 NAME

check_smart.zcu.pl - B<Check SMART status> of ATA/SCSI/SAT disks, returning any usable metrics as perfdata. With Megaraid controller support.

=head1 VERSION

version 1.0.7

=head1 DESCRIPTION

check_smart.zcu.pl is checking SMART status of given disk. Return any usable metrics as perfdata.

For usage information, run ./check_smart.zcu.pl -h
                        
=head1 SOURCE AVAILABILITY

This source is in B<Nagios Exchange>:

  L<http://exchange.nagios.org/directory/Plugins/System-Metrics/Storage-Subsystem/Check-SMART-status-ZCU/details>

=head1 BUGS

Please report any bugs or feature requests to Nagios Exchange in comments.

   L<http://exchange.nagios.org/directory/Plugins/System-Metrics/Storage-Subsystem/Check-SMART-status-ZCU/details>

=head1 INCOMPATIBILITIES

None known.

=head1 AUTHOR

B<Michal Svamberg>, C<< <svamberg at civ.zcu.cz> >>

=head1 LICENSE

This software is copyright (c) 2013 by B<Michal Svamberg>.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut


