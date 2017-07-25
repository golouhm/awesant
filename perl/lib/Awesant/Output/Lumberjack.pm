=head1 NAME

Awesant::Output::Lumberjack - Send messages over a TLS socket using lumberjack protocol.

=head1 SYNOPSIS

    my $output = Awesant::Output::Lumberjack->new(
        host => "127.0.0.1",
        port => 4711,
        ssl_ca_file => "/path/to/ca.crt",
        connect_timeout => 10,
        timeout => 10,
        protocol_version => 1,
        persistent => "yes"
    );

    $output->push($line);

=head1 DESCRIPTION

This transport module connects to a remote socket and ships data via TLS using lumberjack protocol.
(see lumberjack protocol definition https://github.com/elasticsearch/logstash-forwarder/blob/master/PROTOCOL.md)

=head1 OPTIONS

=head2 host

The hostname or ip address of the logstash server.

It's possible to set a comma separated list of failover hosts.

    lumberjack {
        host active-server, failover-server-1, failover-server-2
        port 4711
    }

Default: 127.0.0.1

=head2 port

The port number where the lumberjack server is listening.

Default: no default

=head2 ssl_ca_file

Lumberjack protocol is based on TLS. To verify the remote server CA public key is needed

=head2 connect_timeout

The timeout in seconds to connect to the remote server.

Default: 10

=head2 timeout

The timeout in seconds to transport data to the remote server.

Default: 10

=head2 protocol_version

Currently only Lumberjack version 1 is supported which is documented on https://github.com/elasticsearch/logstash-forwarder/blob/master/PROTOCOL.md.
Version 2 of the protocol is not officially documented.

Default: yes

=head2 persistent

Use persistent connections or not.

Default: yes

=head1 METHODS

=head2 new

Create a new output object.

=head2 connect

Connect to the lumberjack/logstash server.

=head2 disconnect

Disconnect from the lumberjack/logstash server.

=head2 push

Push data to the lumberjack/logstash server.

=head2 readAck

Read Acknowledge frame.

=head2 writeLumberjackFrame

Write input data to the socket connected to lumberjack/logstash server using lumberjack protocol.

=head2 convertArrayToLumberjackDataFrames

Converts data in perl array of hashes to lumberjack data frames.

=head2 convertHashToLumberjackDataFrame

Converts data in perl hash to single lumberjack data frame.

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
Based on Socket.pm from Jonny Schulz (https://github.com/bloonix/awesant/blob/master/perl/lib/Awesant/Output/Socket.pm)
and Lumberjack protocol from Jordan Sissel (https://github.com/elasticsearch/logstash-forwarder/blob/master/PROTOCOL.md)

=head1 COPYRIGHT

Copyright (C) 2013 by Mitja Golouh. All rights reserved.

=cut

package Awesant::Output::Lumberjack;

use strict;
use warnings;
use IO::Socket::SSL qw(inet4);
use IO::Select;
use Log::Handler;
use Params::Validate qw();
use JSON;
use Errno;
use IO::Compress::Deflate qw(deflate $DeflateError) ;
use Data::Dumper;
use POSIX qw(:errno_h);
use Time::HiRes qw();


sub new {
    my $class = shift;
    my $opts = $class->validate(@_);
    my $self = bless $opts, $class;

    $self->{log} = Log::Handler->get_logger("awesant");
    
    $self->{__alarm_sub} = sub {
        alarm(0);
    };

    $self->{__timeout_sub} = sub {
        die "connection timed out";
    };

    # lumberjack protocol implements ordered delivery using sequence number
    # when max sequence is reached it starts again from 1
    $self->{msg_sequence} = 0;
    $self->{max_msg_sequence} = 0xffffffff;
    $self->{last_ack} = 0;
    $self->{window_size} = undef;

    # number of unsuccessful connection atemtps used to throttle connection retries
    $self->{unsuccessful_conn_count} = 0;
    
    $self->{max_window_size} = 10000;
    $self->{compression} = "true";


    $self->log->notice("$class initialized");


    return $self;
}

sub connect {
    my $self = shift;

    # If the socket is still active, then just return true.
    # This works only if the sock is set to undef on errors.
    if ($self->{sock} && $self->{persistent}) {
          return 1;
    }

        # Some additional logic to delay retries when log server is unreachable
    if ($self->{unsuccessful_conn_count} > 50) {
        $self->log->notice("Sleeping 10min due to way too many unseccessful connections to log server");
        sleep 600;
    }  elsif ($self->{unsuccessful_conn_count} > 10) {
        $self->log->notice("Sleeping 60s due to too many unseccessful connections to log server");
        sleep 60;
    }

    my $module = $self->{sockmod};
    my $port   = $self->{port};
    my $hosts  = $self->{hosts};
    my @order  = @$hosts;
    my $sock;

    # Try to connect to the hosts in the configured order.
    while (my $host = shift @order) {
        # Although the connection was successful, the host is pushed
        # at the end of the array. If the connection lost later, then
        # the next host will be connected.
        push @$hosts, shift @$hosts;

        # Set the currently used host to the object.
        $self->{host} = $host;

        # Set the PeerAddr to the host that we a try to connect.
        $self->{sockopts}->{PeerAddr} = $host;

        # We don't want that the daemon dies if the connection
        # was not successful. The eval block is also great to
        # break out on errors.
        $self->log->notice("connect to server $host:$port");
        eval {
            local $SIG{ALRM} = $self->{__timeout_sub};
            local $SIG{__DIE__} = $self->{__alarm_sub};
            alarm($self->{connect_timeout});
            $sock = IO::Socket::SSL->new(%{$self->{sockopts}});
            die "error=$!, ssl_error=$SSL_ERROR" unless $sock;
            alarm(0);
        };

        # If no error message exists and the socket is created,
        # then the connection was successful. In this case we
        # just jump out of the loop.
        if (!$@ && $sock) {
            $self->{unsuccessful_conn_count} = 0;
            last;
        }

        # At this point the connection was not successful.
        if ($@) {
            $self->log->error($@);
        }

        $self->log->error("unable to connect to server $host:$port");
    }

    # It's possible that no connection could be established to any host.
    # If a connection could be established, then the socket will be
    # stored to $self->{sock} and autoflush flag is set to the socket.
    if ($sock) {
        $sock->autoflush(1);
        $sock->blocking(1);
        $self->log->notice("connected to server $self->{host}:$self->{port}");
        $self->{sock} = $sock;
        return 1;
    }
    $self->{unsuccessful_conn_count}++;
    return undef;
}

sub disconnect {
    my $self = shift;
    my $socket = $self->{sock};

    if ($socket) {
        close $socket;
    }
}

sub push {
    my ($self, $data) = @_;
    
    #$data is perl hash variable
    
    # At first try to connect to the server.
    # If the connect was successful, the socket
    # is stored in $self->{sock}.
    $self->connect
        or return undef;  

    my $sock = $self->{sock};
    my $timeout = $self->{timeout};
    my $protocol_version = $self->{protocol_version};
    
    my $response = "";
    my $ack_no = -1;
    my $protocol_header = "";

    eval {
        local $SIG{ALRM} = $self->{__timeout_sub};
        local $SIG{__DIE__} = $self->{__alarm_sub};
        alarm($timeout);

        if ($self->log->is_debug) {
            $self->log->debug("set timeout to $timeout seconds");
            $self->log->debug("send data to server $self->{host}:$self->{port}");
        }

        my $ret = $self->writeLumberjackFrame($data);
        if ($ret > 0 ) {
            $self->log->error("Socket closed unexpectedly");
            $self->{sock} = undef;
            return; # return from eval
        }

        if ($self->log->is_debug) {
            $self->log->debug("data written to server $self->{host}:$self->{port}");
        }          
		
        alarm(0);
    };

    # bail out, msg transmit was interrupted
    if (!defined $self->{sock}) {
	  $self->log->error("Transmit was interrupted");
      return undef;
    }
    
    if ($protocol_version eq "1") {
      	if ($self->{msg_sequence} > $self->{last_ack} + $self->{window_size} - 1) {
      		$response = undef;
      		while (!defined $response ) {
      			$response = $self->readACK();
      		}
      
    		if (length($response) == 6) {
        		$protocol_header = substr $response, 0, 2;
    	    	$ack_no = unpack("N", substr $response, 2, 4);
	        	if ($self->log->is_debug) {
            		$self->log->debug("got response from server $self->{host}:$self->{port}: $protocol_header - $ack_no");
        		}
    		} else {
            	$self->log->error("Incorrect response length from server $self->{host}:$self->{port}: " . length($response) . ". Expecting length 6 bytes.");
        		return undef;
    		}

    		if ($protocol_header eq $protocol_version . "A") {
      			if ($ack_no == $self->{msg_sequence} ) {
      			    $self->{last_ack} = $self->{msg_sequence};
    	        	return 1;
	        	} else {
            		$self->log->error("Incorrect acknowledge sequence from server: $ack_no. Expecting sequence " . $self->{msg_sequence});
        		}
    		} else {
        		$self->log->error("incorrect response header from server: $protocol_header");
    		}

    		$self->{sock} = undef;
    		return undef;     
    	}      
    }


    if (!$self->{persistent}) {
        $self->log->debug("Closing socket");
        $self->close_socket;
    }

    if ($@) {
        $self->log->error($@);
        $self->{sock} = undef;
        return undef;
    }

    return 1;
}

sub readACK {
    my ($self) = @_;
    
    my $sock = $self->{sock};
    my $timeout = $self->{timeout}; 
    my $response = "";   


    eval {
        local $SIG{ALRM} = $self->{__timeout_sub};
        local $SIG{__DIE__} = $self->{__alarm_sub};
        alarm($timeout);
        
        if ($self->log->is_debug) {
            $self->log->debug("set timeout to $timeout seconds");
            $self->log->debug("waiting for ACK");
        }        
        
        # SSL read the whole frame
        # it should be exactly 6 bytes long
        my $n = sysread( $sock, $response, 16384);

        if ( !defined($n) ) {
            # Resource temporarily unavailable; the call might work if you try again later. 
            # The macro EWOULDBLOCK is another name for EAGAIN
        	if ($! != EWOULDBLOCK && $! != EAGAIN) {
        		$self->log->error($SSL_ERROR);
        		return undef;
        	};
        	
        	# If you get SSL_ERROR_WANT_READ on an ssl_write() operation, you need to read inbound data.
        	# SSL_WANT_READ means "wait for the socket to be readable, then call this function again."
        	
        	# If you get SSL_ERROR_WANT_WRITE on an ssl_read() operation, you need to send outbound data, 
        	# or at least wait for the socket to become writable.
        	# SSL_WANT_WRITE means "wait for the socket to be writeable, then call this function again."
        	if ( $SSL_ERROR == SSL_WANT_WRITE ) {
        		# retry read once I can write
        		return undef;
        	} else {
        		# retry
        		return undef;
        	}
        } elsif ( !$n  ) {
			$self->log->debug( "EOF" );
			return undef;
		} 
        
        alarm(0);
    }; 
    
    return $response;  
}

sub writeLumberjackFrame {
    #$data is perl array of hashes
    my ($self, $data) = @_;
    
    $self->log->debug("writeLumberjackFrame");
    
    my $sock = $self->{sock};
    my $protocol_version = $self->{protocol_version};
    my $compression = $self->{compression};

    my $payload = $self->convertArrayToLumberjackDataFrames($data,$compression);
    
    
    # Write to socket
    ##################################################
    # window header PROTOCOL_VERSION + "W"
    my $n = syswrite $sock, $protocol_version . "W", 2;
    if (!$sock -> connected()) {
		return 1;
    };

    # window size is $self->{window_size} 
    syswrite $sock, pack('N', $self->{window_size}), 4;

    if (defined $compression) {
    	# compressed frame type header PROTOCOL_VERSION + "C"
    	syswrite $sock, $protocol_version . "C", 2;
		# size of compressed payload
    	syswrite $sock, pack('N', length($payload)), 4;
    }
	
	# and write the (un)compressed payload
	my $payload_length = length($payload);
	my $payload_offset = 0;
	while ($payload_offset < $payload_length) {
		# max ssl frame is 16384 so we have to break apart large writes
		syswrite $sock, $payload, 16384, $payload_offset;
		$payload_offset = $payload_offset + 16384;
	}


	# lumberjack protocol works nicely without compression
	# TODO: add config flag to enable/disable compression, set compression level
	#syswrite $sock, $uncompressed_payload, length($uncompressed_payload);
	#if ($self->log->is_debug) {
    #	$self->log->debug($uncompressed_payload);
    #	$self->log->debug(unpack( 'H*',$uncompressed_payload));
	#}
    
    return 0;
}

sub convertArrayToLumberjackDataFrames {
    #$data is perl hash variable
    my ($self, $data, $compression) = @_;
        	#$self->log->info("*****************************************************************************");
        	#$self->log->info(Dumper( $data));
        	#$self->log->info("*****************************************************************************");

    $self->log->debug("  convertArrayToLumberjackDataFrames");

   	my $uncompressed_payload = '';  #init buffer

    if (ref($data) eq 'ARRAY'){
    	$self->{window_size} = scalar @$data;
        $self->log->debug("    set window_size = $self->{window_size}");
    	for my $rowIndex (0 .. $#{$data})
		{
      		$uncompressed_payload .= $self->convertHashToLumberjackDataFrame($data->[$rowIndex]);
		}
    
    } else {
        $self->{window_size} = 1;
    	$uncompressed_payload = $self->convertHashToLumberjackDataFrame($data);
    } 

    if (defined $compression){
    	# compress payload
    	##################################################
    	my $compressed_payload = '';  #init buffer
    	deflate \$uncompressed_payload => \$compressed_payload;


    	return $compressed_payload;
    	
    } else {
    	return $uncompressed_payload;
    }
}

sub convertHashToLumberjackDataFrame {
    #$data is perl hash variable
    my ($self, $data) = @_;
    
    $self->log->debug("    convertHashToLumberjackDataFrame");

    my $protocol_version = $self->{protocol_version};
    # increment sequence
    # rollover to 0 when sequence reaches 2^32
    if ($self->{msg_sequence} >= $self->{max_msg_sequence}) {
        $self->{msg_sequence} = 1;
    } else {
        $self->{msg_sequence}++;
    };        
    my $sequence = $self->{msg_sequence};
    my $uncompressed_payload = ''; # init
    
    # prepare message payload
    ##################################################
    if ($protocol_version eq "1") {
		# Write Key-Value Data Frame:
		# version: uint8 = '1'
		# code: uint8 = 'D'
		# seq: uint32
		# number of key-value pairs: uint32
		# repeat #number of key-value pairs
		#   key length (bytes): uint32
		#   key text
		#   value length (bytes): uint32
		#   value text   
    
		my $decoded = $data;
    	
    	# header 1D
    	$uncompressed_payload = "1D";
    	# packet sequence number
    	$uncompressed_payload .= pack('N', $sequence);
    	# key-value pair count (number of keys in hash - 1 for @timestamp - 1 for @version)
    	$uncompressed_payload .= pack('N', (scalar keys %{$decoded}) - 2 );
    	
    	# "Line" is obligatory element!!!   
    	# Logstash Lumberjack input returns error if we send @timestamp 	
		my $value;
		foreach my $item( keys %{$decoded} ) { 
		  	next if ($item eq 'tags' || $item eq '@version' || $item eq '@timestamp');
		  	$value = $decoded->{$item};
				$self->log->debug("      $item $decoded->{$item}");
   				$uncompressed_payload .= pack('NA*NA*', length($item), $item , length($value) , $value ); 
		}
		# tags is an ARRAY
    	$uncompressed_payload .= pack('NA*NA*', 4, "tags", length(join(",",@{$decoded->{'tags'}})), join(",",@{$decoded->{'tags'}}) );
		
	}

    if ($protocol_version eq "2") {
		# Write JSON Data Frame:
		# version: uint8 = '2'
		# code: uint8 = 'J'
		# seq: uint32
		# payloadLen (bytes): uint32
		# payload: JSON document
		
		# "Line" is obligatory element !!!
		
    	# header 2J
    	$uncompressed_payload = "2J";
    	# packet sequence number
    	$uncompressed_payload .= pack('N', $sequence);
    	$uncompressed_payload .= pack('N', length($data));
    	$uncompressed_payload .= $data;    	
	}

  return $uncompressed_payload;
}



sub validate {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        host => {
            type => Params::Validate::SCALAR | Params::Validate::ARRAYREF,
            default => "127.0.0.1",
        },
        port => {
            type => Params::Validate::SCALAR,
            default => 6379,
        },
        protocol_version => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:1|2)\z/,
            default => "1",
        },        
        connect_timeout => {
            type => Params::Validate::SCALAR,
            default => 10,
        },
        timeout => {
            type => Params::Validate::SCALAR,
            default => 10,
        },
        persistent => {
            type => Params::Validate::SCALAR,
            regex => qr/^(?:yes|no|0|1)\z/,
            default => "yes",
        },
        ssl_ca_file => {
            type => Params::Validate::SCALAR,
        },
    });

    if ($options{persistent} eq "no") {
        $options{persistent} = 0;
    }

    my %sockopts = (
        port => 'PeerPort',
        ssl_ca_file   => 'SSL_ca_file',
        SSL_session_cache_size => 10,
    );

    while (my ($opt, $modopt) = each %sockopts) {
        if ($options{$opt}) {
            $options{sockopts}{$modopt} = $options{$opt};
        }
    }
    $options{sockopts}{SSL_verify_mode} = 0x01; # SSL_VERIFY_PEER
    $options{sockopts}{SSL_session_cache_size} = 10;

    $options{host} =~ s/\s//g;
    $options{hosts} = [ split /,/, $options{host} ];


    return \%options;
}

sub log {
    my $self = shift;

    return $self->{log};
}

1;


