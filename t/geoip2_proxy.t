#!/usr/bin/perl

# Match the built-in GeoIP module's trusted proxy and recursive XFF semantics.

use warnings;
use strict;
use Test::More;
BEGIN { use FindBin; chdir($FindBin::Bin); }
use lib 'lib';
use Test::Nginx;
use GeoIP2;

for my $mode (qw/untrusted nonrecursive recursive/) {
    subtest $mode => sub {
        my $t = Test::Nginx->new()->has(qw/http rewrite/)->plan(9);
        my $d = $t->testdir();
        my @entries = map { [$_->[0], mmdb_map(code => mmdb_value(2, $_->[1]))] }
            (['127.0.0.1', 'LOCAL'], ['192.0.2.1', 'CLIENT'],
             ['10.0.0.2', 'EDGE'], ['2001:db8::1', 'V6']);
        $t->write_file('test.mmdb', mmdb(6, \@entries));
        my $trust = $mode eq 'untrusted' ? '198.51.100.0/24' : '127.0.0.1/32';
        my $recursive = $mode eq 'recursive' ? 'on' : 'off';
        $t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
master_process off;
events {}
http {
    %%TEST_GLOBALS_HTTP%%
    geoip2_proxy $trust;
    geoip2_proxy 10.0.0.0/8;
    geoip2_proxy_recursive $recursive;
    geoip2 $d/test.mmdb {
        \$code default=missing code;
        \$explicit default=missing source=\$http_x_address code;
    }
    server {
        listen 127.0.0.1:8080;
        return 200 "code=\$code
explicit=\$explicit
";
    }
}
EOF
        $t->run();
        is(request('')->{code}, 'LOCAL', 'no XFF uses peer');
        is(request('X-Forwarded-For: 192.0.2.1')->{code},
            $mode eq 'untrusted' ? 'LOCAL' : 'CLIENT', 'single XFF');
        my $chain = $mode eq 'untrusted' ? 'LOCAL'
            : $mode eq 'recursive' ? 'CLIENT' : 'EDGE';
        is(request('X-Forwarded-For: 192.0.2.1, 10.0.0.2')->{code},
            $chain, 'XFF chain follows recursive setting');
        is(request("X-Forwarded-For: 192.0.2.1\r\nX-Forwarded-For: 10.0.0.2")->{code},
            $chain, 'repeated XFF headers');
        is(request('X-Forwarded-For: invalid')->{code}, 'LOCAL', 'invalid XFF uses peer');
        is(request('X-Forwarded-For: 2001:db8::1')->{code},
            $mode eq 'untrusted' ? 'LOCAL' : 'V6', 'IPv6 XFF');
        is(request('X-Forwarded-For: ::ffff:192.0.2.1')->{code},
            $mode eq 'untrusted' ? 'LOCAL' : 'CLIENT', 'mapped XFF');
        is(request("X-Forwarded-For: 10.0.0.2\r\nX-Address: 192.0.2.1")->{explicit},
            'CLIENT', 'explicit source bypasses proxy selection');
        is(request("X-Forwarded-For: 192.0.2.1\r\nX-Address: invalid")->{explicit},
            'missing', 'invalid explicit source does not fall back to XFF');
    };
}
done_testing();

sub request {
    my ($headers) = @_;
    return response_fields(http("GET / HTTP/1.0\r\nHost: localhost\r\n"
        . "$headers\r\n\r\n"));
}
