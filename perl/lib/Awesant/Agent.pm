=head1 NAME

Awesant::Agent - Ships log files for logstash.

=head1 SYNOPSIS

    Awesant::Agent->run(
        config  => $path_to_configuration,
        pidfile => $path_to_pid_file,
    );

=head1 DESCRIPTION

Awesant is a simple log file shipper for logstash.

It ships log files and sends the data to different transports.

All what you have to do is to call the method C<run> with its expected options.

=head1 METHODS

=head2 run

Start the shipping machine.

Nothing more is there for you to do. That means that you shouldn't touch the
other methods in this module.

=head2 load_output

Load the output modules that are used by configuration.

As example if C<redis> is defined as transport in the output section

    output {
        redis {
            ...
        }
    }

then Awesant is looking for a module called C<Awesant::Output::Redis>.
If you would define a section call C<foo>, then Awesant would try to
C<require> the module C<Awesant::Output::Foo>.

=head2 load_input

The method C<load_input> does in the first step the same like C<load_output>.
It looks for input modules. As example if the input C<file> is configured,
then it tries to load the module C<Awesant::Input::File>.

As next each output module that was pre-loaded is bound to the inputs.
This is done using the parameter C<type>.

=head2 load_module

This method just includes the input and output modules and is called by
C<load_output> and C<load_input>. The process to load the modules is really
simple.

As example if the following sections are configured:

    output {
        redis {
            ...
        }
    }

then the module is loaded as follows:

    my $input_or_output = "output"; # output is the first section
    my $transport = "redis";        # redis is the configured transport

    my $module = join("::",
        "Awesant",
        ucfirst($input_or_output),
        ucfirst($transport)
    );

    require $module;

All clear? :-)

=head2 daemonize

Start the endless loop and calls C<run_agent> in an eval block.

=head2 run_agent

This method is just a wrapper and calls C<run_log_shipper> in an eval block.

=head2 run_server

This methods creates some process groups for each input and just calls C<run_agent>
for each group after the workers are forked.

=head2 run_log_shipper

The main logic of the Awesant agent. It requests the inputs for data to
forward the data to the outputs.

=head2 prepare_message

Each log line is passed to C<prepare_message> and which adds additional
fields and returns hash ready for shipment to output

=head2 send_events_to_output

Sends events prepared by prepare_message to one output.
If output supports batch sending it pushes events in batches of window_size.
Otherwise pushes events to output one by one.

=head2 log_watch

Watch continuous for new log files if a path contains a wildcard.

=head2 reap_children

Reap died sub processes.

=head2 spawn_children

Fork new children if less children than the configured workers are running.

=head2 kill_children

Kill all children on signal term.

=head2 sig_child_handler

A handler to reap children.

=head2 get_config

Load the configuration from a file.

Removes the PID file.

=head2 create_logger

Create the logger object. As logger C<Log::Handler> is used.

=head2 validate_config, validate_agent_config, validate_add_field_match

Validate the configuration.

=head2 config

Just an accessor to the configuration.

=head2 log

Just an accessor to the logger.

=head1 PREREQUISITES

    Log::Handler
    Params::Validate
    JSON
    POSIX
    Sys::Hostname
    Time::HiRes
    Class::Accessor::Fast

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <support(at)bloonix.de>.

=head1 AUTHOR

Jonny Schulz <support(at)bloonix.de>.

=head1 COPYRIGHT

Copyright (C) 2012 by Jonny Schulz. All rights reserved.

=cut

package Awesant::Agent;

use strict;
use warnings;
use Log::Handler;
use Params::Validate qw();
use JSON;
use POSIX qw(:sys_wait_h);
use Sys::Hostname;
use Time::HiRes qw();
use Awesant::Config;
use Awesant::HangUp;
use Data::Dumper;
use base qw(Class::Accessor::Fast);

# On Windows fork() is not really available.
# If the agent will be started on windows
# then awesant runs only as single process.
# TODO: implement threading?
use constant IS_WIN32 => $^O =~ /Win32/i;

# Only the parent is allowed to do some actions.
# For this reason the pid of the parent is safed.
use constant PARENT_PID => $$;

