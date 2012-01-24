# Module: ConntrackSync.pm
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2010 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Mohit Mehta
# Date: 2010
# Description: vyatta conntrack-sync management
#
# **** End License ****
#

package Vyatta::ConntrackSync;

use strict;
use warnings;

use Vyatta::Config;
use Vyatta::Misc;
use Vyatta::Interface;
use Vyatta::TypeChecker;
use Vyatta::Keepalived;
use base qw(Exporter);

our @EXPORT = qw(
        conntrackd_write_file
        get_conntracksync_val
        get_config_val
	run_cmd
	conf_file_header
	address_ignore
	generate_conntrackd_config
	interface_checks
	failover_mechanism_checks
	expect_sync_protocols_checks
	print_dbg_config_output
	get_vrrp_sync_grps	
);

my $DEBUG="false";
my $SYSLOG="false";
my $LOGGER = 'sudo logger -t conntracksync.pm -p local0.warn --';

my $CONF_FILE      = '/etc/conntrackd/conntrackd.conf';
my $LOCK_FILE      = '/var/lock/conntrack.lock';
my $CTL_FILE       = '/var/run/conntrackd.ctl';

my $GENERAL_SECTION_START    = "General {\n";
my $SYNC_SECTION_START       = "Sync {\n";
my $MODE_SECTION_START       = "\tMode FTFW {\n";
my $MULTICAST_SECTION_START  = "\tMulticast {\n";
my $OPTIONS_SECTION_START    = "\tOptions {\n";
my $OPTIONS_EXPECTATIONSYNC_START    = "\t\tExpectationSync {\n";


# TODO : kernel-space event filtering saves some CPU cycles by avoiding the
# copy of the event message from kernel-space to user-space. The kernel-space 
# event filtering is prefered, however, you require a Linux kernel >= 2.6.29
# to filter from kernel-space. CURRENTLY, we're using Userspace filtering 
# because Kernelspace filtering seems BUGGY i.e. doesn't filter addresses 
# such as 10.3.0.255 255.255.255.255. Reported to Netfilter developer and 
# he plans to fix this in libnetfilter_conntrack. we would then have to 
# upgrade libnetfilter-conntrack3 that has that fix
my $FILTER_SECTION_START     = "\tFilter From Userspace {\n";

my $ADDRIGNORE_SECTION_START = "\t\tAddress Ignore {\n";
my $PROTOACCEPT_SECTION_START = "\t\tProtocol Accept {\n";
my $SECTION_END              = "}\n";
my $CONNTRACKSYNC_ERR_STRING = "conntrack-sync error:";

sub run_cmd {
    my $cmd = shift;
    my $error = system("$cmd");

    if ($SYSLOG eq "true") {
        my $func = (caller(1))[3];
        system("$LOGGER [$func] [$cmd] = [$error]");
    }
    if ($DEBUG eq "true") {
        my $func = (caller(1))[3];
        print "[$func] [$cmd] = [$error]\n";
    }
    return $error;
}

sub conntrackd_write_file {
  my ($config) = @_;

  open( my $fh, '>', $CONF_FILE ) || die "Couldn't open $CONF_FILE - $!";
  print $fh $config;
  close $fh;
}

sub get_conntracksync_val {
  my ( $value_func, $rel_path ) = @_;
  my $config = new Vyatta::Config;
  $config->setLevel('service conntrack-sync');
  return $config->$value_func("$rel_path");
}

sub get_config_val {
  my ( $value_func, $level, $rel_path ) = @_;
  my $config = new Vyatta::Config;
  $config->setLevel("$level");
  return $config->$value_func("$rel_path");
}

sub conf_file_header {
  my $output;
  my $date = `date`;
  chomp $date;
  $output = "#\n# autogenerated by vyatta-conntrack-sync.pl on $date\n#\n";
  return $output;
}

sub address_ignore {
  my $addr_type = shift;
  my $cli_type  = undef;
  $cli_type = 'ipv4' if $addr_type eq '4';
  $cli_type = 'ipv6' if $addr_type eq '6';
  my $output = undef;
  my @addrs =
    get_conntracksync_val( "returnValues", "ignore-address $cli_type" );
  foreach my $addr (@addrs) {

    # check type of address
    # if type matches $addr_type then put appropriate string in $output
    if ( $addr_type eq '4' ) {
      $output .= "\t\t\tIPv4_address $addr\n" if validateType( 'ipv4', $addr, 'quiet' );
      $output .= "\t\t\tIPv4_address $addr\n"
        if validateType( 'ipv4net', $addr, 'quiet' );
    } elsif ( $addr_type eq '6' ) {
      $output .= "\t\t\tIPv6_address $addr\n" if validateType( 'ipv6', $addr, 'quiet' );
      $output .= "\t\t\tIPv6_address $addr\n"
        if validateType( 'ipv6net', $addr, 'quiet' );
    }
  }
  return $output;
}

