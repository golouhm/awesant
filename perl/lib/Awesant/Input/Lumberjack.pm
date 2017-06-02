=head1 NAME

Awesant::Input::Lumberjack - Receive messages over a TLS socket using lumberjack protocol.

=head1 SYNOPSIS

    my $output = Awesant::Input::Lumberjack->new(
        host  => "localhost",
        port  => "4711",
        ssl_ca_file   => "/path/to/ca.crt",
        ssl_cert_file => "/path/to/ssl.crt",
        ssl_key_file  => "/path/to/ssl.key" 
    );

    # lines = max "lines" to read = max lumberjack messages to read
    # It may be less.
    $output->pull(lines => 100);

=head1 DESCRIPTION

Listen on TCP socket and receive data via TLS using lumberjack protocol.
(see lumberjack protocol definition https://github.com/elasticsearch/logstash-forwarder/blob/master/PROTOCOL.md)
Only version 1 of Lumberjack protocol is supported.

It is possible to use logstash-forwarder to send messages to Awesant Lumberjack input.

=head1 OPTIONS

=head2 host

The hostname or ip address to listen on.

Default: 127.0.0.1

=head2 port

The port number where the lumberjack server is listening.

Default: no default

=head2 ssl_ca_file

Lumberjack protocol is based on TLS. To verify the remote server CA public key is needed

=head2 ssl_cert_file

Lumberjack protocol is based on TLS. Public key of the Lumberjack server.

=head2 ssl_key_file

Lumberjack protocol is based on TLS. Private key of the Lumberjack server.


=head1 METHODS

=head2 new

Create a new input object and start listening on host:port for incoming messages.

=head2 open_socket

Helper to create the listening socket on host:port.

=head2 close_socket

Helper to close the listening socket

=head2 load_buffer

Helper to read additional data from socket if there is less then $need_length data in the buffer.
If data is not needed (eg. we are checking if new lumberjack frame has arrived) do nothing.

=head2 get_data

Helper to read $need_length data from buffered input. 
If data is not needed (eg. we are checking if new lumberjack frame has arrived) do nothing.
Behind the scenes it calls load_buffer to fetch more data from socket if needed.

return value: $need_length of data from buffer or empty string if not enough data

=head2 init_empty_buffer

Buffer is defined as:
- is_fixed_size_buf: true if data source is perl string (decompressed dataframe) or
				     false if data source is socket
- fh: handle if the data source is socket
- peerhost: who is on the other side if data source is socket
- content: buffer content
- index: current read position of buffer
- length: current buffer length 

=head2 parse

Parse input buffer passed as a parameter according to lumberjack protocol.
return value:  @messages: array of parsed messages, each message is a hash array of key-value pairs 

=head2 acknowledge

Send lumberjack acknowledge frame with current sequence.

=head2 pull

Awesant pull interface. Pulls $lines messages from this input.
return value: @messages: array of parsed messages, each message is a hash array of key-value pairs


=head2 validate

Validate the configuration that is passed to the C<new> constructor.

=head2 log

Just a accessor to the logger.

=head1 PREREQUISITES

    IO::Socket::SSL
    Log::Handler
    Params::Validate

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <mitja.golouh(at)gmail.com>.

=head1 AUTHOR

Mitja Golouh <mitja.golouh(at)gmail.com>.
Based on Socket.pm from Jonny Schulz (https://github.com/bloonix/awesant/blob/master/perl/lib/Awesant/Input/Socket.pm)
and Lumberjack protocol from Jordan Sissel (https://github.com/elasticsearch/logstash-forwarder/blob/master/PROTOCOL.md)

=head1 COPYRIGHT

Copyright (C) 2013 by Mitja Golouh. All rights reserved.

=cut

package Awesant::Input::Lumberjack;

use strict;
use warnings;
use IO::Socket::INET;
use IO::Select;
use IO::Socket::SSL qw(inet4);
use Params::Validate qw();
use Log::Handler;
use IO::Uncompress::Inflate qw(inflate $InflateError) ;
use base qw(Class::Accessor::Fast);
use Data::Dumper; # for debugging purposes
use JSON;

__PACKAGE__->mk_accessors(qw/log json socket select window_sizes sequences/);

sub new {
    my $class = shift;
    my $opts  = $class->validate(@_);
    my $self  = bless $opts, $class;

    $self->{json} = JSON->new->utf8();
    $self->{log} = Log::Handler->get_logger("awesant");
    $self->open_socket;
    $self->log->info("$class initialized");
    $self->{windows_sizes} = {};
    $self->{sequences} = {};
    $self->{curr_buffer_ref} = \(my $buffer);
	$self->{curr_buffer_index} = 0;
	$self->{curr_buffer_length} = 0;

	# when we do parsing of decompressed package we can not read any more
	# what was in compressed package has fixed size
	$self->{is_fixed_size_buf} = 0; 
	
    return $self;
}

sub open_socket {
    my $self = shift;
    my $host = $self->{host};
    my $port = $self->{port};
    my $sockopts = $self->{sockopts};
    $self->{socket} = IO::Socket::SSL->new(%$sockopts)
        or die "unable to create socket for $host:$port - $!";

    $self->{select} = IO::Select->new($self->{socket});
}


sub close_socket {
    my $self = shift;
    $self->DESTROY;
}

sub load_buffer {
    my ($self, $buffer, $need_length, $isnotrequired) = @_;
    
		# when reading from fixed buffer (string) we can not expect any more data
		if ($buffer->{"is_fixed_size_buf"}) {
			if ($isnotrequired)  { return ""; }
			else { die "Need length $need_length, got ", $buffer->{"length"} - $buffer->{"index"}; }
		}
		# when reading from socket try to get $need_length of data
		else {
			my $fh = $buffer->{"fh"};

		    if ($isnotrequired and !$fh->pending and $buffer->{"length"} != 0)  { return ""; }
		
    		my $temp_buf = "";    
    		
			while ($buffer->{"length"} - $buffer->{"index"} < $need_length) {  
		        $self->log->debug("do sysread");
		    	my $received_count = sysread( $fh, $temp_buf, 16384);
    	  		$self->log->debug("sysread received_count: $received_count");
    	  		
			 	if ( !defined($received_count)) {
        			$self->log->debug("remove closed socket of", $buffer->{"peerhost"});
     	   			$self->select->remove($fh);
        			close $fh;
        			die "remove closed socket of ", $buffer->{"peerhost"};        
	   			} elsif ( $received_count == 0 ) {
    				$self->log->debug("socket has been closed", $buffer->{"peerhost"});
        			$self->select->remove($fh);
        			close $fh;
        			die "socket has been closed ", $buffer->{"peerhost"}; 
    			}    

				$buffer->{"length"}  += $received_count;
				$buffer->{"content"} .= $temp_buf;				
    		}   			    		
		}		
}


# return value: 
#   $data: $need_length of data from buffer or empty string if not enough data
sub get_data {
    my ($self, $buffer, $need_length, $isnotrequired) = @_;
    
	my $buffer_index = $buffer->{"index"};
	my $buffer_length = $buffer->{"length"};


	# we dont have enough data in buffer, load data to buffer
	if ($buffer_length - $buffer_index < $need_length) {
		$self->load_buffer( $buffer, $need_length, $isnotrequired);
	}
	

	$buffer->{"index"}  = $buffer_index + $need_length;
	return substr $buffer->{"content"}, $buffer_index, $need_length;
}	

sub init_empty_buffer {
  my ($self, $fh) = @_;
  my %buffer;
  
  $buffer{"fh"} = $fh;
  $buffer{"content"} = "";
  $buffer{"index"} = 0;
  $buffer{"length"} = 0;
  $buffer{"is_fixed_size_buf"} = 0;
  $buffer{"peerhost"} = $fh->peerhost || "n/a";
  
  return %buffer;
}

# return value: 
#  @messages: array of parsed messages, each message is a hash array of key-value pairs 
sub parse {
    my ($self, $buffer_ref) = @_;
    
    my @messages;
    my $fh = $buffer_ref->{"fh"};
	my $buffer_index_ref = \$buffer_ref->{"index"};
	my $buffer_length_ref = \$buffer_ref->{"length"};
	my $buffer_content_ref = \$buffer_ref->{"content"};
    my $is_fixed_size_buf = $buffer_ref->{"is_fixed_size_buf"};
	my %message;
	my $key_length;
	my $key;
	my $value_length;
	my $value;			
    
    
    while (my $protocol_version = $self->get_data ($buffer_ref, 1, 1)) {
		die "unsupported protocol version $protocol_version" unless $protocol_version eq "1";
		
		my $frame_type = $self->get_data ($buffer_ref, 1);
		$self->log->debug("Frame type", $frame_type);
			
		
		# FRAME_DATA
		if ( $frame_type eq "D" ) { 
		    $self->log->debug("New FRAME_DATA");
			# extract data lead
			my $sequence = unpack("N", $self->get_data ($buffer_ref, 4));			
			my $pair_count = unpack("N", $self->get_data ($buffer_ref, 4));
			$self->log->debug("  Data_frame contains sequence: $sequence");
						

			
			# loop through pair_count key-value frames
			foreach my $i (1..$pair_count) {
				# We basically do this but to speed thing up the code get a bit complicated
				#$key_length = unpack("N", $self->get_data($buffer_ref, 4));
				#$key = $self->get_data($buffer_ref, $key_length);
				#$value_length = unpack("N", $self->get_data($buffer_ref, 4));
				#$value = $self->get_data($buffer_ref, $value_length);
				
				while ($is_fixed_size_buf == 0 && $$buffer_length_ref - $$buffer_index_ref < 4) { $self->load_buffer($buffer_ref, 4, 0, $self->{"select"}); }
				$key_length = unpack("N", substr $$buffer_content_ref, $$buffer_index_ref, 4);
				$$buffer_index_ref += 4;
				
				while ($is_fixed_size_buf == 0 && $$buffer_length_ref - $$buffer_index_ref < $key_length+4) { $self->load_buffer($buffer_ref, $key_length+4, 0, $self->{"select"}); } 
				$key = substr $$buffer_content_ref, $$buffer_index_ref, $key_length;
				$$buffer_index_ref += $key_length;

				$value_length = unpack("N", substr $$buffer_content_ref, $$buffer_index_ref, 4);
				$$buffer_index_ref += 4;				
				
				while ($is_fixed_size_buf == 0 && $$buffer_length_ref - $$buffer_index_ref < $value_length) {$self->load_buffer($buffer_ref, $value_length, 0, $self->{"select"});} 
				$value = substr $$buffer_content_ref, $$buffer_index_ref, $value_length;
				$$buffer_index_ref += $value_length;
							
				$message{"$key"} = $value;
				$self->log->debug("  Data_frame contains Key: $key, Value: $value");
			}
			
			my $last_received = $self->{sequences}{$fh};
			if ($sequence <= $last_received) {
				$self->log->warning("skipping old message with sequence $sequence");
			} 
			# if $last_received == 0 then we have a new socket 
			# if existing socket than we must follow the sequence without gaps 
			elsif ($last_received > 0 and $sequence > $last_received + 1) {
				die "we detected a gap in messages (last received=$last_received incoming=$sequence";
			}
			else {
				push (@messages, $self->json->encode(\%message)); 
				$self->{sequences}{$fh} = $sequence;
				$self->log->debug("  Push received event(s) to queue and update current sequence to $self->{sequences}{$fh}");
			} 
			
		# FRAME_WINDOW	
		} elsif ( $frame_type eq "W" ) { 
		    $self->log->debug("New FRAME_WINDOW");
			# how often must we acknowledge received data frames
			my $window_size = unpack("N", $self->get_data ($buffer_ref, 4));
			$self->{window_sizes}{$fh} = $window_size;
			$self->log->debug("  New windows size: $window_size");
		
			
		
		# FRAME_COMPRESSED	
		} elsif ( $frame_type eq "C" ) {  
		    $self->log->debug("New FRAME_COMPRESSED");

			my $compressed_payload_length = unpack("N", $self->get_data ($buffer_ref, 4));
			$self->log->debug("  Compressed payload length", $compressed_payload_length);
			
			my $compressed_payload = $self->get_data ($buffer_ref, $compressed_payload_length); 	
			my $uncompressed_payload = '';  #init buffer
			inflate \$compressed_payload => \$uncompressed_payload;
	
		    my %compressed_buffer = $self->init_empty_buffer($fh);
			$compressed_buffer{"is_fixed_size_buf"} = 1; 
			$compressed_buffer{"content"} = $uncompressed_payload;
			$compressed_buffer{"length"} = length $uncompressed_payload;
		
			push @messages, $self->parse(\%compressed_buffer);

		} else {
			# unknown frame type
			my $peerhost = $fh->peerhost | "n/a";
			$self->log->debug("Unknown frame type", $peerhost);
			$self->select->remove($fh);
			close $fh;
			die "Unknown frame type", $peerhost;       	
		}
    } 
    
    return (@messages);

    
}

sub acknowledge {
	my ($self, $fh) = @_;
	$self->log->debug("  Send ACK with sequence $self->{sequences}{$fh}");
	my $n = syswrite $fh, "1A".pack('N', $self->{sequences}{$fh}), 6;
	$self->{last_ack}{$fh} = $self->{sequences}{$fh};
}

sub pull {
    my ($self, %opts) = @_;
    my $response = $self->{response};
    my $count = $opts{lines} || 10;
    my @lines = ();

    $self->log->debug("Waiting for incoming socket");
    my @ready = $self->select->can_read;

    foreach my $fh (@ready) {
        $self->log->debug("Socket available for connect or read");
        if ($fh == $self->socket) {
            $self->socket->timeout(10);
            my $client = $self->socket->accept or 
            	$self->log->warning("failed to accept or ssl handshake: $!, $SSL_ERROR");

            if ($! == &Errno::ETIMEDOUT) {
                $self->log->warning("accept runs on a timeout");
            }

            $self->socket->timeout(0);
            next unless $client;
            
            
            my $addr = $client->peerhost || "n/a";
            $self->select->add($client);
            $self->{sequences}{$client} = 0; #reset sequence on every client (re)connect
            $self->{last_ack}{$client} = 0;
            $self->log->debug("new client connection accepted from ", $addr );
            next;
        }

    		my $last_ack = $self->{last_ack}{$fh};

			eval {
				local $SIG{__DIE__} = sub { alarm(0) };
                local $SIG{ALRM} = sub { die "timeout" };
                alarm(30);
                my %normal_buffer = $self->init_empty_buffer($fh);
        		my (@messages) = $self->parse(\%normal_buffer);
        		alarm(0);
        		push @lines, @messages;
        		$self->log->debug("Incoming data parsed. Check if we need to acknowledge");
        		$self->log->debug("  Current sequence $self->{sequences}{$fh}, last acknowledged $last_ack, window size $self->{window_sizes}{$fh}");
				if ($self->{sequences}{$fh} - $last_ack >= $self->{window_sizes}{$fh}) { 
					$self->acknowledge($fh)
				};
        	};
        	if ($@) {
            	my $err = $@;
            	$self->log->debug($err);
            }

        $count--;
        last unless $count;
    }

    return \@lines;
}

sub validate {
    my $class = shift;

    my %options = Params::Validate::validate(@_, {
        host => {
            type => Params::Validate::SCALAR,
        },
        port => {
            type => Params::Validate::SCALAR,
            regex => qr/^\d+\z/,
        },
        ssl_ca_file => {
            type => Params::Validate::SCALAR,
        },
        ssl_cert_file => {
            type => Params::Validate::SCALAR,
        },
        ssl_key_file => {
            type => Params::Validate::SCALAR,
        },
    });

    my %sockopts = (
        host  => "LocalAddr",
        port  => "LocalPort",
        ssl_ca_file   => "SSL_ca_file",
        ssl_cert_file => "SSL_cert_file",
        ssl_key_file  => "SSL_key_file",       
    );

    while (my ($opt, $modopt) = each %sockopts) {
        if ($options{$opt}) {
            $options{sockopts}{$modopt} = $options{$opt};
        }
    }

    $options{sockopts}{SSL_verify_mode} = 0x01; # SSL_VERIFY_PEER


    $options{sockopts}{Listen} = SOMAXCONN;
    $options{sockopts}{Reuse}  = 1;

    return \%options;
}

sub DESTROY {
    my $self = shift;
    my $socket = $self->{socket};

    if ($socket) {
        close $socket;
    }
}

1;