# Just some simple accessors
__PACKAGE__->mk_accessors(qw/config log json watch filed inputs outputs/);

our $VERSION = "0.22";

sub run {
    my ($class, %args) = @_;

    my $self = bless {
        args    => \%args, # the command line arguments
        done    => 0,      # a flag to stop the daemon on some signals
        child   => { },    # store the pids of each child
        reaped  => { },    # store the pids of each child that was reaped
        inputs  => [ ],    # store the inputs as process groups
        outputs => { },    # store the outputs in a hash ref by type
        watch   => 0,      # store the files to watch for each process group
        filed   => 0,      # store the files already watched for each process group
        json    => JSON->new->utf8()
    }, $class;

    # Store all input types. This is necessary to
    # bind wildcard outputs to all input types.
    $self->{input_types} = { };

    # Parse the configuration
    $self->get_config;
    $self->create_logger;

    # Check if screen output is defined.
    my $output_config = $self->config->{output};
    if ($output_config->{screen}) {
        Awesant::HangUp->now(pid_file => $self->{args}->{pidfile}, dev_null => 0);
    } else {
        Awesant::HangUp->now(pid_file => $self->{args}->{pidfile}, dev_null => 1);
    }

    # Run Awesant
    $self->load_input;
    $self->load_output;
    $self->daemonize;
}

sub load_output {
    my $self = shift;
    my $outputs = $self->config->{output};

    $self->log->info("loading output plugins");

    foreach my $output (keys %$outputs) {
        # At first the output module is required.
        # Example: redis => Awesant/Output/Redis.pm
        $self->log->info("Loading output plugin $output");
        my $module = $self->load_module(output => $output);
        $self->log->info("Output plugin $output loaded ($module)");

        foreach my $config (@{$outputs->{$output}}) {
            # Option "type" is used by the agent and must be
            # deleted from the output configuration.
            my $types = delete $config->{type};

            # Type is an mandatory parameter. The type is overwritten
            # if incoming json_events has @type set.
            if (!defined $types) {
                die "missing mandatory parameter 'type' of output '$output'";
            }

            if (!length $types) {
                die "no value passed for parameter 'type' of output '$output'";
            }

            # Create a new output object.
            my $object = $module->new($config);

            $types =~ s/\s+//;
            $types =~ s/\s+\z//;

            # Multiple types are allowed for outputs.
            foreach my $type (split /,/, $types) {
                $type =~ s/^\s+//;
                $type =~ s/\s+\z//;
                push @{$self->outputs->{$type}}, $object;
            }
        }
    }
    
    $self->log->info("loading output plugins complete");
}