sub proto_accept {
  my $output = undef;
  my $proto_string =
  	get_conntracksync_val( "returnValue", "accept-protocol" );
  my @proto_list = ();
  
  if (defined $proto_string) {
    my @string_list = split(/,/, $proto_string);
    while(@string_list) {
      # capitalize protocol values for conntrackd config
      $string_list[0] =~ tr/a-z/A-Z/;
      if (!(scalar(grep(/^$string_list[0]$/, @proto_list)) > 0)) {
        push @proto_list, $string_list[0];
      }
      shift(@string_list);
    } 
    while(@proto_list) {
      $output .= "\t\t\t$proto_list[0]\n";
      shift(@proto_list);
    } 
  }
  return $output;
}

sub generate_conntrackd_config {

  my $expect_all_flag = 'false';
  my $expect_sync_configured = 'false';

  my $intf_name = get_conntracksync_val( "returnValue", "interface" );
  my @intf_ip = Vyatta::Misc::getIP( $intf_name, '4' );
  my @iponly = split( '/', $intf_ip[0] );
  my $mcast_grp = get_conntracksync_val( "returnValue", "mcast-group" );

  my $conntrack_table_size = `cat /proc/sys/net/netfilter/nf_conntrack_max`;
  my $cache_hash_size      = `cat /sys/module/nf_conntrack/parameters/hashsize`;
  chomp $cache_hash_size;
  chomp $conntrack_table_size;
  my $cache_table_size = 2 * $conntrack_table_size;

  my $sync_queue_size =
    get_conntracksync_val( "returnValue", "sync-queue-size" );
  my $event_listen_queue_size =
    get_conntracksync_val( "returnValue", "event-listen-queue-size" );
    
  # get protocols for which expect table is to be synched. 
  my @expect_sync_protocols = 
    get_conntracksync_val( "returnValues", "expect-sync");

  if (@expect_sync_protocols) {
      #create hash of expect-sync protocols from the array 
      my %hash_expect_sync_protocols = map { $_ => 1 } @expect_sync_protocols;  

      if (%hash_expect_sync_protocols) {
          $expect_sync_configured = 'true';
      
          # If all is enabled, then set expect_all_flag   
          if(exists($hash_expect_sync_protocols{"all"})) {
             $expect_all_flag = 'true'; 
          }
      }
  }

  # convert to MB to B for underlying conntrackd config
  $sync_queue_size = $sync_queue_size * 1024 * 1024;
  $event_listen_queue_size = $event_listen_queue_size * 1024 * 1024;
  
  ## BEGIN CONFIG FILE GENERATION ##
  my $output = undef;
  $output = conf_file_header();

  # GENERATE SYNC SECTION
  $output .= "\n#\n# Synchronizer settings\n#\n";
  $output .= $SYNC_SECTION_START;

  $output .= $MODE_SECTION_START;
  # mode section end
  $output .= "\t$SECTION_END";

  $output .= $MULTICAST_SECTION_START;
  $output .= "\t\tIPv4_address $mcast_grp\n";
  $output .= "\t\tGroup 3780\n";
  $output .= "\t\tIPv4_interface $iponly[0]\n";
  $output .= "\t\tInterface $intf_name\n";
  $output .= "\t\tSndSocketBuffer $sync_queue_size\n";
  $output .= "\t\tRcvSocketBuffer $sync_queue_size\n";
  $output .= "\t\tChecksum on\n";
  # multicast section end
  $output .= "\t$SECTION_END";

  # If any expect-sync protocolis configured, write options section
  if ($expect_sync_configured eq 'true') {
      # Options section start
      $output .= $OPTIONS_SECTION_START;
      # Expectation sync start
      $output .= $OPTIONS_EXPECTATIONSYNC_START;
      if ($expect_all_flag eq 'true') {
         $output .= "\t\t\tftp\n";
         $output .= "\t\t\tsip\n"; 
         $output .= "\t\t\th323\n"; 
 #       $output .= NFS 
 #       $output .= SQL*net 
      } else {
         foreach (@expect_sync_protocols) {
 	     $output .= "\t\t\t$_\n";
         } 
      }
      # Expectation sync end 
      $output .= "\t\t$SECTION_END";
      # Options section end
      $output .= "\t$SECTION_END";
  }

  # SYNC SECTION END
  $output .= "$SECTION_END";

  # GENERATE GENERAL SECTION
  $output .= "\n#\n# General settings\n#\n";
  $output .= $GENERAL_SECTION_START;
  $output .= "\tNice -20\n";
  $output .= "\tHashSize $cache_hash_size\n"
    ;    # this should be same as 'firewall conntrack-hash-size'
         #  i.e. /sys/module/nf_conntrack/parameters/hashsize
  $output .= "\tHashLimit $cache_table_size\n"
    ;    # this should be double of 'firewall conntrack-table-size'
         # i.e. /proc/sys/net/netfilter/nf_conntrack_max
  $output .= "\tLogFile off\n";
  $output .= "\tSyslog on\n";
  $output .= "\tLockFile $LOCK_FILE\n";
  $output .= "\tUNIX {\n";
  $output .= "\t\tPath $CTL_FILE\n";
  $output .= "\t\tBacklog 20\n";
  $output .= "\t}\n";
  $output .= "\tNetlinkBufferSize 2097152\n";
  $output .= "\tNetlinkBufferSizeMaxGrowth $event_listen_queue_size\n";
  $output .= "\tNetlinkOverrunResync Off\n";
  $output .= "\tNetlinkEventsReliable On\n";

  my $ipv4_ignore_list = address_ignore('4');
  my $proto_accept_list = proto_accept();
  # uncomment lines below when conntrack-sync ipv6 is supported in future
  # my $ipv6_ignore_list = address_ignore('6');

  if (defined $ipv4_ignore_list || defined $proto_accept_list) {
  
  	$output .= $FILTER_SECTION_START;
  	
  	if (defined $ipv4_ignore_list) {
  		$output .= $ADDRIGNORE_SECTION_START;
  		$output .= $ipv4_ignore_list;
  		# ignoring ipv6 right now up until it's implemented
  		# $output .= $ipv6_ignore_list;
  		# addrignore section end
  		$output .= "\t\t$SECTION_END";
  	}
  	
  	if (defined $proto_accept_list) {
  		$output .= $PROTOACCEPT_SECTION_START;
  		$output .= $proto_accept_list;
  		# proto section section end
  		$output .= "\t\t$SECTION_END";
  	}
  	
  	# filter section end
  	$output .= "\t$SECTION_END";
  
  }	

  # GENERAL SECTION END
  $output .= "$SECTION_END";

  ## END CONFIG FILE GENERATION ##

  return $output;
}

