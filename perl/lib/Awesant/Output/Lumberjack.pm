=head1 NAME

Awesant::Output::Lumberjack - Send messages over a TLS socket using lumberjack protocol.

=head1 SYNOPSIS

    my $output = Awesant::Output::Lumberjack->new(
        host => "127.0.0.1",
        port => 4711,
        timeout => 10,
    );

    $output->push($line);

=head1 DESCRIPTION

This transport module connects to a remote socket and ships data via TLS using lumberjack protocol.
(see lumberjack protocol definition https://github.com/elasticsearch/logstash-forwarder/blob/master/PROTOCOL.md)

=head1 OPTIONS

=head2 host

The hostname or ip address of the logstash server.

It's possible to set a comma separated list of failover hosts.

    socket {
        host active-server, failover-server-1, failover-server-2
        port 4711
    }

Default: 127.0.0.1

=head2 port

The port number where the lumberjack server is listening.

Default: no default

=head2 timeout

The timeout in seconds to transport data to the remote server.

Default: 10

=head2 connect_timeout

The timeout in seconds to connect to the remote server.

Default: 10

=head2 persistent

Use persistent connections or not.

Default: yes

=head2 ssl_ca_file

Lumberjack protocol is based on TLS. To verify the remote server CA public key is needed

=head1 METHODS

=head2 new

Create a new output object.

=head2 connect

Connect to the lumberjack/logstash server.

=head2 disconnect

Disconnect from the socket.

=head2 push

Push data to the lumberjack/logstash server.

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
use IO::Socket::SSL;
use IO::Select;
use Log::Handler;
use Params::Validate qw();
use JSON;
use Errno;
use IO::Compress::Deflate qw(deflate $DeflateError) ;
use Data::Dumper;

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
    $self->{msg_sequence} = 1;
    $self->{last_ack_msg_sequence} = 0;
    $self->{max_msg_sequence} = 0xffffffff;

    # number of unsuccessful connection atemtps used to throttle connection retries
    $self->{unsuccessful_conn_count} = 0;


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
            die $! unless $sock;
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
    # At first try to connect to the server.
    # If the connect was successful, the socket
    # is stored in $self->{sock}.
    $self->connect
        or return undef;

    

    my $sock = $self->{sock};
    my $timeout = $self->{timeout};
    
    my $ack_no = -1;

    eval {
        local $SIG{ALRM} = $self->{__timeout_sub};
        local $SIG{__DIE__} = $self->{__alarm_sub};
        alarm($timeout);

        my $rest = length($data);
        my $offset = 0;

        if ($self->log->is_debug) {
            $self->log->debug("set timeout to $timeout seconds");
            $self->log->debug("send data to server $self->{host}:$self->{port}");
        }

        my $ret = $self->writeLumberjackDataFrame($data);
        if ($ret > 0 ) {
            $self->log->error("Socket closed unexpectedly");
            $self->{sock} = undef;
            return; # return from eval
        }

        if ($self->log->is_debug) {
            $self->log->debug("data written to server $self->{host}:$self->{port}, awaiting response");
        }
        
        $ack_no = $self->receiveAck();
		
        alarm(0);
    };

    # bail out, msg transmit was interrupted
    if (!defined $self->{sock}) {
      return undef;
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




      if ($ack_no == $self->{msg_sequence}) {
      		$self->{last_ack_msg_sequence} = $ack_no;
            # increment sequence
            # rollover to 0 when sequence reaches 2^32
            if ($self->{msg_sequence} >= $self->{max_msg_sequence}) {
                $self->{msg_sequence} = 1;
            } else {
                $self->{msg_sequence}++;
            };

            return 1;
        } else {
            $self->log->error("incorrect acknowledge sequence from server: $ack_no");
        }
    } 

    $self->{sock} = undef;
    return undef;
}

sub receiveAck {
        # SSL read the whole frame
        # it should be exactly 6 bytes long
        my $n = 0;
        my $gotbytes = "";

        while ($n < 6) {
          my $gotcount = 0;
          $gotcount = sysread( $sock, $gotbytes, 16384);
          $n = $n + $gotcount;
          $response .= $gotbytes;

          if (!$sock -> connected()) {
              alarm(0);
              $self->log->error("Socket closed unexpectadly");
              $self->{sock} = undef;
              return undef; # return from eval
          }

          #$self->log->debug("n = $n, gotbytes = $gotbytes, response = $response");
          
        }
        
    if (!defined $response) {
        $self->log->error("no response received from server $self->{host}:$self->{port}");
        return undef;
    }

    if (length($response) == 6) {
        my $protocol_header = substr $response, 0, 2;
        if ($protocol_header ne $self->{protocol_version} . "A"){
        	$self->log->error("incorrect response header from server: $protocol_header");
        	return undef;
        }
        $ack_no = unpack("N", substr $response, 2, 4);
        if ($self->log->is_debug) {
            $self->log->debug("got response from server $self->{host}:$self->{port}: $protocol_header - $ack_no");
        }
        return $ack_no;
    } else {
        if ($self->log->is_debug) {
            $self->log->debug("incorrect response length from server $self->{host}:$self->{port}: length($response)");
        }
        return undef;
    }
    
}