sub load_input {
    my $self = shift;
    my $input_config = $self->config->{input};
    my $no_worker_inputs;

    $self->log->info("load input plugins");

    foreach my $input_type (keys %$input_config) {
        # At first load the input modules.
        # Example: file => Awesant/Input/File.pm
        my $module = $self->load_module(input => $input_type);

        foreach my $plugin_config (@{$input_config->{$input_type}}) {
            my $input_group;

            # Shift the agent configuration parameter.
            my %agent_config;
            foreach my $param (qw/type tags add_field workers format/) {
                if (exists $plugin_config->{$param}) {
                    $agent_config{$param} = delete $plugin_config->{$param};
                }
            }

            # If the add_field value is a hash then it can contains code
            # instead of a simple string. In this case the code must be
            # executed for every json event.
            if (ref $agent_config{add_field} eq "HASH") {
                foreach my $field (keys %{$agent_config{add_field}}) {
                    if (ref $agent_config{add_field}{$field} eq "HASH") {
                        $agent_config{__add_field}{$field} = delete $agent_config{add_field}{$field};
                    }
                }
            }

            # A path should be set.
            $agent_config{path} = $plugin_config->{path} || "/";

            if ($agent_config{workers}) {
                $input_group = {
                    watch => [ ], filed => { }, inputs => [ ],
                    workers => $agent_config{workers}
                };
                push @{$self->inputs}, $input_group;
            } else {
                $no_worker_inputs ||= { watch => [ ], filed => { }, inputs => [ ], workers => 1 };
                $input_group = $no_worker_inputs;
            }

            # The file input can only process a single file, but if a wildcard
            # is used within the path or a comma separated list of files is passed
            # then it's necessary to create an input object for each file.
            if (lc $input_type eq "file" or lc $input_type eq "filemultiline" or lc $input_type eq "oraclealertlogxml") {
                if ($input_group->{workers} && $input_group->{workers} > 1) {
                    $self->log->info("set workers for input $input_type to 1");
                    $input_group->{workers} = 1;
                }

                foreach my $path (split /,/, $plugin_config->{path}) {
                    $path =~ s/^\s+//;
                    $path =~ s/\s+\z//;

                    # Store the path to watch for new files if the path
                    # contains a wildcard. If a new file is found then
                    # a new input object will be created.
                    push @{$input_group->{watch}}, {
                        module        => $module,
                        watch_path    => $path,
                        plugin_config => { %$plugin_config },
                        agent_config  => { %agent_config },
                    };

                    while (my $file = glob $path) {
                        # Clone the configuration for each file input.
                        my %p = %$plugin_config;
                        my %a = %agent_config;
                        $p{path} = $a{path} = $file;

                        # Store the file name to skip the file from watching.
                        $input_group->{filed}->{$file} = time;

                        my $validated = $self->validate_agent_config(\%a);
                        $validated->{time} = scalar Time::HiRes::gettimeofday();
                        $validated->{object} = $module->new(\%p);
                        $validated->{remove_on_errors} = 1;
                        push @{$input_group->{inputs}}, $validated;
                        $self->{input_types}->{ $validated->{type} }++;
                    }
                }
            } else {
                my $validated = $self->validate_agent_config(\%agent_config);
                $validated->{time} = scalar Time::HiRes::gettimeofday();
                $validated->{object} = $module->new($plugin_config);
                push @{$input_group->{inputs}}, $validated;
                $self->{input_types}->{ $validated->{type} }++;
            }
        }
    }

    if ($no_worker_inputs) {
        push @{$self->inputs}, $no_worker_inputs;
    }
}

sub load_module {
    my ($self, $io, $type) = @_;

    # localize SIG __DIE__ due to problems when loading XSLoader.pm
    # Can't locate object method "tid" via package "threads" at /usr/share/perl5/XSLoader.pm line 92.
    local $SIG{__DIE__};	
	
    # output { redis { } }
    #   = Awesant::Output::Redis
    my $module = join("::",
        "Awesant",
        ucfirst($io),
        ucfirst($type),
    );

    eval "require $module";
    
    if ($@) {
        # The module name may be uppercase.
        # output { tcp { } }
        #    = Awesant::Output::TCP
        $module = join("::",
            "Awesant",
            ucfirst($io),
            uc($type),
        );
    	eval "require $module";
        die $@ if $@;
    }

    $self->log->debug("Load_module return $module");
    return $module;
}

sub daemonize {
    my $self = shift;

    # Ignoring sig hup and pipe by default, because we have no
    # reload mechanism and don't want to break on pipe signals.
    $SIG{HUP} = $SIG{PIPE} = "IGNORE";

    # If one of the following signals are catched then the daemon
    # should stop normally and reap all children first.
    $SIG{TERM} = $SIG{INT} = sub { $self->{done} = 1 };

    # When to run the next log watch
    $self->{next_watch_time} = time + $self->config->{log_watch_interval};

    if (IS_WIN32) {
        $self->run_agent;
    } else {
        $self->run_server;
    }
}

sub run_server {
    my $self = shift;
    my $child = $self->{child};
    my $reaped = $self->{reaped};

    # Handle died children.
    $SIG{CHLD} = sub { $self->sig_child_handler(@_); };
    while ($self->{done} == 0) {
        # Reap died children.
        $self->reap_children;
        # Spawn new children.
        $self->spawn_children;

        foreach my $group (0..$#{ $self->inputs }) {
            my $input_group = $self->inputs->[$group];
            $self->log->debug(
                scalar keys %{$input_group->{child}},
                "processes running for process group $group:",
                keys %{$input_group->{child}},
            );
        }

        # Sleep a while
        Time::HiRes::usleep(500_000);
    }
    $self->kill_children;
}

