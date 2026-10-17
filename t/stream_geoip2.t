#!/usr/bin/perl

# Stream equivalents of HTTP lookup and conversion tests, using PROXY protocol.

use warnings;
use strict;
use Test::More;
BEGIN { use FindBin; chdir($FindBin::Bin); }
use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;
use GeoIP2;

my %values = sample_values();
my $t = Test::Nginx->new()->has(qw/stream stream_return stream_map/)
    ->plan(scalar(keys %values) + 24);
my $d = $t->testdir();
my @entries = map { [$_->[0], sample_record($_->[1])] }
    (['0.0.0.0', 'ZERO'], ['1.2.3.4', 'V4'], ['127.0.0.1', 'LOCAL'],
     ['2001:db8::1', 'V6']);
$t->write_file('dual.mmdb', mmdb(6, \@entries));
$t->write_file('zero.mmdb', mmdb(6, \@entries));
$t->write_file('ipv4.mmdb', mmdb(4, [@entries[0 .. 2]]));
$t->write_file('other.mmdb', mmdb(4, [['1.2.3.4', sample_record('OTHER')]]));
my $variables = join '', map { "\$v_$_ default=missing source=\$proxy_protocol_addr $_;\n" }
    sort keys %values;
my $output = join '', map { "$_=\$v_$_\n" } sort keys %values;
$t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
master_process off;
events {}
stream {
    %%TEST_GLOBALS_STREAM%%
    map \$remote_addr \$zero { default ::; }
    geoip2 $d/dual.mmdb {
        $variables
        \$code default=missing source=\$proxy_protocol_addr code;
        \$name source=\$proxy_protocol_addr country names en;
        \$sub source=\$proxy_protocol_addr subdivisions 0 code;
        \$absent source=\$proxy_protocol_addr nonexistent;
        \$map default=missing source=\$proxy_protocol_addr country;
        \$array default=missing source=\$proxy_protocol_addr subdivisions;
        \$local code;
        \$epoch metadata build_epoch;
        \$checked metadata last_check;
        \$changed metadata last_change;
    }
    geoip2 $d/zero.mmdb { \$zero_code source=\$zero code; }
    geoip2 $d/ipv4.mmdb { \$ipv4 default=missing source=\$proxy_protocol_addr code; }
    geoip2 $d/other.mmdb { \$other default=missing source=\$proxy_protocol_addr code; }
    server {
        listen 127.0.0.1:8080 proxy_protocol;
        return "$output
code=\$code
name=\$name
sub=\$sub
absent=\$absent
map=\$map
array=\$array
local=\$local
epoch=\$epoch
checked=\$checked
changed=\$changed
zero=\$zero_code
ipv4=\$ipv4
other=\$other
";
    }
}
EOF
$t->run();

my $r = lookup('0.0.0.0');
is($r->{code}, 'ZERO', 'first lookup at zero address');
is($r->{zero}, 'ZERO', 'first lookup at IPv6 zero address');
is($r->{ipv4}, 'ZERO', 'first zero lookup in IPv4-only database');
for my $field (sort keys %values) {
    is($r->{$field}, $values{$field}, "format $field");
}
is($r->{name}, 'Test land', 'nested string path');
is($r->{sub}, 'A1', 'array index path');
is($r->{absent}, '', 'missing path without default');
is($r->{map}, 'missing', 'map value uses default');
is($r->{array}, 'missing', 'array value uses default');
is($r->{local}, 'LOCAL', 'PROXY source does not change default connection source');
is($r->{epoch}, '1234567890', 'build timestamp');
cmp_ok($r->{checked}, '>', 0, 'initial check timestamp');
is($r->{changed}, $r->{checked}, 'initial change timestamp');
for my $case (
    ['1.2.3.4', 'V4'], ['1.2.3.4', 'V4'], ['2001:db8::1', 'V6'],
    ['192.0.2.1', 'missing'], ['192.0.2.1', 'missing'], ['1.2.3.4', 'V4'],
    ['', 'missing'],
) {
    is(lookup($case->[0])->{code}, $case->[1], "lookup '$case->[0]'");
}
$r = lookup('::ffff:1.2.3.4');
is($r->{code}, 'V4', 'mapped address in dual database');
is($r->{ipv4}, 'V4', 'mapped address in IPv4-only database');
is(lookup('::102:304')->{ipv4}, 'missing', 'family alias does not reuse IPv4 cache');
is(lookup('1.2.3.4')->{ipv4}, 'V4', 'IPv4 after family alias');
is(lookup('1.2.3.4')->{other}, 'OTHER', 'databases have independent caches');

sub lookup {
    my ($ip) = @_;
    my $type = $ip =~ /:/ ? 'TCP6' : 'TCP4';
    my $dst = $type eq 'TCP6' ? '::1' : '127.0.0.1';
    my $header = $ip eq '' ? "PROXY UNKNOWN\r\n"
        : "PROXY $type $ip $dst 12345 80\r\n";
    return response_fields(stream('127.0.0.1:' . port(8080))->io($header));
}
