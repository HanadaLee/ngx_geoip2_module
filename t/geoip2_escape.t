#!/usr/bin/perl

# Per-variable URI escaping in HTTP and Stream.

use warnings;
use strict;
use Test::More;
BEGIN { use FindBin; chdir($FindBin::Bin); }
use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;
use GeoIP2;

my $unicode = pack('H*', 'c58c627520e4b88ae6b5b7');
my $reserved = q{ /?#[]@!$&'()*+,;=:%};
my $bytes = pack('C*', 0 .. 255);
my $escaped_bytes = join '', map {
    chr($_) =~ /[A-Za-z0-9._~-]/ ? chr($_) : sprintf('%%%02X', $_)
} 0 .. 255;
my $record = mmdb_map(
    safe => mmdb_value(2, 'AZaz019-._~'),
    unicode => mmdb_value(2, $unicode),
    reserved => mmdb_value(2, $reserved),
    bytes => mmdb_value(4, $bytes),
    empty => mmdb_value(2, ''),
    integer => mmdb_value(6, pack('N', 4294967295)),
    signed => mmdb_value(8, pack('H*', 'ffffffff')),
    float => mmdb_value(15, pack('f>', -12.5)),
    nested => mmdb_map(name => mmdb_value(2, $unicode)),
);

my @cases = (
    ['safe', 'escape=uri safe', 'AZaz019-._~'],
    ['unicode', 'escape=uri unicode', '%C5%8Cbu%20%E4%B8%8A%E6%B5%B7'],
    ['reserved', 'escape=uri reserved', '%20%2F%3F%23%5B%5D%40%21%24%26%27%28%29%2A%2B%2C%3B%3D%3A%25'],
    ['bytes', 'escape=uri bytes', $escaped_bytes],
    ['empty', 'escape=uri default=fallback empty', ''],
    ['integer', 'escape=uri integer', '4294967295'],
    ['signed', 'escape=uri signed', '-1'],
    ['float', 'escape=uri float', '-12.50000'],
    ['raw_unicode', 'unicode', $unicode],
    ['raw_reserved', 'reserved', $reserved],
    ['nested', 'source=$remote_addr escape=uri nested name', '%C5%8Cbu%20%E4%B8%8A%E6%B5%B7'],
    ['reordered', 'default=fallback escape=uri source=$remote_addr unicode', '%C5%8Cbu%20%E4%B8%8A%E6%B5%B7'],
    ['missing', 'escape=uri nonexistent', ''],
    ['default', 'escape=uri "default=fallback /%" nonexistent', 'fallback /%'],
    ['invalid_source', 'source=$invalid escape=uri "default=fallback /%" unicode', 'fallback /%'],
    ['missing_address', 'source=$absent escape=uri "default=fallback /%" unicode', 'fallback /%'],
    ['map', 'escape=uri "default=fallback /%" nested', 'fallback /%'],
);

for my $mode (qw/http stream/) {
    subtest $mode => sub {
        my @modules = $mode eq 'http' ? qw/http rewrite map/
            : qw/stream stream_return stream_map/;
        my $t = Test::Nginx->new()->has(@modules)->plan(scalar @cases);
        my $d = $t->testdir();
        $t->write_file('test.mmdb', mmdb(4, [['127.0.0.1', $record]]));
        my $variables = join '', map { "\$v_$_->[0] $_->[1];\n" } @cases;
        my $output = join '', map { "$_->[0]=\$v_$_->[0]\n" } @cases;
        my $globals = $mode eq 'http' ? '%%TEST_GLOBALS_HTTP%%'
            : '%%TEST_GLOBALS_STREAM%%';
        my $status = $mode eq 'http' ? '200' : '';
        $t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
master_process off;
events {}
$mode {
    $globals
    map \$remote_addr \$invalid { default not-an-ip; }
    map \$remote_addr \$absent { default 192.0.2.1; }
    geoip2 $d/test.mmdb {
        $variables
    }
    server {
        listen 127.0.0.1:8080;
        return $status "$output";
    }
}
EOF
        $t->run();
        my $response = $mode eq 'http' ? http_get('/')
            : stream('127.0.0.1:' . port(8080))->io('');
        my $fields = response_fields($response);
        for my $case (@cases) {
            is($fields->{$case->[0]}, $case->[2], $case->[0]);
        }
    };
}

done_testing();
