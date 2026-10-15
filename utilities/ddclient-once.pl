#!/usr/bin/env perl
use strict;
use warnings;

# Use ddclient's own parser so provider credentials, quoting, continuations, and
# multiple host definitions remain supported. Never evaluate the config as shell.
require '/usr/bin/ddclient';
my $ip = shift @ARGV // die "Missing external IPv4\n";
my @expected_hosts;
# Apply policy after EVERY config read: ddclient reloads the file inside main.
# ddclient 4.0.0 clamps daemon=0 to its 60-second minimum, so remove the setting
# instead. Ordinary CLI IP flags also do not override per-host config values.
my $read_config = \&ddclient::read_config;
{
    no warnings 'redefine';
    *ddclient::read_config = sub {
        my ($file, $hosts, $globals) = @_;
        $read_config->(@_);
        die "No DDNS hosts configured\n" unless keys %$hosts;
        @expected_hosts = keys %$hosts;
        delete $globals->{daemon};
        for my $host (values %$hosts) {
            delete $host->{daemon};
            @{$host}{qw(use usev4 ipv4 usev6)} = ('disabled', 'ipv4', $ip, 'disabled');
        }
    };
}

# Some ddclient releases log provider failure but still exit zero. Validate every
# host's in-memory result at exit, rather than relying on exit status or log text.
END {
    if ($? == 0) {
        no warnings 'once';
        for my $host (@expected_hosts) {
            my $result = $ddclient::recap{$host} // {};
            if (($result->{'status-ipv4'} // '') ne 'good' || ($result->{ipv4} // '') ne $ip) {
                $? = 1;
                last;
            }
        }
    }
}

# Use ddclient's normal update, provider handling, and cache.
# The wrapper's filename does not end in 'd', so its daemon default is disabled.
@ARGV = (
    '--file=/config/ddclient.conf', '--cache=/tmp/ddclient.cache',
    '--foreground', '--force', '--timeout=120',
    '--no-debug', '--no-verbose', '--no-syslog', '--exec',
);
ddclient::main();
