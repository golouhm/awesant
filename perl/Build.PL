use strict;
use warnings;
use Module::Build;

my $build = Module::Build->new(
    create_makefile_pl => "traditional",
    license            => "perl",
    module_name        => "Awesant::Agent",
    dist_author        => "Jonny Schulz",
    sign               => 0,
    #recommends => {
    #    "Net::RabbitMQ" => 0,
    #},
    requires => {
        perl => "5.006_001",
        "Class::Accessor"  => 0,
        "Fcntl"            => 0,
        "IO::Select"       => 0,
        "IO::Socket"       => 0,
        "Log::Handler"     => "0.75",
        "Params::Validate" => 0,
        "POSIX"            => 0,
        "Sys::Hostname"    => 0,
        "JSON"             => 0,
        "JSON::XS"         => 0
    },
);

$build->create_build_script;
