# Awesant::Output::Lumberjack

## Description

This transport module connects to a remote socket and ships data via TLS using lumberjack protocol.
(see lumberjack protocol definition https://github.com/elasticsearch/logstash-forwarder/blob/master/PROTOCOL.md)

## Options

### host

The hostname or ip address of the logstash server.

It's possible to set a comma separated list of failover hosts.

    socket {
        host active-server, failover-server-1, failover-server-2
        port 4711
    }

Default: 127.0.0.1

### port

The port number where the lumberjack server is listening.

Default: no default

### timeout

The timeout in seconds to transport data to the remote server.

Default: 10

### connect_timeout

The timeout in seconds to connect to the remote server.

Default: 10

### persistent

Use persistent connections or not.

Default: yes

### ssl_ca_file

Lumberjack protocol is based on TLS. To verify the remote server CA public key is needed