sub writeLumberjackDataFrame {
    #$data is nicely formated JSON string
    my ($self, $data) = @_;
    
    my $sock = $self->{sock};
    my $protocol_version = $self->{protocol_version};
    
    my $sequence = $self->{msg_sequence};
   	my $uncompressed_payload = '';  #init buffer


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
    
    	my $decoded = decode_json($data);
    	
    	my $file = $decoded->{'source_path'};
    	my $host = $decoded->{'source_host'};
    	my $type = $decoded->{'type'};
    	my $offset = 1000+$sequence;
    	my $line = $decoded->{'message'};

    	# header 1D
    	$uncompressed_payload = "1D";
    	# packet sequence number
    	$uncompressed_payload .= pack('N', $sequence);
    	# key-value pair count
    	$uncompressed_payload .= pack('N', 5 );
    	

    	$uncompressed_payload .= $self->writeKeyValue("file", $file);
    	$uncompressed_payload .= $self->writeKeyValue("host", $host);
    	$uncompressed_payload .= $self->writeKeyValue("type", $type);
    	# TODO: it would be nice to send line number as offset instead of artificial sequence number
		$uncompressed_payload .= $self->writeKeyValue("offset", $offset);
		# "Line" is obligatory element!!!
    	$uncompressed_payload .= $self->writeKeyValue("line", $line);

	}

    if ($protocol_version eq "2") {
		# Write JSON Data Frame:
		# version: uint8 = '2'
		# code: uint8 = 'J'
		# seq: uint32
		# payloadLen (bytes): uint32
		# payload: JSON document
		
		# "Line" is obligatory element in JSON format!!!
		
    	# header 2J
    	$uncompressed_payload = "2J";
    	# packet sequence number
    	$uncompressed_payload .= pack('N', $sequence), 4;
    	$uncompressed_payload .= pack('N', length($data)), 4;
    	$uncompressed_payload .= $data;    	
	}

    # compress payload
    ##################################################
    my $compressed_payload = '';  #init buffer
    deflate \$uncompressed_payload => \$compressed_payload;

    # Write to socket
    ##################################################
    # window header PROTOCOL_VERSION + "W"
    my $n = syswrite $sock, $protocol_version . "W", 2;
    if (!$sock -> connected()) {
		return 1;
    };

    # window size is defined as parameter
    syswrite $sock, pack('N', $self->{window_size}), 4;


    # compressed frame type header PROTOCOL_VERSION + "C"
    syswrite $sock, $protocol_version . "C", 2;
	# size of compressed payload
    syswrite $sock, pack('N', length($compressed_payload)), 4;
	# and the compressed payload
    syswrite $sock, $compressed_payload;

	# lumberjack protocol works nicely without compression
	# TODO: add config flag to enable/disable compression, set compression level
	#syswrite $sock, $uncompressed_payload, length($uncompressed_payload);
	#if ($self->log->is_debug) {
    #	$self->log->debug($uncompressed_payload);
    #	$self->log->debug(unpack( 'H*',$uncompressed_payload));
	#}

    return 0;
}

sub writeKeyValue{
    my ($self, $key, $value) = @_;   
	if (defined $value) { 
    	return pack('N', length($key)) . $key . pack('N', length($value)) . $value;
	}
	else {
    	return pack('N', length($key)) . $key . pack('N', 0);
	}
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
        window_size => {
            type => Params::Validate::SCALAR,
            default => 1,
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
        ssl_cert_file => 'SSL_cert_file',
        ssl_key_file  => 'SSL_key_file',
        ssl_version   => 'TLSv12',
        SSL_session_cache_size => 10,
    );

    while (my ($opt, $modopt) = each %sockopts) {
        if ($options{$opt}) {
            $options{sockopts}{$modopt} = $options{$opt};
        }
    }
    $options{sockopts}{SSL_verify_mode} = 0x01; # SSL_VERIFY_PEER
    $options{sockopts}{SSL_version} = 'TLSv12';
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


