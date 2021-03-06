=head1 NAME

Awesant::Input::OracleAlertLogXml - Oracle XML alert log input

=head1 SYNOPSIS

    # Create a new tail-like object specific for Oracle XML Alert log.
    my $input = Awesant::Input::OracleAlertLogXml->new(
        path => "/u01/app/oracle/diag/rdbms/orcl/ORCL/alert/log.xml",
        save_position => "yes", # experimental
    );

    # Pull the next 100 multiline records that were appended
    # to the log file.
    $input->pull(lines => 100);

=head1 DESCRIPTION
 
Oracle Alert XML log files as input. Log file rotation is supported, but note that
you should configure delayed compression for log files.

Input XML structure of alert log:
```
        <msg time='2016-01-01T05:09:20.742+01:00' org_id='oracle' comp_id='rdbms'
         type='UNKNOWN' level='16' host_id='my.dot.com' pid='5887'
    	host_addr='3.4.5.6'>
        <txt>opidrv aborting process L002 ospid (5887) as a result of ORA-65535
        </txt>
        </msg>
```
is converted to JSON msg in the following format:
```
{"org_id":"oracle","host_addr":"3.4.5.6","time":"2016-01-01T05:09:20.742+01:00","comp_id":"rdbms","level":"16","type":"UNKNOWN","host_id":"my.dot.com","pid":"5887","txt":"opidrv aborting process L002 ospid (5887) as a result of ORA-65535\n "}
```

Also the TNS messages spread across multiple XML messages are joined together into single message:
```
{"txt":"\n***********************************************************************\n \nFatal NI connect error 12170.\n \n  VERSION INFORMATION:\nTNS for Linux: Version 11.2.0.4.0 - Production\nOracle Bequeath NT Protocol Adapter for Linux: Version 11.2.0.4.0 - Production\nTCP/IP NT Protocol Adapter for Linux: Version 11.2.0.4.0 - Production\n   Time: 02-JAN-2016 09:55:23\n   Tracing not turned on.\n   Tns error struct:\n     ns main err code: 12535\n     \n TNS-12535: TNS:operation timed out\n     ns secondary err code: 12560\n     nt main err code: 505\n     \n TNS-00505: Operation timed out\n     nt secondary err code: 110\n     nt OS err code: 0\n   Client address: (ADDRESS=(PROTOCOL=tcp)(HOST=1.2.3.4)(PORT=25397))\n ","host_id":"example.com","type":"UNKNOWN","level":"16","comp_id":"rdbms","time":"2016-01-02T09:55:23.995+01:00","host_addr":"4.5.6.7","org_id":"oracle"} 
```

Sometimes multiple TNS messages come interleaved and we have to extract them out in correct order.

=head1 OPTIONS

=head2 path

The path to the log file. Multiple paths can be set as comma separated list.

    input {
        OracleAlertLogXml {
            type alertlog
            path /u01/app/oracle/diag/rdbms/orcl/ORCL/alert/log.xml
        }
    }
    
Wildcards can also be used which is ideal if multiple Oracle instances are running
on the same server.

    input {
        OracleAlertLogXml {
            type alertlog
            path /u01/app/oracle/diag/rdbms/*/*/alert/log.xml
        }
    }
    
Oracle listener logs have the same formating:

    input {
    	OracleAlertLogXml {
        	type listenerlogxml
        	path /u01/app/oracle/diag/tnslsnr/*/*/alert/log.xml
    	}
    }


=head2 skip

Define regexes to skip Oracle alert messages.

    input {
        OracleAlertLogXml {
            type alertlog
            path /u01/app/oracle/diag/rdbms/*/*/alert/log.xml
        	skip "^$"  <---- skip empty messages
        }
    }
    
    input {
    	OracleAlertLogXml {
        	type listenerlogxml
        	path /u01/app/oracle/diag/tnslsnr/*/*/alert/log.xml
        	skip "^$"
        	skip "service_update"  <---- lots of them and of no real use
    	}
    }

Lines that match the regexes will be skipped.

=head2 grep

