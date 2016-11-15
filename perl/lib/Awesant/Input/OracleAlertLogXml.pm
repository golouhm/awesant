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
        <msg time='2016-01-01T05:09:20.742+01:00' org_id='oracle' comp_id='rdbms'
         type='UNKNOWN' level='16' host_id='my.dot.com' pid='5887'
    	host_addr='3.4.5.6'>
        <txt>opidrv aborting process L002 ospid (5887) as a result of ORA-65535
        </txt>
        </msg>
is converted to JSON msg in the following format:
{"org_id":"oracle","host_addr":"3.4.5.6","time":"2016-01-01T05:09:20.742+01:00","comp_id":"rdbms","level":"16","type":"UNKNOWN","host_id":"my.dot.com","pid":"5887","txt":"opidrv aborting process L002 ospid (5887) as a result of ORA-65535\n "}

Also the TNS messages spread across multiple XML messages are joined together into single message:
{"txt":"\n***********************************************************************\n \nFatal NI connect error 12170.\n \n  VERSION INFORMATION:\nTNS for Linux: Version 11.2.0.4.0 - Production\nOracle Bequeath NT Protocol Adapter for Linux: Version 11.2.0.4.0 - Production\nTCP/IP NT Protocol Adapter for Linux: Version 11.2.0.4.0 - Production\n   Time: 02-JAN-2016 09:55:23\n   Tracing not turned on.\n   Tns error struct:\n     ns main err code: 12535\n     \n TNS-12535: TNS:operation timed out\n     ns secondary err code: 12560\n     nt main err code: 505\n     \n TNS-00505: Operation timed out\n     nt secondary err code: 110\n     nt OS err code: 0\n   Client address: (ADDRESS=(PROTOCOL=tcp)(HOST=1.2.3.4)(PORT=25397))\n ","host_id":"example.com","type":"UNKNOWN","level":"16","comp_id":"rdbms","time":"2016-01-02T09:55:23.995+01:00","host_addr":"4.5.6.7","org_id":"oracle"} 

=head1 OPTIONS

=head2 path

The path to the log file. Single file can be listed here

    input {
        file {
            type alertlog
            path /u01/app/oracle/diag/rdbms/orcl/ORCL/alert/log.xml
        }
    }

=head2 skip

Define regexes to skip Oracle alert messages.

    input {
        file {
            type alertlog
            path /u01/app/oracle/diag/rdbms/orcl/ORCL/alert/log.xml
            skip ORA-0404(0|1)
            skip ^ORA-00600
        }
    }

Lines that match the regexes will be skipped.

=head2 grep

