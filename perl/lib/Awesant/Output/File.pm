=head1 NAME

Awesant::Output::File - Send events to file.

=head1 SYNOPSIS

    my $log = Awesant::Output::File->new(
        filename => "/tmp/mylog.txt",
        openmode => "append"
    );

=head1 DESCRIPTION

=head1 OPTIONS

=head2 filename

Filename in which to write the output.

=head2 openmode

Open filename in append mode or new.

=head1 METHODS

=head2 new

Create a new input object.

=head2 push

Push data to file.

=head2 validate

Validate the configuration that is passed to the C<new> constructor.

=head2 log

Just an accessor to the logger.

=head1 PREREQUISITES

    Log::Handler
    Params::Validate

=head1 EXPORTS

No exports.

=head1 REPORT BUGS

Please report all bugs to <mitja.golouh(at)gmail.com>.

=head1 AUTHOR

Mitja Golouh <mitja.golouh(at)gmail.com.

=head1 COPYRIGHT

Copyright (C) 2017 by Mitja Golouh. All rights reserved.
Based on File.pm by Jonny Schulz <support(at)bloonix.de>.

=cut

package Awesant::Output::File;

use strict;
use warnings;
use Log::Handler;
use Params::Validate qw();
use IO::Handle;

sub new {
    my $class = shift;
    my $opts = $class->validate(@_);
    my $self = bless $opts, $class;

    my $fh = undef;
    
    $self->{log} = Log::Handler->get_logger("awesant");

    if ($self->{openmode} eq "append") {
        open $fh, ">>", $self->{filename};
    } elsif ($self->{openmode} eq "new") {
        open $fh, ">", $self->{filename};
    } else {
        $self->log->error("Unknown openmode $self->{openmode} for $self->{filename}");
        die;
    }
    
    $self->{fh} = $fh;
    $self->log->notice("$class initialized");

    return $self;
}

sub push {
    my ($self, $line) = @_;
    my $fh = $self->{fh};

    if ($self->log->is_debug) {
        $self->log->debug("File output: $line");
    }

    print $fh "$line\n";
    $fh->flush;
}

sub validate {
    my $self = shift;

    my %options = Params::Validate::validate(@_, {
        filename => {
            type => Params::Validate::SCALAR,
        },
        openmode => {
            type => Params::Validate::SCALAR,
            default => "append",
            regex => qr/^(append|new)\z/
        },
    });

    return \%options;
}

sub log {
    my $self = shift;

    return $self->{log};
}

1;
