#!/usr/bin/perl

# Default Stream lookup follows realip; an explicit source remains independent.

use warnings;
use strict;
use Test::More;
BEGIN { use FindBin; chdir($FindBin::Bin); }
use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;
use GeoIP2;

my $t = Test::Nginx->new()->has(qw/stream stream_return stream_realip stream_map/)
    ->plan(6);
my $d = $t->testdir();
my @entries = map { [$_->[0], mmdb_map(code => mmdb_value(2, $_->[1]))] }
    (['127.0.0.1', 'LOCAL'], ['192.0.2.1', 'CLIENT'], ['2001:db8::1', 'V6']);
$t->write_file('test.mmdb', mmdb(6, \@entries));
$t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
master_process off;
events {}
stream {
    %%TEST_GLOBALS_STREAM%%
    map \$remote_addr \$fixed { default 127.0.0.1; }
    geoip2 $d/test.mmdb {
        \$code default=missing code;
        \$explicit source=\$fixed code;
    }
    server {
        listen 127.0.0.1:8080 proxy_protocol;
        set_real_ip_from 127.0.0.1;
        return "code=\$code
explicit=\$explicit
";
    }
}
EOF
$t->run();
for my $case (['TCP4', '192.0.2.1', 'CLIENT'], ['TCP6', '2001:db8::1', 'V6'],
    ['TCP6', '::ffff:192.0.2.1', 'CLIENT'])
{
    my ($type, $ip, $expected) = @$case;
    my $dst = $type eq 'TCP6' ? '::1' : '127.0.0.1';
    my $r = response_fields(stream('127.0.0.1:' . port(8080))
        ->io("PROXY $type $ip $dst 12345 80\r\n"));
    is($r->{code}, $expected, "realip default source: $ip");
    is($r->{explicit}, 'LOCAL', "explicit source unaffected: $ip");
}