Define regexes to filter Oracle alert messages.

    input {
        file {
            type alertlog
            path /u01/app/oracle/diag/rdbms/orcl/ORCL/alert/log.xml
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

This methods reads the excepted number of lines or until the end of the
file and returns the lines as a array reference.

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

sub  trim { my $s = shift; $s =~ s/^\s+|\s+$//g; return $s };

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

sub pull {
    my ($self, %opts) = @_;

    local $SIG{PIPE} = "IGNORE";

    my $max_multiline_blocks = $opts{lines} || 1;
    my $lines = [ ];
    my $fhpos = $self->{fhpos};
    my $fhlog = $self->open_logfile
        or return undef;
        
	my $oldpos = $self->{multiline_lastpos} = tell ($fhlog);
    while (my $line = <$fhlog>) {
        $oldpos = $self->{multiline_lastpos}; 
    	$self->{multiline_lastpos} = tell ($fhlog);
    	$self->{multiline_lastreadtime} = Time::HiRes::gettimeofday();
        
        chomp $line;

        # typicall input message 
        #<msg time='2016-01-01T05:09:20.742+01:00' org_id='oracle' comp_id='rdbms'
        # type='UNKNOWN' level='16' host_id='my.dot.com'
        #host_addr='3.4.5.6'>
        #<txt>  Client address: (ADDRESS=(PROTOCOL=tcp)(HOST=1.2.3.4)(PORT=61166))
        #</txt>
        #</msg>
        
        $self->log->debug("new line read: $self->{multiline_status}") unless $self->{is_tns_multiline};
        		# search until prefix is matched than start with new multiline block
        		# drop non matching lines until next <msg.* is found
        		if ($self->{multiline_status} eq "find-start") {
        			if ($line =~ /<msg.*/) {
        				$self->{multiline_buffer} = "$line";
        				$self->{multiline_status} = "read-until-suffix";
        			} 
        			next;
        		}  
        		
        		# </msg> terminates the multiline block
				if ($line =~ /<\/msg>/) {
					$self->{multiline_buffer} .= "\n$line";
					my %msg = $self->convert_xmlalert_to_hash($self->{multiline_buffer});
					if (!$self->{is_tns_multiline}) {
						# start of tns multiline
						if ( $msg{"txt"} =~ /^\s*\*{71}/ ) {		
							$self->log->debug("Start of a new tns multiline");				    
							$self->{is_tns_multiline} = 1;
							$self->{tns_multiline_buffer} = \%msg;
						} 
						# plain simple alert log line
						else {					
							#$self->log->debug(encode_json \%msg);
							if ($self->check_event($msg{"txt"})) {
								push @$lines, encode_json \%msg;
							}
						}
					# continuation of tns multiline	
					} else {
						# another tns multiline following
						if ( $msg{"txt"} =~ /^\s*\*{71}/ ) {	
						 	$self->log->debug("Start of another tns multiline");
							if ($self->check_event($self->{tns_multiline_buffer}->{"txt"})) {
								push @$lines, encode_json $self->{tns_multiline_buffer};
							}						 	
							$self->{tns_multiline_buffer} = \%msg;
						}
						# continuation of the same tns message
						elsif ( $msg{"txt"} =~ /^\s.*|^TNS.*|^Fatal NI connect error.*/ ) {
							$self->log->debug("Continuation of tns multiline");
							$self->log->debug($msg{"txt"}	);
							$self->{tns_multiline_buffer}->{"txt"} .= $msg{"txt"};
						}
						# end of tns multiline	
						else {
							$self->log->debug("End of tns multiline");
							$self->{is_tns_multiline} = 0;
							if ($self->check_event($self->{tns_multiline_buffer}->{"txt"})) {
								push @$lines, encode_json $self->{tns_multiline_buffer};
							}								
						}
						
					}
        			$self->{multiline_buffer} = "";
        			$self->{multiline_status} = "find-start";
        			$self->{lastpos} = $self->{multiline_lastpos};
        		} else {
        			$self->{multiline_buffer} .= "\n$line";
        			next;        			
        		}               		

    	    #$self->log->debug("read", length($line), "bytes from file");
 	       last unless --$max_multiline_blocks;
    	}


	# Check if it's time to consider multiline msg complete (10 sec rule)
    if (defined $self->{multiline_lastreadtime} and
       Time::HiRes::gettimeofday() - $self->{multiline_lastreadtime} > 10) 
    {
        $self->log->debug("10 sec rule - flush multiline message buffer");
		my %msg = $self->convert_xmlalert_to_hash($self->{multiline_buffer});
		if (!$self->{is_tns_multiline}) {
			if ($self->check_event($msg{"txt"})) {
				push @$lines, encode_json \%msg;
			}	
		} else {
			if ($self->check_event($self->{tns_multiline_buffer}->{"txt"})) {
				push @$lines, encode_json $self->{tns_multiline_buffer};
			}
		}
    	push @$lines, $self->{multiline_buffer};
    	$self->{multiline_buffer} = undef;
    	$self->{multiline_status} = "find-start";    
    	$self->{lastpos} = $self->{multiline_lastpos};   
    	$self->{multiline_lastreadtime} = undef; 
    	$self->{is_tns_multiline} = 0;
    }


    if ($self->{fhpos}) {
        seek($fhpos, 0, 0);
        printf $fhpos "%014d:%014d", $self->{inode}, $self->{lastpos};
    }

    # If EOF is reached then the logfile should be
    # checked if the file was rotated.
    if ($max_multiline_blocks > 0) {
        $self->log->debug("reached end of file");
        $self->{reached_end_of_file}++;
    }

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

	my $attr_start = $msg_start + 4;
	my $attr_end = rindex ($msg, ">", $txt_start - 5) - 1;

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
	my @attrs = split(/'\s+>?/, substr($msg, $attr_start, $attr_end - $attr_start ));
	
	# construct hash with all the attribute elements 
	# split attrs to extrace key and value
	my %alertlog_json;
	foreach (@attrs) {
		my @attr = split(/='/, $_);
		# skip empty attributes
		if ($attr[1]) {
			$alertlog_json{trim($attr[0])} = trim($attr[1]);
 		}
 	}
 	
 	# add text field
 	$alertlog_json{"txt"} = substr($msg, $txt_start, $txt_end - $txt_start +1 );
		
	return %alertlog_json;
}

1;
