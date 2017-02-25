=head1 NAME

Awesant::Input::FileMultiline - Files as input with multiline option.

=head1 SYNOPSIS

    # Create a new tail-like object with multiline option.
    my $input = Awesant::Input::FileMultiline->new(
        path => "/inputs/alert.log",
        save_position => "yes", # experimental
        multiline_mode => "prefix-suffix",
        multiline_prefix => "<msg.*",
        multiline_suffix => "<\/msg>",
        multiline_drop_garbage => 1,        
    );
 
    # Pull the next 100 multiline records that were appended
    # to the log file.
    $input->pull(lines => 100);

=head1 DESCRIPTION

Log files as input. Log file rotation is supported, but note that
you should configure delayed compression for log files.

=head1 OPTIONS

=head2 path

The path to the log file. Single file can be listed here

    input {
        file {
            type alertlog
            path /inputs/alert.log
        }
    }

=head2 skip

Define regexes to skip events.

    input {
        file {
            type php-error-log
            path /var/log/php/error.log
            skip PHP (Notice|Warning)
            skip ^any event$
        }
    }

Lines that match the regexes will be skipped.

=head2 save_position

Experimental feature.

If the option save_position is set to true then the last position
with the inode of the log file is saved to a file. If Awesant is down
then it can resume its work where it was stopped. This is useful if you
want to lose as less data as possible of your log files.

Please note that this feature is experimental and does not keep log file
rotations.

=head2 multiline_mode

=head3 indented

This mode groups multiline messages together according the following rule:
- non indented row marks the start of a multiline message
- all indented line that follow are a part of this same message
- this multiline message ends when either a non indented row is read or 10 seconds have 
  passed since the last read  

	
=head3 indented_group

This mode groups multiline messages together according the following rule:
- non indented that matches multiline_prefix marks the start of a multiline message
- all indented lines that follow are a part of this same message
- next non indented row is also part of this message if it matches multiline_indented_group
  including all indented lines that follow
- this multiline message ends when either a non indented row not matching 
  multiline_indented_group is read or 10 seconds have passed since the last read  

Parameters:
    multiline_prefix = regular expression eg "\\*{71}"
    multiline_indented_group = regular expression eg "TNS.*|Fatal NI connect error.*"
	multiline_drop_garbage = yes|no|1|0

Comment:
This mode was explicitly crafted for parsing Oracle alertlog files which includes sqlnet
messages. 

=head3 prefix-garbage
This mode groups multiline messages together according the following rule:
- multiline message starts when multiline_prefix is found
- multiline message ends when either a new multiline_prefix is found or
  multiline_garbage has been matched or 
  10 seconds have passed since the last read 
- if multiline_drop_garbage was specified non matching lines are skipped
   
Parameters:
	multiline_prefix = regular expression eg "<Msg.*"
	multiline_garbage = regular expression eg "TNS.*"
	multiline_drop_garbage = yes|no|1|0

=head3 prefix-suffix
This mode groups multiline messages together according the following rule:
- multiline message starts when multiline_prefix is found
- multiline message ends when multiline_suffix is found

	multiline_prefix
	multiline_suffix
	multiline_drop_garbage

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


package Awesant::Input::FileMultiline;