Define regexes to filter Oracle alert messages.

    input {
        OracleAlertLogXml {
            type alertlog
            path /u01/app/oracle/diag/rdbms/*/*/alert/log.xml
            grep ORA-0404(0|1)
            grep ^ORA-00600
        }
    }

Lines that do not match the regexes will be skipped.


=head2 save_position

Experimental feature.

If the option save_position is set to true then the last position
with the inode of the log file is saved to a file. If Awesant is down
then it can resume its work where it was stopped. This is useful if you
want to lose as less data as possible of your log files.

Please note that this feature is experimental and does not keep log file
rotations.

=head1 METHODS

=head2 new

Create a new input object.

=head2 get_lastpos

Get the last position if the option C<save_position> is true.

=head2 open_logfile

Open the log file and store the inode for later checks.

=head2 check_logfile

This method just checks if the inode has changed of the currently opened
file and the file that is found on the file system. If logrotate moved
the file, then the inode changed. In this case the rotated file is read
until its end and then the file will be closed to re-open the new file
on the file system.

=head2 pull(lines => $number)

This methods reads the excepted number of messages or until the end of the
file and returns the messages as a array reference.

=head2 validate

Validate the configuration that is passed to the C<new> constructor.

=head2 log

Just a accessor to the logger.

=head2 check_event

This method is call for each event and checks filters the event by options C<skip> and C<grep>.

=head1 PREREQUISITES

    Fcntl
    Params::Validate
    Log::Handler

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <mitja.golouh(at)gmail.com>.

=head1 AUTHOR

Mitja Golouh <mitja.golouh(at)gmail.com>
Based on File.pm by Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2016 by Mitja Golouh. All rights reserved.
Based on File.pm by Jonny Schulz <support(at)bloonix.de>.

=cut


package Awesant::Input::OracleAlertLogXml;

use strict;
use warnings;
use Fcntl qw( :flock O_WRONLY O_CREAT O_RDONLY );
use Params::Validate qw();
use Log::Handler;
use JSON;
use HTML::Entities; # to decoded HTML entities in log.xml