sub interface_checks {
  my $err_string = undef;

  # make sure interface is defined
  my $intf_name = get_conntracksync_val( "returnValue", "interface" );
  if ( !defined $intf_name ) {
    $err_string = "$CONNTRACKSYNC_ERR_STRING interface not defined";
    return $err_string;
  }

  # also need to validate that interface exists on the system
  # and that it has an IP address assigned to it
  my $intf = new Vyatta::Interface($intf_name);
  if ($intf) {
    if ( !$intf->exists() ) {
      $err_string = "$CONNTRACKSYNC_ERR_STRING interface does not exist on system";
      return $err_string;
    }
    if ( scalar( $intf->address('4') ) == 0 ) {
      $err_string =
        "$CONNTRACKSYNC_ERR_STRING IP address not configured on interface";
      return $err_string;
    }
  } else {
    $err_string = "$CONNTRACKSYNC_ERR_STRING invalid interface";
    return $err_string;
  }

  return $err_string;
}

sub failover_mechanism_checks {
  my $err_string = undef;

  # make sure failover mechanism is configured
  my @failover_mechanism =
    get_conntracksync_val( "listNodes", "failover-mechanism" );
  if ( scalar(@failover_mechanism) == 0 ) {
    $err_string = "$CONNTRACKSYNC_ERR_STRING failover mechanism not defined";
    return $err_string;
  } elsif ( scalar(@failover_mechanism) > 1 ) {
  	$err_string = 
  		"$CONNTRACKSYNC_ERR_STRING can't set both vrrp " . 
  		"and cluster as failover mechanism";
  	return $err_string;
  }

  # checks for failover mechanism settings specific to the mechanism
  if ( $failover_mechanism[0] eq 'cluster' ) {
    my $cluster_grp = get_conntracksync_val( "returnValue",
      "failover-mechanism cluster group" );

    # make sure cluster group is defined
    if ( !defined $cluster_grp ) {
      $err_string = "$CONNTRACKSYNC_ERR_STRING cluster group not defined";
      return $err_string;
    }

    # make sure cluster process is running
    my $heartbeat_running = 0;
    $heartbeat_running = run_cmd("pgrep heartbeat >&/dev/null");
    if ($heartbeat_running != 0) {
      $err_string = "$CONNTRACKSYNC_ERR_STRING Clustering isn't running";
      return $err_string;
    }

    # make sure cluster group exists
    my @cluster_grps =
      get_config_val( 'listOrigPlusComNodes', 'cluster', 'group' );
    if ( scalar(@cluster_grps) == 0
      || scalar( grep( /^$cluster_grp$/, @cluster_grps ) ) == 0 )
    {
      $err_string = "$CONNTRACKSYNC_ERR_STRING cluster group does not exist";
      return $err_string;
    }

  } elsif ( $failover_mechanism[0] eq 'vrrp' ) {
    my $vrrp_sync_grp = get_conntracksync_val( "returnValue",
      "failover-mechanism vrrp sync-group" );

    # make sure vrrp sync group is defined
    if ( !defined $vrrp_sync_grp ) {
      $err_string = "$CONNTRACKSYNC_ERR_STRING vrrp sync-group not defined";
      return $err_string;
    }

    # make sure VRRP is running
    if (!Vyatta::Keepalived::is_running()) {
      $err_string = "$CONNTRACKSYNC_ERR_STRING VRRP isn't running";
      return $err_string;
    }

    # make sure vrrp sync-group exists
    my $sync_grp_exists = 'false';
    my @vrrp_intfs = Vyatta::Keepalived::list_vrrp_intf('isActive');
    foreach my $vrrp_intf (@vrrp_intfs) {
      my @vrrp_groups = list_vrrp_group($vrrp_intf, 'listOrigPlusComNodes');
      foreach my $vrrp_group (@vrrp_groups) {
        my $sync_grp = list_vrrp_sync_group($vrrp_intf, $vrrp_group, 'returnOrigPlusComValue');
        if (defined $sync_grp && $sync_grp eq "$vrrp_sync_grp") {
          $sync_grp_exists = 'true';
          last;
        }
      }
      last if $sync_grp_exists eq 'true';
    }

    if ($sync_grp_exists eq 'false') {
      $err_string = "$CONNTRACKSYNC_ERR_STRING vrrp sync-group does not exist";
      return $err_string;
    } 

  } else {
    $err_string = "$CONNTRACKSYNC_ERR_STRING invalid failover mechanism";
    return $err_string;
  }

  return $err_string;
}

