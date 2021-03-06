# Awesant::Input::Socket

## Description

Listen on a TCP or UDP socket and ship events.

## Options

### host

The ip address to listen on.

Default: 127.0.0.1

### port

The port number to listen on.

Default: no default

### auth

With this option it's possible to set a username and password if you want
that each client have to authorize.

    user:password

See also the documentation of Awesant::Output::Socket.

### proto

The protocol to use. At the moment only tcp is allowed.

Default: tcp

### ssl_ca_file, ssl_cert_file, ssl_key_file, ssl_verify_mode

If you want to use ssl connections then you can set the path to your ca, certificate and key file.

The option ssl_verify_mode can be set to SSL_VERIFY_PEER, SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
SSL_VERIFY_CLIENT_ONCE or SSL_VERIFY_NONE. Lowercase is allowed.

This options are equivalent to the options of IO::Socket::SSL.

See cpan http://search.cpan.org/~sullr/IO-Socket-SSL/.

Default: there are no defaults set, so you have to check the defaults of IO::Socket::SSL.
Please check the right version of IO::Socket::SSL.

    perl -MIO::Socket::SSL -e 'print $IO::Socket::SSL::VERSION'

### response

Send a response for each received event.

    response => "ok"

Then the string "ok" is send back to the sender.

See also the documentation of Awesant::Output::Socket.