use strict;
use warnings;
use Fcntl qw( :flock O_WRONLY O_CREAT O_RDONLY );
use Params::Validate qw();
use Log::Handler;

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

    # internal state of multiline message:
    # find-start 
    # read-until-suffix, read-until-prefix
    # read-until-nonindent
    $self->{multiline_status} = "find-start";
    
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

    	# find-start 
    	# read-until-suffix, read-until-prefix
    	# read-until-nonindent
        if ($self->check_event($line)) {
        	if ($self->{multiline_mode} eq "indented") {
        		# drop lines until first non-indented line
        		# than start with new multiline block
        		if ($self->{multiline_status} eq "find-start") {
        			if ($line !~ /^\s.*/) {
        				$self->{multiline_buffer} = "$line";
        				$self->{multiline_status} = "read-until-nonindent";
        			}
        			next;
        		} 
        		# if line is indented put it into buffer
        		# otherwise we have a new multiline block and can start a new one 
        		if ($line =~ /^\s.*/) {
        			 $self->{multiline_buffer} .= "\n$line";
        			 next;
        		} else {
        			push @$lines, $self->{multiline_buffer};
        			$self->{lastpos} = $oldpos;
        			$self->{multiline_buffer} = "$line";
        		}
            
        	} elsif ($self->{multiline_mode} eq "indented-group") {       	
        		# search until first non-indented line to start multiline block
        		# drop lines until first non-indented line if multiline_drop_garbage
        		# has been specified
        		if ($self->{multiline_status} eq "find-start") {
        			if ($line =~ /$self->{multiline_prefix}/) {       			
        				$self->{multiline_buffer} = "$line";
        				$self->{multiline_status} = "read-until-nonindent";
        			} elsif (defined $self->{multiline_drop_garbage} and !$self->{multiline_drop_garbage}) {        			
        				push @$lines, $line;
        				$self->{lastpos} = $self->{multiline_lastpos};
        			}   
        			next;
        		} 
        		
        		# if line is indented put it into buffer
        		if ($line =~ /^\s.*/) {
        			 $self->{multiline_buffer} .= "\n$line";
        			 next;
        		# otherwise check if it matches multiline_indented_group
        		} elsif ($line =~ /$self->{multiline_indented_group}/) {
        			 $self->{multiline_buffer} .= "\n$line";
        			 next;
        		} elsif (defined $self->{multiline_drop_garbage} and !$self->{multiline_drop_garbage}) {
        			push @$lines, $self->{multiline_buffer};
        			push @$lines, $line;
        			$self->{multiline_buffer} = "";
        			$self->{multiline_status} = "find-start";
        			$self->{lastpos} = $self->{multiline_lastpos};        			
        		} else {
        			push @$lines, $self->{multiline_buffer};
        			$self->{multiline_buffer} = "";
        			$self->{multiline_status} = "find-start";
        			$self->{lastpos} = $self->{multiline_lastpos};        			
        		}

        		
        	} elsif ($self->{multiline_mode} eq "prefix-garbage") {
        		# search until prefix is matched than start with new multiline block
        		# drop non matching lines if multiline_drop_garbage has been specified
        		if ($self->{multiline_status} eq "find-start") {
        			if ($line =~ /$self->{multiline_prefix}/) {
        				$self->{multiline_buffer} = "$line";
        				$self->{multiline_status} = "read-until-prefix";
        			} elsif (defined $self->{multiline_drop_garbage} and !$self->{multiline_drop_garbage}) {
        				push @$lines, $line;
        				$self->{lastpos} = $self->{multiline_lastpos};
        			}  
        			next;
        		}  
        		
        		# ignore lines matching multiline-garbage and next multiline-prefix
        		if (defined $self->{multiline_garbage} and $line =~ /$self->{multiline_garbage}/) {
        			push @$lines, $self->{multiline_buffer};
        			$self->{multiline_buffer} = "";
        			$self->{multiline_status} = "find-start";
        			$self->{lastpos} = $oldpos;
        			if (defined $self->{multiline_drop_garbage} and !$self->{multiline_drop_garbage}) {
        				push @$lines, $line;
        				$self->{lastpos} = $self->{multiline_lastpos};
        			}
        		} elsif ($line =~ /$self->{multiline_prefix}/) {
        			push @$lines, $self->{multiline_buffer};
        			$self->{multiline_buffer} = "$line";
        			$self->{lastpos} = $oldpos;
        		} else {
        			$self->{multiline_buffer} .= "\n$line";
        			next;        			
        		}       		        	
        		
        	} elsif ($self->{multiline_mode} eq "prefix-suffix") {
        		# search until prefix is matched than start with new multiline block
        		# drop non matching lines if multiline_drop_garbage has been specified
        		if ($self->{multiline_status} eq "find-start") {
        			if ($line =~ /$self->{multiline_prefix}/) {
        				$self->{multiline_buffer} = "$line";
        				$self->{multiline_status} = "read-until-suffix";
        			} elsif (defined $self->{multiline_drop_garbage} and !$self->{multiline_drop_garbage}) {
        				push @$lines, $line;
        				$self->{lastpos} = $self->{multiline_lastpos};
        			}  
        			next;
        		}  
        		
				if ($line =~ /$self->{multiline_suffix}/) {
					$self->{multiline_buffer} .= "\n$line";
        			push @$lines, $self->{multiline_buffer};
        			$self->{multiline_buffer} = "";
        			$self->{multiline_status} = "find-start";
        			$self->{lastpos} = $self->{multiline_lastpos};
        		} else {
        			$self->{multiline_buffer} .= "\n$line";
        			next;        			
        		}               		
        	}

        }

        #$self->log->debug("read", length($line), "bytes from file");
        last unless --$max_multiline_blocks;
    }


	# Check if it's time to consider multiline msg complete (10 sec rule)
    if ($self->{multiline_status} ne "find-start" and 
        defined $self->{multiline_lastreadtime} and
       	Time::HiRes::gettimeofday() - $self->{multiline_lastreadtime} > 10
       ) 
    {
        $self->log->debug("10 sec rule - flush multiline message buffer");
    	push @$lines, $self->{multiline_buffer};
    	$self->{multiline_buffer} = undef;
    	$self->{multiline_status} = "find-start";    
    	$self->{lastpos} = $self->{multiline_lastpos};   
    	$self->{multiline_lastreadtime} = undef; 
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
        },
        # A message is considered complete if no new lines arrive to the message 
        # for 10 seconds, even if no line matching the multi-line-garbage() or 
        # the multi-line-suffix() option is received.
        multiline_mode => {
            type => Params::Validate::SCALAR,  
            default => undef,
            regex => qr/^(indented|indented-group|prefix-garbage|prefix-suffix)\z/
        },
        multiline_prefix => {
            type => Params::Validate::SCALAR,
            default => undef
        }, 
        multiline_suffix => {
            type => Params::Validate::SCALAR,
            default => undef
        },             
        multiline_garbage => {
            type => Params::Validate::SCALAR,
            default => undef
        },
        multiline_drop_garbage => {
            type => Params::Validate::SCALAR,
            default => 1,
            regex => qr/^(?:yes|no|1|0)\z/
        },      
        multiline_indented_group => {
            type => Params::Validate::SCALAR,
            default => undef
        }, 
        multiline_ignore_newline => {
            type => Params::Validate::SCALAR,
            default => 1,
            regex => qr/^(?:yes|no|1|0)\z/
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

    if ($options{multiline_drop_garbage} eq "no") {
        $options{multiline_drop_garbage} = 0;
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

1;