sub  trim  { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };
sub  rtrim { my $s = shift; $s =~ s/\s+$//g; return $s };

sub new {
    my $class = shift;
    my $opts = $class->validate(@_);
    my $self = bless $opts, $class;

    $self->{log} = Log::Handler->get_logger("awesant");
    $self->{reached_end_of_file} = 0;
    $self->get_lastpos;
    $self->open_logfile;
    
    $self->{multiline_buffer} = "";
    $self->{multiline_lastreadtime} = undef;

    # find-start 
    # read-until-suffix, read-until-prefix
    # read-until-nonindent
    $self->{multiline_status} = "find-start";
    $self->{is_tns_multiline} = 0;
    # we keep the real lastpos internally until whole multiline block is read
    # than we post it to $self->{lastpos}
    $self->{multiline_lastpos} = 0;
    
    $self->log->info("$class initialized");

    return $self;
}

sub get_lastpos {
    my $self = shift;
    my $file = $self->{path};
    my $libdir = $self->{libdir};
    my $inode = "";

    if ($self->{start_position} eq "begin") {
        $self->{multiline_lastpos} = $self->{lastpos} = 0;
    } else {
        # set lastpos = total size of file in bytes
        $self->{multiline_lastpos} = $self->{lastpos} = -e $file ? (stat($file))[7] : 0;
    }

    if (!$self->{save_position}) {
        return;
    }

    my $basename = do { $self->{path} =~ m!([^\\/]+)\z!; $1 };
    my $posfile = "$libdir/awesant-$basename.pos";

    if (-e $posfile) {
        $self->log->debug("read last position from $posfile");
        open my $fh, "<", $posfile or die "unable to open '$posfile' for reading - $!";
        my $line = <$fh>;
        my ($inode, $lastpos) = split /:/, $line;

        if (defined $inode && defined $lastpos && $inode =~ /^\d+\z/ && $lastpos =~ /^\d+\z/) {
            $inode =~ s/^0+//;
            $lastpos =~ s/^0+//;

            if (-e $file && (stat($file))[1] eq $inode) {
                $self->{multiline_lastpos} = $self->{lastpos} = $lastpos;
            }
        }

        close $fh;
    }

    $self->log->debug("last position $self->{lastpos}");
    $self->log->debug("open '$posfile' for writing");
    sysopen my $fhpos, $posfile, O_CREAT | O_WRONLY
        or die "unable to open '$posfile' for writing - $!";

    # autoflush
    my $oldfh = select $fhpos;
    $| = 1;
    select $oldfh;

    # save the file handle for later usage
    $self->{fhpos} = $fhpos;
}

sub open_logfile {
    my $self = shift;
    my $file = $self->{path};
    my $fhlog = $self->{fhlog};

    if ($fhlog && $self->check_logfile) {
        return $fhlog;
    }

    $self->log->info("open '$file' for reading");

    open $fhlog, "<", $file or do {
        $self->log->error("unable to open logfile '$file' for reading - $!");
        return undef;
    };

    # Store the inode for the logfile to check
    # later if the inode changed because logrotate
    # moves the file.
    $self->{inode} = (stat($file))[1];
    $self->log->debug("stored inode $self->{inode} for file '$file'");

    # If fhlog is already set then we just reopen the next
    # file and jump to the start of the file, otherwise
    # a log file wasn't opened before and we jump to the
    # position of get_lastpos
    if ($self->{fhlog}) {
        $self->{lastpos} = 0;
    }

    $self->log->info("seek to position $self->{lastpos} of file '$file'");
    seek($fhlog, $self->{lastpos}, 0);
    $self->{fhlog} = $fhlog;
    return $fhlog;
}

sub check_logfile {
    my $self  = shift;
    my $file  = $self->{path};
    my $inode = $self->{inode};
    my $fhlog = $self->{fhlog};

    # If the end logfile of the logfile is not reached... go forward.
    if ($self->{reached_end_of_file} == 0) {
        #$self->log->debug("skip check logfile - reached_end_of_file=$self->{reached_end_of_file}");
        return 1;
    }

    # If the end of the logfile is reached and we see that the logfile does
    # not exist or the inode has changed, the rest of the logfile is read.
    # Then, if reached_end_of_file is set higher than 9 it means that the
    # real end is reached. (reached_end_of_file of 20 = 20 loops * 500ms = 10seconds)
    if ($self->{reached_end_of_file} < 20 && (!-e $file || $inode != (stat($file))[1])) {
        return 1
    }

    # Clean up the eof marker
    $self->{reached_end_of_file} = 0;

    # Check if the logfile exists.
    if (!-e $file) {
        $self->log->info("the log file '$file' does not exists any more");
        close $fhlog;
        $self->{fhlog} = undef;
        return 0;
    }

    # Check if the inode has changed, because it's possible
    # that logrotate.d rotates the log file.
    if ($inode != (stat($file))[1]) {
        $self->log->info("inode of file '$file' changed - closing file handle");
        $self->{fhlog} = undef;
        close $fhlog;
        return 0;
    }

    # Check if the the current position where the log file was
    # read is higher than the file size. It's possible that
    # the logfile was flushed.
    if ((stat($file))[7] < $self->{lastpos}) {
        $self->log->info("the size of file '$file' shrinks - seeking back");
        seek($fhlog, 0, 0);
        $self->{multiline_lastpos} = $self->{lastpos} = 0;
    } 

    return 1;
}
# Determine the sequence inside TNS message
# 10.%NI%
# 20. %VERSION INFORMATION%
# 30. %Time:%
# 40. %Tracing%
# 50. %Tns error struct%
# 60 (optional) nr err code: W
# 70 (optional if W>0) TNS-W
# 80. %ns main err code:% X
# 90  %TNS-X"
# 100. ns secondary err code
# 110. nt main err code: Y
# 120. (optional if y>0) TNS-Y
# 130. nt secondary err code
# 140. nt OS err code
# 150. (optional) Client address:
sub get_tns_message_state {
    my ($self, $line, $tns_active_error_type, $tns_active_error_no) = @_;
	
	my $current_line_state = -1;
	my $current_tns_active_error_no = undef;
	my $current_tns_active_error_type = undef;

	if ( $line =~ /^\s*(NI|Fatal NI)/) { $current_line_state = 10; }
	elsif ( $line =~ /^\s*VERSION INFORMATION/) { $current_line_state = 20; }
	elsif ( $line =~ /^\s*Time/) { $current_line_state = 30; }
	elsif ( $line =~ /^\s*Tracing/) { $current_line_state = 40; }
	elsif ( $line =~ /^\s*Tns error struct/) { $current_line_state = 50; }
	elsif ( $line =~ /^\s*nr err code/) { $current_line_state = 60; $current_tns_active_error_type = "nr"; $current_tns_active_error_no = sprintf("%05d", ( split ' ', $line )[ -1 ]); }
	elsif ($tns_active_error_no and $tns_active_error_type eq "nr" and $line =~ /^\s*TNS-$tns_active_error_no/) { $current_line_state = 70; }
	elsif ( $line =~ /^\s*ns main err code/) { $current_line_state = 80; $current_tns_active_error_type = "ns"; $current_tns_active_error_no = sprintf("%05d", ( split ' ', $line )[ -1 ]); }
	elsif ($tns_active_error_no and $tns_active_error_type eq "ns" and $line =~ /^\s*TNS-$tns_active_error_no/) { $current_line_state = 90; }
	elsif ( $line =~ /^\s*ns secondary err code/) { $current_line_state = 100; }
	elsif ( $line =~ /^\s*nt main err code/) { $current_line_state = 110; $current_tns_active_error_type = "nt"; $current_tns_active_error_no = sprintf("%05d", ( split ' ', $line )[ -1 ]); }
	elsif ($tns_active_error_no and $tns_active_error_type eq "nt" and $line=~ /^\s*TNS-$tns_active_error_no/) { $current_line_state = 120; }
	elsif ( $line =~ /^\s*nt secondary err code/) { $current_line_state = 130; }
	elsif ( $line =~ /^\s*nt (OS|os) err code/) { $current_line_state = 140; }
	elsif ( $line =~ /^\s*Client address/) { $current_line_state = 150; }
	elsif ( $line =~ /^\s*\*{71}/ ) { $current_line_state = 0; }
	elsif ( $line =~ /^TNS.*/) { $current_line_state = -1; } # it is a TNS line but the order is incorrect, usually during backlog parsing
    else { $self->log->warn("Unexpected input to get_tns_message_state:" . $line); }

	return ($current_line_state, $current_tns_active_error_type, $current_tns_active_error_no);
}

sub process_tns_multiline_backlog {

	my ($self, $backlog) = @_;

	# empty backlog, nothing to do
    if (scalar @{$backlog} == 0) {
    	return undef;
    }

	my $tns_multiline_state = 0; # holds current state of tns multiline message completeness
   	my $tns_active_error_type = $self->{tns_active_error_type}; # eg. ns, nr, ...
   	my $tns_active_error_no = $self->{tns_active_error_no}; # holds active error no eg. ns main err code: ---> 12535 <---
    my $tns_multiline_buffer;

	$tns_multiline_buffer = $backlog->[0];
	delete $backlog->[0];	
	
    if ($tns_multiline_buffer->{"line"} =~ /^\s*\*{71}/ ) {		
    	$tns_multiline_buffer->{"ora.type"} = "TNS";
    }
    else {
    	$self->log->debug("Backlog not starting with TNS start *******");

    	# loop until correct backlog start is found and return as ora.type="TNS mess"
    	$tns_multiline_buffer->{"ora.type"} = "TNS mess";
		for my $i (1 .. scalar @{$backlog} - 1)				
		{
			my $current_msg = $backlog->[$i];
		    if ($current_msg->{"line"} =~ /^\s*\*{71}/ ) {		
				return $tns_multiline_buffer;	
    		}
    		else {
            	$tns_multiline_buffer->{"line"} .= "\n".$current_msg->{"line"};
            	delete $backlog->[$i];
    		}			
		}
    	
    	return $tns_multiline_buffer;
    }
			
	for my $i (1 .. scalar @{$backlog} - 1)				
	{
		my $current_msg = $backlog->[$i];

		my ($current_line_state, $current_tns_active_error_type, $current_tns_active_error_no) = $self->get_tns_message_state($current_msg->{"line"}, $tns_active_error_type, $tns_active_error_no );						
		if ($current_line_state > $tns_multiline_state) {
            $tns_multiline_buffer->{"line"} .= "\n".$current_msg->{"line"};
            delete $backlog->[$i];
            # update TNS multiline state
            $tns_multiline_state = $current_line_state;
            $tns_active_error_type = $current_tns_active_error_type;
            $tns_active_error_no = $current_tns_active_error_no;
        }		
	}	
	
	# just compact the array to remove deleted entries
	# not an optimal solution but this situations are rare so we don't
	# have to look for perfection
	@{$backlog} = map { exists $backlog->[$_] ? $backlog->[$_] : () } 0 .. $#{$backlog} ;	

	return $tns_multiline_buffer;
}

sub pull {
    my ($self, %opts) = @_;

    local $SIG{PIPE} = "IGNORE";

    # instead of number of lines we set limit to max number of multiline blocks 
    my $max_multiline_blocks = $opts{lines} || 1;  
    my $lines = [ ];
    my $fhpos = $self->{fhpos};
    my $fhlog = $self->open_logfile or return undef;
        	
	my $lastpos = $self->{lastpos};
	my $multiline_lastreadtime = $self->{multiline_lastreadtime};
	my $multiline_status = $self->{multiline_status};
	my $multiline_buffer = $self->{multiline_buffer};
	my $is_tns_multiline = $self->{is_tns_multiline};
	my $tns_multiline_buffer = $self->{tns_multiline_buffer};

    # TNS messages tend to get logged in incorrect order
	# We use some state logic to detect and avoid tns order mess
	my $tns_multiline_state = $self->{tns_multiline_state}; # holds current state of tns multiline message completeness
    my $tns_active_error_type = $self->{tns_active_error_type}; # eg. ns, nr, ...
    my $tns_active_error_no = $self->{tns_active_error_no}; # holds active error no eg. ns main err code: ---> 12535 <---
    my $tns_order_mess = $self->{tns_order_mess}; # 0=no mess, 1=one TNS message mess, 2=two TNS messages ....
	my $tns_multiline_backlog = $self->{tns_multiline_backlog}; # holds skipped lines due to incorrect order on source
	my $got_new_lines = 0;
	
    while (my $line = <$fhlog>) { 

    	$multiline_lastreadtime = Time::HiRes::gettimeofday() unless defined $multiline_lastreadtime;
        $got_new_lines = 1;

		
        chomp $line;

        # typicall input message 
        #<msg time='2016-01-01T05:09:20.742+01:00' org_id='oracle' comp_id='rdbms'
        # type='UNKNOWN' level='16' host_id='my.dot.com'
        #host_addr='3.4.5.6'>
        #<txt>  Client address: (ADDRESS=(PROTOCOL=tcp)(HOST=1.2.3.4)(PORT=61166))
        #</txt>
        #</msg>
        
        		# search until prefix is matched than start with new multiline block
        		# drop non matching lines until next <msg.* is found
        		if ($multiline_status eq "find-start") {
        			# use index or substr instead of regex because it is twice as fast
					# if ($line =~ /<msg.*/) {
        			if (index($line,"<msg") == 0) {
        				$multiline_buffer = "$line";
        				$multiline_status = "read-until-suffix";
        			} 
        			next;
        		}  
        		
        		# </msg> terminates the multiline block
        		# use index or substr instead of regex because it is twice as fast
				#if ($line =~ /<\/msg>/) {
				if (index($line,"<\/msg>") == 0) {

					$multiline_buffer .= "\n$line";
					my %msg = %{$self->convert_xmlalert_to_hash($multiline_buffer)};
					$msg{"offset"} = $lastpos + 1; # set offset start of the multiline message 					

					if ( $msg{"line"} eq "" ) {
						# do nothing, skip empty messages
					}
					elsif (!$is_tns_multiline) {
						# start of tns multiline
						if ( $msg{"line"} =~ /^\s*\*{71}/ ) {		
							$self->log->debug("Start of a new tns multiline");	
							$is_tns_multiline = 1; 
                            $tns_order_mess = 0;
							
							# reset TNS multiline state
							$tns_multiline_state = 0; $tns_active_error_type = undef; $tns_active_error_no = undef;

							$msg{"ora.type"} = "TNS";
							$tns_multiline_buffer = \%msg;
						} 
						# plain simple alert log line
						else {										
							if ($self->check_event($msg{"line"})) {
								push @$lines, \%msg;
								$max_multiline_blocks--;
							}
						}
					# continuation of tns multiline	
					} else { 
                        
						# another tns multiline following
						if ( $msg{"line"} =~ /^\s*\*{71}/ ) {	
                            if ($tns_multiline_state >= 140 and not $tns_order_mess) {						
						 		$self->log->debug("Start of another tns multiline");
						 		
						 		# reset TNS multiline state
						 		$tns_multiline_state = 0; $tns_active_error_type = undef; $tns_active_error_no = undef;
						 		
								if ($self->check_event($tns_multiline_buffer->{"line"})) {
									push @$lines, $tns_multiline_buffer;
									$max_multiline_blocks--;
								}						 	
								$msg{"ora.type"} = "TNS";
								$tns_multiline_buffer = \%msg;
							}	
                        	# hm, we have hit tns order mess, put current event into the backlog
                            else {
                            	$self->log->debug("TNS order mess ++");
                            	
                            	$tns_order_mess++;
                                push @$tns_multiline_backlog, \%msg;
                            }							
						}
						# continuation of the same tns message
						elsif ( $msg{"line"} =~ /^\s.*|^TNS.*|^Fatal NI connect error.*/) 
						{
							my ($current_line_state, $current_tns_active_error_type, $current_tns_active_error_no) = $self->get_tns_message_state($msg{"line"}, $tns_active_error_type, $tns_active_error_no );

							if ($current_line_state > $tns_multiline_state) {
                               	$tns_multiline_buffer->{"line"} .= "\n".$msg{"line"};
                               	# update TNS multiline state
                               	$tns_multiline_state = $current_line_state;
                        		$tns_active_error_type = $current_tns_active_error_type;
                        		$tns_active_error_no = $current_tns_active_error_no;
                            }
							else 
							{
								if ( $tns_order_mess ) { push @$tns_multiline_backlog, \%msg; }
								else {
									$self->log->warn("Incorrect TNS message order without TNS mess");	
									$tns_multiline_buffer->{"ora.type"}	= "TNS mess";						
									$tns_multiline_buffer->{"line"} .= "\n".$msg{"line"};
								}
							}
                        }

						# end of tns multiline	
						else {
							$self->log->debug("End of tns multiline");

							# push current tns multiline to output
							if ($self->check_event($tns_multiline_buffer->{"line"})) {
								push @$lines, $tns_multiline_buffer;
								$max_multiline_blocks--;
							}	
							
							# process_tns_multiline_backlog
							if ($tns_order_mess) {
								$self->log->debug("Process TNS multiline backlog of " . scalar @{$tns_multiline_backlog} . " line(s)");	
								$self->log->debug("Expecting " . $tns_order_mess . " TNS message(s)");		
								while (my $x = $self->process_tns_multiline_backlog($tns_multiline_backlog)) {
									push @$lines, $x;
									$tns_order_mess--;
									$max_multiline_blocks--;
								}											

								if ($tns_order_mess != 0) {
									$self->log->warn("Incorrect number of TNS messages in TNS multiline backlog");
								}
								$self->log->debug("Done processing TNS multiline backlog");
																						
								# push new message after tns multiline to output
								if ($self->check_event($msg{"line"})) {
									push @$lines, \%msg;
									$max_multiline_blocks--;
								}								
							}
							
							$tns_multiline_backlog = undef;
							$tns_order_mess = 0;							
							$is_tns_multiline = 0;						
        				}
        			}
						
       				$multiline_buffer = "";
       				$multiline_status = "find-start";
       				$lastpos = tell ($fhlog); # we set lastpos variable after previous message has been completed
       				
        	} else {
        		$multiline_buffer .= "\n$line";
        		next;        			
        	}               		

    	    #$self->log->debug("read", length($line), "bytes from file");
			# exit loop when max blocks have been read
 	        last unless $max_multiline_blocks;
    	}

	$multiline_lastreadtime = Time::HiRes::gettimeofday() if $got_new_lines;


	# Check if it's time to consider multiline msg complete (10 sec rule)
    if (($multiline_status ne "find-start" or $is_tns_multiline)and 
    	defined $multiline_lastreadtime and
       	Time::HiRes::gettimeofday() - $multiline_lastreadtime > 10
       ) 
    {
        $self->log->debug("10 sec rule - flush multiline message buffer");
		if (!$is_tns_multiline) {
			my %msg = %{$self->convert_xmlalert_to_hash($multiline_buffer)};
			if ($self->check_event($msg{"line"})) {
				push @$lines, \%msg;
			}	
		} else {
			if ($self->check_event($tns_multiline_buffer->{"line"})) {
				push @$lines, $tns_multiline_buffer;
			}
			# TODO: process backlog if it exists				
		}

    	$multiline_buffer = undef;
    	$tns_multiline_buffer = undef;
    	$multiline_status = "find-start";    
    	$lastpos = tell ($fhlog);   
    	$multiline_lastreadtime = undef; 
    	$is_tns_multiline = 0;
		$tns_multiline_backlog = undef;
		$tns_order_mess = 0;
    }


	# write current position to file so we can continue after retart
    if ($self->{fhpos}) {
        seek($fhpos, 0, 0);
        printf $fhpos "%014d:%014d", $self->{inode}, $lastpos;
    }

    # If EOF is reached then the logfile should be
    # checked if the file was rotated.
    if ($max_multiline_blocks > 0) {
        $self->{reached_end_of_file}++;
    }

    $self->{lastpos} = $lastpos;
	$self->{multiline_lastreadtime} = $multiline_lastreadtime;
	$self->{multiline_status} = $multiline_status;
	$self->{multiline_buffer} = $multiline_buffer;
	$self->{is_tns_multiline} = $is_tns_multiline; 
	$self->{tns_multiline_buffer} = $tns_multiline_buffer;
    $self->{tns_multiline_state} = $tns_multiline_state;
    $self->{tns_active_error_type} = $tns_active_error_type;
    $self->{tns_active_error_no} = $tns_active_error_no;
    $self->{tns_multiline_backlog} = $tns_multiline_backlog;
    $self->{tns_order_mess} = $tns_order_mess;

    return $lines;
}

sub validate {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        libdir => {
            type => Params::Validate::SCALAR,
            default => "/var/lib/awesant"
        },
        start_position => {
            type => Params::Validate::SCALAR,
            default => "end",
            regex => qr/^(begin|end)\z/
        },
        save_position => {
            type => Params::Validate::SCALAR,
            default => 0,
            regex => qr/^(?:yes|no|1|0)\z/
        },
        path => {
            type => Params::Validate::SCALAR,
        },
        skip => {
            type => Params::Validate::SCALAR | Params::Validate::ARRAYREF,
            default => undef
        },
        grep => {
            type => Params::Validate::SCALAR | Params::Validate::ARRAYREF,
            default => undef
        }
    });

    foreach my $key (qw/skip grep/) {
        if (defined $options{$key} && ref $options{$key} ne "ARRAY") {
            $options{$key} = [ $options{$key} ];
        }
    }

    if ($options{save_position} eq "no") {
        $options{save_position} = 0;
    }

    return \%options;
}