sub expect_sync_protocols_checks() {
  my $err_string = undef;

  # If expect-sync is configured 

  my @expect_sync_protocols = get_conntracksync_val( "returnValues", "expect-sync" );
  if (@expect_sync_protocols) {
    my @expect_sync_orig_protocols = get_conntracksync_val("returnOrigValues", "expect-sync");
    if (@expect_sync_orig_protocols) {
       foreach (@expect_sync_orig_protocols) {
           if ($_ eq "all") {
              print "$_ \n";
              $err_string = "$CONNTRACKSYNC_ERR_STRING Please remove expect-sync all before configuring other protocols"; 
              return $err_string;
           } 
       }
       foreach (@expect_sync_protocols) {
           if ($_ eq "all") {
              print "$_ \n";
              $err_string = "$CONNTRACKSYNC_ERR_STRING Please remove expect-sync <protocol(s)> before configuring all protocols"; 
              return $err_string;
           } 
       }
    }
  }
  return $err_string;
}
sub print_dbg_config_output {
  my $config = shift;
  print "wrote the following generated conntrackd config file - \n$config\n"
    if $DEBUG eq 'true';
}

sub get_vrrp_sync_grps {
  my @sync_grps = Vyatta::Keepalived::list_all_vrrp_sync_grps();
  return @sync_grps;
}

1;
