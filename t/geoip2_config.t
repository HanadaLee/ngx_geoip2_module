#!/usr/bin/perl

# Custom block handlers must validate their own argument counts and values.

use warnings;
use strict;
use Test::More;
BEGIN { use FindBin; chdir($FindBin::Bin); }
use lib 'lib';
use Test::Nginx;
use GeoIP2;

my @invalid = (
    ['$v;', qr/missing GeoIP2 lookup path/, 'missing lookup path'],
    ['$v metadata;', qr/invalid number of arguments/, 'missing metadata field'],
    ['$v metadata build_epoch extra;', qr/invalid number of arguments/, 'extra metadata argument'],
    ['$v metadata build_epoch_suffix;', qr/invalid GeoIP2 metadata field/, 'build_epoch prefix'],
    ['$v metadata last_check_suffix;', qr/invalid GeoIP2 metadata field/, 'last_check prefix'],
    ['$v metadata last_change_suffix;', qr/invalid GeoIP2 metadata field/, 'last_change prefix'],
    ['$v metadata unknown;', qr/invalid GeoIP2 metadata field/, 'unknown metadata field'],
    ['$v default=fallback;', qr/missing GeoIP2 lookup path/, 'default without path'],
    ['$v source=$remote_addr;', qr/missing GeoIP2 lookup path/, 'source without path'],
    ['$v default=fallback source=$remote_addr;', qr/missing GeoIP2 lookup path/, 'options without path'],
    ['$ code;', qr/invalid variable name/, 'empty variable name'],
    ['variable code;', qr/invalid setting/, 'missing dollar prefix'],
    ['$v default=a default=b code;', qr/default has already been declared/, 'duplicate default'],
    ['$v source=$remote_addr source=$remote_addr code;', qr/source has already been declared/, 'duplicate source'],
    ['$v source=127.0.0.1 code;', qr/invalid source variable name/, 'literal source'],
    ['$v invalid=x code;', qr/invalid setting/, 'unknown option'],
    ['auto_reload;', qr/invalid number of arguments/, 'missing reload interval'],
    ['auto_reload 1s extra;', qr/invalid number of arguments/, 'extra reload argument'],
    ['auto_reload invalid;', qr/invalid interval/, 'invalid reload interval'],
    ['auto_reload -1s;', qr/invalid interval/, 'negative reload interval'],
    ['$previous metadata build_epoch; $v;', qr/missing GeoIP2 lookup path/, 'stale token after longer statement'],
    ['$previous metadata build_epoch; $v metadata;', qr/invalid number of arguments/, 'stale metadata token'],
);

for my $mode (qw/http stream/) {
    subtest $mode => sub {
        my $t = Test::Nginx->new()->has($mode)->plan(2 * @invalid + 8);
        my $d = $t->testdir();
        $t->write_file('test.mmdb', mmdb(4, [['127.0.0.1', sample_record('LOCAL')]]));
        $t->write_file('corrupt.mmdb', 'not a database');
        $t->write_file('error.log', '');

        for my $case (@invalid) {
            config($t, $mode, "geoip2 $d/test.mmdb { $case->[0] }");
            my ($status, $log) = check_config($t);
            is($status, 1, "$case->[2] rejected without a signal");
            like($log, $case->[1], "$case->[2] diagnostic");
        }

        config($t, $mode, "geoip2 $d/test.mmdb { " . <<'EOF');
            $code default=fallback source=$remote_addr code;
            $reordered source=$remote_addr default=fallback country names en;
            $epoch metadata build_epoch;
            $check metadata last_check;
            $change metadata last_change;
            auto_reload 1s;
        }
EOF
        my ($status, $log) = check_config($t);
        is($status, 0, 'valid options, metadata and interval');
        unlike($log, qr/Sanitizer|runtime error:/, 'valid config has no sanitizer errors');

        for my $case (
            ["geoip2 $d/missing.mmdb { \$v code; }", qr/could not open GeoIP2 database/, 'missing database'],
            ["geoip2 $d/corrupt.mmdb { \$v code; }", qr/could not open GeoIP2 database/, 'corrupt database'],
            ["geoip2 $d/test.mmdb { \$a code; } geoip2 $d/test.mmdb { \$b code; }", qr/Duplicate GeoIP2 mmdb/, 'duplicate database'],
        ) {
            config($t, $mode, $case->[0]);
            ($status, $log) = check_config($t);
            is($status, 1, "$case->[2] rejected");
            like($log, $case->[1], "$case->[2] diagnostic");
        }
    };
}
done_testing();

sub config {
    my ($t, $mode, $block) = @_;
    my $globals = $mode eq 'http' ? '%%TEST_GLOBALS_HTTP%%' : '%%TEST_GLOBALS_STREAM%%';
    $t->write_file_expand('nginx.conf', "%%TEST_GLOBALS%%\nevents {}\n$mode { $globals\n$block\n}\n");
}

sub check_config {
    my ($t) = @_;
    my $pid = open my $pipe, '-|';
    die "fork: $!" unless defined $pid;
    if (!$pid) {
        open STDERR, '>&', \*STDOUT or die "redirect: $!";
        exec $Test::Nginx::NGINX, '-t', '-p', $t->testdir() . '/',
            '-c', 'nginx.conf', '-e', 'stderr';
        die "exec: $!";
    }
    local $/;
    my $log = <$pipe>;
    close $pipe;
    return ($? & 127 ? -($? & 127) : $? >> 8, $log);
}
