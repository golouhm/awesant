# Awesant::Input::Lumberjack

## Description

Listen on TCP socket and receive data via TLS using lumberjack protocol.
(see lumberjack protocol definition https://github.com/elasticsearch/logstash-forwarder/blob/master/PROTOCOL.md)
Only version 1 of Lumberjack protocol is supported.

It is possible to use logstash-forwarder to send messages to Awesant Lumberjack input.

## Options

### host

The hostname or ip address to listen on.

Default: 127.0.0.1

### port

The port number where the lumberjack server is listening.

Default: no default

### ssl_ca_file

Lumberjack protocol is based on TLS. To verify the remote server CA public key is needed

### ssl_cert_file

Lumberjack protocol is based on TLS. Public key of the Lumberjack server.

### ssl_key_file

Lumberjack protocol is based on TLS. Private key of the Lumberjack server.


