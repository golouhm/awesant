#!/usr/bin/perl
use strict;
use warnings;
use Getopt::Long qw(:config no_ignore_case);
use lib "perl/lib";
use Awesant::Agent;

if (!-e "Makefile") {
    print "Execute me from the source directory!\n";
    exit 1;
}

my $o_prefix           = "/usr/local";
my $o_confdir          = "/etc";
my $o_initdir          = "/etc/init.d";
my $o_logdir           = "/var/log";
my $o_rundir           = "/var/run";
my $o_perl             = "/usr/bin/perl";
my $o_perl_prefix      = "/usr/local";
my $o_perl_destdir     = "";
my $o_perl_installdirs = "site";
my $o_without_perl     = 0;
my $o_build_package    = 0;
my $o_help             = 0;

GetOptions(
    "prefix=s"           => \$o_prefix,
    "confdir=s"          => \$o_confdir,
    "initdir=s"          => \$o_initdir,
    "logdir=s"           => \$o_logdir,
    "rundir=s"           => \$o_rundir,
    "perl=s"             => \$o_perl,
    "perl-destdir=s"     => \$o_perl_destdir,
    "perl-installdirs=s" => \$o_perl_installdirs,
    "without-perl"       => \$o_without_perl,
    "build-package"      => \$o_build_package,
    "h|help"             => \$o_help
);

if ($o_help) {
    print "Usage: perl Configure.PL [ OPTIONS ]\n\n";
    print "Configure options:\n\n";
    print "  --prefix DIR\n";
    print "  --confdir DIR\n";
    print "  --initdir DIR\n";
    print "  --logdir DIR\n";
    print "  --rundir DIR\n";
    print "  --perl PERL EXECUTABLE\n";
    print "  --perl-destdir DESTDIR\n";
    print "  --perl-installdirs INSTALLDIRS\n";
    print "\n";
    exit 0;
}

my ($mversion, $cversion);

$mversion = $Awesant::Agent::VERSION;

open my $ch, "<", "ChangeLog" or die "Unable to open ChangeLog for reading - $!";
$cversion = <$ch>;
$cversion =~ s/^awesant\s\((\d+\.\d+)\).*/$1/;
close $ch;

open my $fh, ">", "Makefile.config" or die "Unable to overwrite Makefile - $!";

print "Writing Makefile.config ...\n";

print $fh <<EOF;
# Base paths
PREFIX=\$(DESTDIR)$o_prefix
CONFDIR=\$(DESTDIR)$o_confdir
INITDIR=\$(DESTDIR)$o_initdir
LOGDIR=\$(DESTDIR)$o_logdir
RUNDIR=\$(DESTDIR)$o_rundir
PERL=$o_perl
PERL_INSTALLDIRS=$o_perl_installdirs
PERL_DESTDIR=\$(DESTDIR)
WITHOUT_PERL=$o_without_perl
BUILDPKG=$o_build_package
EOF

close $fh;

print "Done.\n";