sub run_agent {
    my $self = shift;

    while ($self->{done} == 0) {
        eval { $self->run_log_shipper };

        if ($self->{done} == 0) {
            sleep 1;
        }
    }
}

# send $events to $output
# return number of unsent events:
#   return value = 0 => all events successfully sent
#   return value > 0 => there was an error sending events to output
sub send_events_to_output {
    my ($self, $output, $events, $otype) = @_;

    # max window size of output
    # if not defined default is 1
    my $output_windows_size = $output->{max_window_size};
    if (!defined $output_windows_size) {
        $output_windows_size = -1;
    }
                          
    my $num_of_events = $#{$events}+1;
	my $num_of_shipped = 0;     
    $self->log->info( "Output $otype using $output preparing to ship $num_of_events event(s)");
    while ($num_of_events > $num_of_shipped ) {   
    	# for compatibility with older outputs don't push windows size 1 as array 
    	# encode as json string
    	if ($output_windows_size == -1) {
        	if ( !$output->push($self->json->encode($events->[$num_of_shipped])) ) {
				$self->log->error("Output $otype using " . ref($output) . " returns an error ");
                last;
            }
            $self->log->info( "Output $otype using $output shiped 1 event");
            $num_of_shipped = $num_of_shipped + 1;
        
        # number of events is less then or equal to max_window_size	                		
        } elsif ($#{$events}+1 <= $output_windows_size ) {    
            if ( !$output->push( [@{$events}] )) {
				$self->log->error("Output $otype using " . ref($output) . " returns an error");
                last;
            }
            $self->log->info( "Output $otype using $output shiped " . ($#{$events} + 1) . " event(s) (num of shiped events is less or equal to max windows size)");
            $num_of_shipped = $num_of_shipped + $#{$events} + 1;
                    	
        # number of events is more then max_window_size	   	
        } else {
            if ( !$output->push([@{$events}[$num_of_shipped..$output_windows_size-1]] ) ) {
				$self->log->error("Output $otype using " . ref($output) . " returns an error");
                last;
            }
            $self->log->info( "Output $otype using $output shiped $output_windows_size events equal to windows size");
            $num_of_shipped += $output_windows_size;
        }
    }         

	return $num_of_events - $num_of_shipped;
}

sub run_log_shipper {
    my $self = shift;
    my $poll = $self->config->{poll} / 1000;
    my $inputs = $self->inputs;
    my $outputs = $self->outputs;
    my $max_lines = $self->config->{lines};
    my $messurement = Time::HiRes::gettimeofday();
    my $count_lines = 0;
    my $count_bytes = 0;
    my $benchmark = $self->config->{benchmark};
    my (%failed, @destroy_inputs);

    while ($self->{done} == 0) {
        # Watch for new log files.
        if ($self->watch) {
            $self->log_watch;
        }

        # Destroy file inputs that returns an error.
        foreach my $num (sort {$b <=> $a} @destroy_inputs) {
            my $destroy = splice(@$inputs, $num, 1);
            my $filed = $destroy->{path};
            delete $self->filed->{$filed};
            $self->log->info("destroyed file '$filed'");
        }

        # Cleanup the array
        @destroy_inputs = ();

        # If no lines was received, then the agent should
        # sleep for a while - low cost cpu :-)
        my $time = Time::HiRes::gettimeofday() + $poll;

        # otype = output type
        # itype = input type
        #
        # If an event couldn't be send, then all left lines are
        # stored with the output object to the %failed hash and
        # the type of the input is used as the hash key.
        # If the hash %failed is not empty, then all inputs with
        # no type and all input types that are stored in %failed
        # will be skipped until %failed is empty. That means that
        # no events will be read from the inputs.
        foreach my $input_num (0..$#{$inputs}) {
            my $input = $inputs->[$input_num];

            # Some data for benchmarks. The count of lines and bytes are printed each second.
            if ($benchmark) {
                my $delta = sprintf("%.6f", Time::HiRes::gettimeofday() - $messurement);
                if ($delta > 1) {
                    $count_bytes = sprintf("%.3fM", $count_bytes > 0 ? $count_bytes / 1_048_576 : 0);
                    $self->log->notice("processed $count_lines lines / $count_bytes bytes in $delta seconds");
                    $messurement = Time::HiRes::gettimeofday();
                    $count_lines = 0;
                    $count_bytes = 0;
                }
            }

            # Check if it's time to process the input.
            if ($input->{time} - Time::HiRes::gettimeofday() > 0) {
                next;
            }

            # The type of the input. Note that the type can be
            # overwritten if the input format is a json event.
            my $itype = $input->{type};
            my $ipath = $input->{path};

            # If there are errors detected and no type is set,
            # then shipping log data is blocked for inputs
            # with no type until %failed is empty.
            if (!defined $itype && scalar keys %failed) {
                next;
            }

            # If there exists errors for this type, then the stored
            # lines must be flushed to the outputs first.
            if ($failed{$itype}) {
                $self->log->info("found failed events for input type $itype");
                
                # Process each failed output until no further outputs exists.
                while (my $ref = shift @{$failed{$itype}}) {
                    my $output = $ref->{output};
                    my $otype  = $ref->{type};
                    my $num_of_unsent  = 0;
                    my $num_of_events = scalar @{$ref->{events}};

                    # Process events
                    $self->log->info(
                        "try to process",
                        scalar @{$ref->{events}},
                        "event(s) for output type $otype",
                    );
                    
                    $num_of_unsent = $self->send_events_to_output($output, $ref->{events}, $otype);

                    if ($num_of_unsent == 0) {
                        $self->log->notice(
                            "output $otype is reachable again -",
                            "flushed $num_of_events event(s)"
                        );
                    }

                    # If it wasn't possilbe to ship all events then the
                    # output returns an error. In this case the output
                    # is stored back to the %failed hash.
                    if ($num_of_unsent > 0 ) {
                        # The error message should only be logged if the output died again.
                        if ($num_of_unsent == $num_of_events) {
                            $self->log->error(
                                "output $otype returns an error again -",
                                "held $num_of_unsent event(s) in stash"
                            );
                        }
                        splice( @{$ref->{events}}, 0, $num_of_events - $num_of_unsent );
                        unshift @{$failed{$itype}}, $ref; 
                        last;
                    }
                }

                # If no items left, then the input type can be deleted
                # and processed again in the next run.
                if (!@{$failed{$itype}}) {
                    delete $failed{$itype};
                }

                # Process the next input.
                next;
            }

            # Get events from the input.
            $self->log->debug("pull lines from input type $itype path $ipath");
            my $lines = $input->{object}->pull(lines => $max_lines);

            if (!defined $lines && $input->{remove_on_errors}) {
                $self->log->info("input type $itype path $ipath returns undef, object will be destroyed");
                push @destroy_inputs, $input_num;
            }

            # If no lines exists, just jump to the next input and
            # process the input at time + poll.
            if (!$lines || !@$lines) {
                $input->{time} = Time::HiRes::gettimeofday() + $poll;
                next;
            }

            # If the input return events then the global interval
            # is set to now, so the sleep value should be 0.
            $time = Time::HiRes::gettimeofday();
            $self->log->debug("pulled", scalar @$lines, "lines from input type $itype path $ipath");
			$self->log->info("pulled", scalar @$lines, "lines from input type $itype path $ipath");

            # Process each line to event and store each event by the output type.
            my %prepared_events;
            while (my $line = shift @$lines) {
                my ($otype, $event) = $self->prepare_message($input, $line)
                    or next;
                push @{$prepared_events{$otype}}, $event;
            }
         
            $self->log->info("prepared events for shipment to output");

			# iterate over output types and send events to output
            foreach my $otype (keys %prepared_events) {
                my @outputs;

				# find which outputs are registered for this otype
                foreach my $ot ($otype, "*") {
                    if (exists $outputs->{$ot}) {
                        push @outputs, @{$outputs->{$ot}};
                    }
                }

                if (!@outputs) {
                    $self->log->warning(
                        "received events from input type $itype",
                        "with an non existent output type $otype"
                    );
                    next;
                }

				# loop over outputs and ship array of events
                my $events = $prepared_events{$otype};
                foreach my $output (@outputs) {
                    my $num_of_unsent  = 0;
                    my $num_of_events = scalar @{$events};
                
                    $num_of_unsent = $self->send_events_to_output($output, $events, $otype);

                    if ($num_of_unsent == 0) {
                        $self->log->info( "output $otype shiped $num_of_events event" );
                    }

                    # If it wasn't possilbe to ship all events then the
                    # output returns an error. In this case the output
                    # is stored back to the %failed hash.
                    if ($num_of_unsent > 0 ) {
                            $self->log->error(
                                "output $otype returns an error ",
                                "push $num_of_unsent event(s) to stash"
                            );
                            
		                       	push @{$failed{$itype}}, {
                                	type   => $otype,
                                	output => $output,
                                	events  => [ @{$events}[($num_of_events-$num_of_unsent)..($num_of_events-1)] ],
                            	};
                    }
                    
                    
                }
                # all events for this output type where shipped, continue to the next output type
                
            }
        }

        $time -= Time::HiRes::gettimeofday();

        if ($time > 0 && $self->{done} == 0) {
            $self->log->debug(sprintf("sleep for %.6f seconds", $time));
            Time::HiRes::usleep($time * 1_000_000);
        }
    }
}

sub prepare_message {
    my ($self, $input, $line) = @_;
    my ($event, $type, $timestamp);
    my $hostname = $self->config->{hostname};

    my ($type_alias, $tags_alias, $fields_alias) = ('type', 'tags', 'fields');

    if ($input->{format} eq "json") {
        eval { $event = $self->json->decode($line) };
        if ($@) {
            $self->log->error("unable to decode json event for input $input->{type}:", $@);
            $self->log->error($line);
            return ();
        }
        $event->{$type_alias} ||= $input->{type};
        push @{$event->{$tags_alias}}, @{$input->{tags}};
        foreach my $field (keys %{$input->{add_field}}) {
                $event->{$field} = $input->{add_field}->{$field};
        }
    } elsif ($input->{format} eq "plain") {
        my ($seconds, $microseconds) = Time::HiRes::gettimeofday();

		# cache timestampe (in case of event bursts)
        if (defined $self->{seconds} && $seconds == $self->{seconds}) {
        	$timestamp = $self->{timestamp};
        } else {
        	$self->{seconds} = $seconds;
        	$timestamp = POSIX::strftime("%Y-%m-%dT%H:%M:%S", gmtime($seconds)) . "." . substr($microseconds,0,3) . "Z";      	
        	$self->{timestamp} = $timestamp;
        }

		# plain input can be a simple text line or perl hash
        	if (not ref $line) {
	            $event = {
    	            '@version'    => 1,
        	        '@timestamp'  => $timestamp,
            	    'source'      => "file://" . $hostname . $input->{path},
                	'host' 		  => $hostname,
	                'file' 		  => $input->{path},
    	            'type'        => $input->{type},
        	        'tags'        => $input->{tags},
            	    'line'     	  => $line, # "Line" is obligatory element!!!
            	};
            } else {
	            $event = $line;
    	        $event->{'@version'}    = 1;
        		$event->{'@timestamp'}  = $timestamp;
            	$event->{"source"}      = "file://" . $hostname . $input->{path} unless $event->{"source"} ;
            	$event->{"host"} 		= $hostname unless $event->{"host"};
	            $event->{"file"} 		= $input->{path} unless $event->{"file"};
    	        $event->{"type"}        = $input->{type} unless $event->{"type"};
        	    $event->{"tags"}        = $input->{tags} unless $event->{"tags"};
            	
            }

            foreach my $key (keys %{$input->{add_field}}) {
                $event->{$key} = $input->{add_field}->{$key};
            }
    
    };

    if ($input->{__add_field}) {
        foreach my $code (@{$input->{__add_field_code}}) {
            &$code($event);
        }
    }

	# return event as PERL object
    return ($event->{$type_alias}, $event);
}

sub log_watch {
    my $self = shift;
    my $watch = $self->watch;
    my $filed = $self->filed;
    my $inputs = $self->inputs;

    if ($self->{next_watch_time} > time) {
        return;
    }

    # Update the time for the next run
    $self->{next_watch_time} = time + $self->config->{log_watch_interval};
    $self->log->debug("watch for new log files");

    foreach my $to_watch (@$watch) {
        my $path = $to_watch->{watch_path};
        my $module = $to_watch->{module};
        my $plugin_config = $to_watch->{plugin_config};
        my $agent_config = $self->validate_agent_config($to_watch->{agent_config});

        while (my $file = glob $path) {
            if (!exists $filed->{$file}) {
                my %p = %$plugin_config;
                my %a = %$agent_config;
                $p{path} = $a{path} = $file;
                $p{start_position} = "begin";
                $a{remove_on_errors} = 1;
                $a{time} = scalar Time::HiRes::gettimeofday();
                $a{object} = $module->new(\%p);
                push @$inputs, \%a;
                $filed->{$file} = time;
            }
        }
    }
}

sub get_config {
    my $self = shift;

    my $config = Awesant::Config->parse(
        $self->{args}->{config}
    );

    $self->{config} = $self->validate_config($config);
}

sub create_logger {
    my $self = shift;

    $self->{log} = Log::Handler->create_logger("awesant");

    if ($self->config->{logger}) {
        $self->{log}->config(config => $self->config->{logger});
    }

    # For debugging.
    $SIG{__DIE__}  = sub { $self->log->trace(error   => @_) };
    $SIG{__WARN__} = sub { $self->log->trace(warning => @_) };
}

sub spawn_children {
    my $self = shift;

    foreach my $group (0..$#{ $self->inputs }) {
        my $input_group = $self->inputs->[$group];
        my $current_worker = scalar keys %{$input_group->{child}};
        my $wanted_worker = $input_group->{workers};

        if ($current_worker < $wanted_worker) {
            for (1..$wanted_worker - $current_worker) {
                # Fork a new child.
                my $pid = fork;

                if ($pid) {
                    # If $pid is set, then it's the parent.
                    $self->{child}->{$pid} = $input_group;
                    # The pid is stored to the process group just to
                    # count how many processes are running for the group.
                    $input_group->{child}->{$pid} = $pid;
                    # Hoa yeah! A new perl machine was born! .-)
                    $self->log->info("forked child $pid for input group $group");
                } elsif (!defined $pid) {
                    # If the $pid is undefined then fork failed.
                    die "unable to fork - $!";
                } else {
                    # If the pid is defined then it's the child.
                    eval {
                        $self->filed($input_group->{filed});
                        $self->watch($input_group->{watch});
                        $self->inputs($input_group->{inputs});
                        $self->run_agent;
                    };
                    exit($? ? 9 : 0);
                }
            }
        }
    }
}

sub reap_children {
    my $self = shift;
    my $child = $self->{child};
    my $reaped = $self->{reaped};
    my @reaped = keys %$reaped;

    foreach my $pid (@reaped) {
        my $input_group = delete $child->{$pid};
        delete $input_group->{child}->{$pid};
        delete $reaped->{$pid};
    }
}

sub kill_children {
    my $self  = shift;
    my $child = $self->{child};
    my @chld  = keys %$child;

    # Don't TERM the daemon. At first we reap all children.
    local $SIG{TERM} = "IGNORE";

    # Give the children 15 seconds time to stop.
    my $wait = time + 15;

    # Try to kill the agents soft.
    $self->log->info("send sig term to children", @chld);
    kill 15, @chld;

    while (@chld && $wait > time) {
        $self->log->info("wait for children", @chld);
        sleep 1;
        $self->reap_children;
        @chld = keys %$child;
    }

    # All left children will be killed hard.
    if (scalar keys %$child) {
        @chld = keys %$child;
        $self->log->info("send sig kill to children", @chld);
        kill 9, @chld;
    }
}

sub sig_child_handler {
    my $self = shift;

    while ((my $child = waitpid(-1, WNOHANG)) > 0) {
        if ($? > 0) {
            $self->log->error("child $child died: $?");
        } else {
            $self->log->notice("child $child died: $?");
        }

        # Store the PID to delete the it later from $self->{child}
        $self->{reaped}->{$child} = $child;
    }

    $SIG{CHLD} = sub { $self->sig_child_handler(@_) };
}

sub validate_config {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        poll => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:[1-9]\d\d\d|[1-9]\d\d)\z/,
            default => 500,
        },
        lines => {
            type => Params::Validate::SCALAR,
            default => 100,
        },
        hostname => {
            type => Params::Validate::SCALAR,
            default => Sys::Hostname::hostname(),
        },
        output => {
            type => Params::Validate::HASHREF,
        },
        input => {
            type => Params::Validate::HASHREF,
        },
        logger => {
            type => Params::Validate::HASHREF,
            optional => 1,
        },
        benchmark => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:yes|no|0|1)\z/,
            default => 0,
        },
        log_watch_interval => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
            default => 5,
        },       
    });

    foreach my $key (qw/benchmark/) {
        if ($options{$key} eq "no") {
            $options{$key} = 0;
        }
    }

    foreach my $key (qw/output input/) {
        my $ref = $options{$key};
        foreach my $type (keys %$ref) {
            if (ref $ref->{$type} eq "HASH") {
                $ref->{$type} = [ $ref->{$type} ];
            }
        }
    }

    return \%options;
}

