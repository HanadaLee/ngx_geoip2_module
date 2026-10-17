#!/usr/bin/perl

# HTTP lookup, data conversion and address-cache regressions.

use warnings;
use strict;
use Test::More;
BEGIN { use FindBin; chdir($FindBin::Bin); }
use lib 'lib';
use Test::Nginx;
use GeoIP2;

my %values = sample_values();
my $t = Test::Nginx->new()->has(qw/http rewrite map/)
    ->plan(scalar(keys %values) + 26);
my $d = $t->testdir();

my @entries = map { [$_->[0], sample_record($_->[1])] }
    (['0.0.0.0', 'ZERO'], ['1.2.3.4', 'V4'], ['127.0.0.1', 'LOCAL'],
     ['2001:db8::1', 'V6']);
$t->write_file('dual.mmdb', mmdb(6, \@entries));
$t->write_file('zero.mmdb', mmdb(6, \@entries));
$t->write_file('ipv4.mmdb', mmdb(4, [@entries[0 .. 2]]));
$t->write_file('other.mmdb', mmdb(4, [['1.2.3.4', sample_record('OTHER')]]));

my $variables = join '', map { "\$v_$_ default=missing source=\$http_x_address $_;\n" }
    sort keys %values;
my $output = join '', map { "$_=\$v_$_\n" } sort keys %values;
$t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
master_process off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    map \$host \$zero { default ::; }
    geoip2 $d/dual.mmdb {
        $variables
        \$code default=missing source=\$http_x_address code;
        \$name source=\$http_x_address country names en;
        \$sub source=\$http_x_address subdivisions 0 code;
        \$absent source=\$http_x_address nonexistent;
        \$map default=missing source=\$http_x_address country;
        \$array default=missing source=\$http_x_address subdivisions;
        \$local code;
        \$epoch metadata build_epoch;
        \$checked metadata last_check;
        \$changed metadata last_change;
    }
    geoip2 $d/zero.mmdb { \$zero_code source=\$zero code; }
    geoip2 $d/ipv4.mmdb { \$ipv4 default=missing source=\$http_x_address code; }
    geoip2 $d/other.mmdb { \$other default=missing source=\$http_x_address code; }
    server {
        listen 127.0.0.1:8080;
        return 200 "$output
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
is($r->{local}, 'LOCAL', 'default source is connection address');
is($r->{epoch}, '1234567890', 'build timestamp');
cmp_ok($r->{checked}, '>', 0, 'initial check timestamp');
is($r->{changed}, $r->{checked}, 'initial change timestamp');

for my $case (
    ['1.2.3.4', 'V4'], ['1.2.3.4', 'V4'], ['2001:db8::1', 'V6'],
    ['192.0.2.1', 'missing'], ['192.0.2.1', 'missing'], ['1.2.3.4', 'V4'],
    ['not-an-ip', 'missing'], ['', 'missing'], ['1.2.3.4, 5.6.7.8', 'missing'],
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
    return response_fields(http("GET / HTTP/1.0\r\nHost: localhost\r\n"
        . "X-Address: $ip\r\n\r\n"));
}