sub log {
    my $self = shift;

    return $self->{log};
}

sub check_event {
    my ($self, $event) = @_;

    if ($self->{skip}) {
        foreach my $regex (@{$self->{skip}}) {
            if ($event =~ /$regex/) {
                return 0;
            }
        }
    }

    if ($self->{grep}) {
        foreach my $regex (@{$self->{grep}}) {
            if ($event =~ /$regex/) {
                return 1;
            }
        }
        return 0;
    }

    return 1;
}

sub convert_xmlalert_to_hash {
    my ($self, $msg) = @_;
    
    my $msg_start = index $msg, '<msg';
	$self->log->warning("<msg position should be 1 and not $msg_start") if $msg_start != 0;

	my $txt_start = index ($msg, '<txt>') + 5;
	my $txt_end = index ($msg, '</txt>') - 1;

	# Attributes can be embedded in msg tag
	# Also standalone attributes are sometimes included
	#
	# <msg time='2016-12-06T09:39:43.193+01:00' org_id='oracle' comp_id='rdbms'
	# msg_id='1108830330' type='INCIDENT_ERROR' group='Generic Internal Error'
	# level='1' host_id='test.example.com' host_addr='10.1.1.2'
	# prob_key='ORA 600 [17285]' errid='61827' detail_path='/u01/app/oracle/diag/rdbms/orcl/ORCL/trace/ORCL_ora_6453.trc'>
	# <attr name='IMPACT' value='PROCESS FAILURE'/>
	# <txt>Errors in file /u01/app/oracle/diag/rdbms/orcl/ORCL/trace/ORCL_ora_6453.trc  (incident=61827):
	#ORA-00600: internal error code, arguments: [17285], [0x7FC35BE25310], [1], [0x2FB755BB8], [], [], [], [], [], [], [], []
	# </txt>
	#</msg>
	my $standalone_attr_start = index ($msg, '<attr');

	# identify position of attributes inside of <msg> tag
	my $attr_start = $msg_start + 5;
	my $attr_end;
	if ($standalone_attr_start == -1) {
		$attr_end = rindex ($msg, ">", $txt_start - 5) - 1;
	} else {
		$attr_end = rindex ($msg, ">", $standalone_attr_start) - 1;
	}

	# extract attributes of <msg> tag
	# we get something like this
	# time='2014-12-31T09:17:03.294+01:00
	# org_id='oracle
	# comp_id='rdbms
	# client_id='
	# type='UNKNOWN
	# level='16
	# host_id='mydomain.com
	# host_addr='12.12.12.12
	# module='
	# pid='19562
#	my @attrs = split(/'\s+>?/, substr($msg, $attr_start, $attr_end - $attr_start ));




    my %alertlog_json = map { (split /='/, "ora.".$_, -1) } split /'\s+>?/, substr($msg, $attr_start, $attr_end - $attr_start );

	# construct hash with all the attribute elements 
	# split attrs to extrace key and value
	# prefix ora. is added to avoid conflict for eg. type
#	my %alertlog_json;
#	foreach (@attrs) {
#		my ($attr0, $attr1) = split(/='/, $_, 2);
		# skip empty attributes
#		if (defined $attr1) {
##			$alertlog_json{"ora.".$attr0} = $attr1;
#			$alertlog_json{"ora.".trim($attr0)} = trim($attr1);
# 		}
# 	}
 	
 	$alertlog_json{"host"} = delete $alertlog_json{"ora.host_id"};
 	$alertlog_json{"file"} = $self->{path};
 	
    # add text field, decode HTML entities on the fly
    $alertlog_json{"line"} = decode_entities(rtrim(substr($msg, $txt_start, $txt_end - $txt_start +1 )));
    
    # add standalone attributes
    # <attr name='IMPACT' value='PROCESS FAILURE'/>
    # <attr name='IMPACT' value='POSSIBLE INSTANCE FAILURE'/>
    if ($standalone_attr_start >= 0) {
    	my $standalone_attr_end_of_name = index ($msg, '\' value=', $standalone_attr_start + 12);
    	my $standalone_attr_end = index ($msg, '\'/>', $standalone_attr_start);

    	my $standalone_attr_name  = substr($msg, $standalone_attr_start + 12, $standalone_attr_end_of_name - $standalone_attr_start - 12 );
    	my $standalone_attr_value = substr($msg, $standalone_attr_end_of_name + 9, $standalone_attr_end - $standalone_attr_end_of_name - 9 );
    	
    	$alertlog_json{$standalone_attr_name} = $standalone_attr_value;
    }
	
	return \%alertlog_json;
}

1;