sub validate_agent_config {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        type => {
            type => Params::Validate::SCALAR,
        },
        tags => {
            type => Params::Validate::SCALAR
                    | Params::Validate::ARRAYREF,
            default => [ ],
        },
        format => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:plain|json_event|json)\z/,  
            default => "plain",
        },
        add_field => {
            type => Params::Validate::SCALAR
                    | Params::Validate::HASHREF
                    | Params::Validate::ARRAYREF,
            default => { },
        },
        __add_field => {
            type => Params::Validate::HASHREF,
            optional => 1,
        },
        path => {
            type => Params::Validate::SCALAR,
            default => "/",
        },
        workers => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
            default => 0,
        },        
    });

    if ($options{format} eq "json_event") {
        $options{format} = "json";
    }

    # add_field => {
    #     domain => {
    #         key    => '@source_path',
    #         match  => "([a-z]+\.[a-z]+)/([a-z]+)/[^/]+$",
    #         concat => "$2.$1",
    #     }
    # }

    if (defined $options{add_field}) {
        if (ref $options{add_field} eq "ARRAY") {
            $options{add_field} = { @{$options{add_field}} };
        } elsif (ref $options{add_field} ne "HASH") {
            my @fields;
            foreach my $field (split /,/, $options{add_field}) {
                $field =~ s/^\s+//;
                $field =~ s/\s+\z//;
                push @fields, $field;
            }
            $options{add_field} = { @fields };
        }
    }

    if (defined $options{__add_field}) {
        foreach my $field (keys %{$options{__add_field}}) {
            my $ref = $options{__add_field}{$field};

            # The code generation. I'm sorry that it's a bit unreadable.
            my $func = "sub { my (\$e) = \@_; if (defined \$e->{'$ref->{field}'} && \$e->{'$ref->{field}'} =~ m!$ref->{match}!) { ";
                $func .= "\$e->{'$field'} = \"$ref->{concat}\"; }";
                if (defined $ref->{default}) {
                    $func .= " else { \$e->{'$field'} = '$ref->{default}'; } ";
                }
            $func .= "}";

            # Eval the code.
            my $code = eval $func;
            push @{$options{__add_field_func}}, $func;
            push @{$options{__add_field_code}}, $code;
        }
    }

    if (defined $options{tags} && ref $options{tags} ne "ARRAY") {
        my $tags = $options{tags};
        $options{tags} = [ ];
        foreach my $tag (split /,/, $tags) {
            $tag =~ s/^\s+//;
            $tag =~ s/\s+\z//;
            push @{$options{tags}}, $tag;
        }
    }
    
    return \%options;
}

sub validate_add_field_match {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        field => {
            type => Params::Validate::SCALAR,
            regex => qr/^\w+\z/,
        },
        match => {
            type => Params::Validate::SCALAR,
        },
        concat => {
            type => Params::Validate::SCALAR,
            regex => qr/^[^"]+\z/,
        },
        default => {
            type => Params::Validate::SCALAR,
            regex => qr/^[^']+\z/,
            optional => 1,
        },
    });

    return \%options;
}

1;
