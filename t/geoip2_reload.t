#!/usr/bin/perl

# File replacement, failed reload recovery and cached entry invalidation.

use warnings;
use strict;
use Test::More;
use Time::HiRes qw/ time sleep /;
BEGIN { use FindBin; chdir($FindBin::Bin); }
use lib 'lib';
use Test::Nginx;
use Test::Nginx::Stream qw/ stream /;
use GeoIP2;

for my $mode (qw/http stream/) {
    subtest $mode => sub {
        my $t = Test::Nginx->new()->has($mode)->plan(20);
        my $d = $t->testdir();
        $t->write_file('active.mmdb', database('A', 1));
        $t->write_file('disabled.mmdb', database('STATIC', 1));
        utime 1234567890, 1234567890, "$d/active.mmdb" or die "utime: $!";
        my $src = $mode eq 'http' ? '$http_x_address' : '$proxy_protocol_addr';
        my $globals = $mode eq 'http' ? '%%TEST_GLOBALS_HTTP%%' : '%%TEST_GLOBALS_STREAM%%';
        my $pp = $mode eq 'stream' ? 'proxy_protocol' : '';
        my $status = $mode eq 'http' ? '200' : '';
        $t->write_file_expand('nginx.conf', <<EOF);
%%TEST_GLOBALS%%
daemon off;
master_process off;
events {}
$mode {
    $globals
    geoip2 $d/active.mmdb {
        auto_reload 1s;
        \$code default=missing source=$src code;
        \$epoch metadata build_epoch;
        \$check metadata last_check;
        \$change metadata last_change;
    }
    geoip2 $d/disabled.mmdb { \$disabled source=$src code; }
    server {
        listen 127.0.0.1:8080 $pp;
        return $status "code=\$code
epoch=\$epoch
check=\$check
change=\$change
disabled=\$disabled
";
    }
}
EOF
        $t->run();
        my $query = sub { query($mode, $_[0] // '0.0.0.0') };
        my $r = $query->();
        is($r->{code}, 'A', 'initial zero lookup');
        is($query->('1.2.3.4')->{code}, 'A', 'warm nonzero lookup');

        # Older timestamp, and a different data offset in the replacement.
        replace($t, 'active.mmdb', database('B', 2), 1234567880);
        $r = wait_for($query, sub { $_[0]->{epoch} eq '2' });
        is($r->{epoch}, '2', 'reload with older mtime');
        is($r->{code}, 'B', 'zero address cache invalidated after reload');
        is($query->('1.2.3.4')->{code}, 'B', 'nonzero cache invalidated');
        cmp_ok($r->{change}, '>', 1234567890, 'last_change is reload time, not file mtime');

        replace($t, 'active.mmdb', database('C', 3), 1234567880);
        $r = wait_for($query, sub { $_[0]->{epoch} eq '3' });
        is($r->{epoch}, '3', 'same-mtime atomic replacement detected');
        is($r->{code}, 'C', 'same-IP lookup reads new database');
        my $change = $r->{change};
        my $check = $r->{check};
        $r = wait_for($query, sub { $_[0]->{check} > $check });
        cmp_ok($r->{check}, '>', $check, 'unchanged database checked again');
        is($r->{change}, $change, 'unchanged file not reloaded');

        replace($t, 'active.mmdb', 'corrupt database', 1234567880);
        wait_for($query, sub { $t->read_file('error.log') =~ /MMDB_open.*failed/ });
        like($t->read_file('error.log'), qr/MMDB_open.*failed/, 'failed reload logged');
        $r = $query->();
        is($r->{code}, 'C', 'failed reload retains old database and cache');
        is($r->{change}, $change, 'failed reload leaves last_change unchanged');

        replace($t, 'active.mmdb', database('D', 4), 1234567880);
        $r = wait_for($query, sub { $_[0]->{epoch} eq '4' });
        is($r->{code}, 'D', 'valid replacement recovers after failure');
        rename "$d/active.mmdb", "$d/saved.mmdb" or die "rename: $!";
        wait_for($query, sub { $t->read_file('error.log') =~ /stat.*active\.mmdb.*failed/ });
        like($t->read_file('error.log'), qr/\[error\].*stat.*active\.mmdb.*failed/,
            'missing file logged at error level');
        is($query->()->{code}, 'D', 'missing file retains mapped database');

        is($query->('192.0.2.1')->{code}, 'missing', 'cache a negative lookup');
        replace($t, 'active.mmdb', database('E', 5), 1234567880);
        replace($t, 'disabled.mmdb', database('CHANGED', 5), 1234567880);
        $r = wait_for(sub { $query->('192.0.2.1') }, sub { $_[0]->{epoch} eq '5' });
        is($r->{code}, 'E', 'negative lookup cache invalidated on reload');
        is($query->()->{disabled}, 'STATIC', 'auto_reload disabled by default');
        is($query->('::ffff:1.2.3.4')->{code}, 'E', 'mapped lookup after repeated reloads');
        $t->stop();
    };
}
done_testing();

sub database {
    my ($code, $epoch) = @_;
    my @ips = ('0.0.0.0', '1.2.3.4');
    push @ips, '192.0.2.1' if $epoch == 5;
    return mmdb(4, [map { [$_, mmdb_map(code => mmdb_value(2, $code))] } @ips],
        epoch => $epoch, padding => mmdb_value(2, 'x' x ($epoch * 7)));
}

sub replace {
    my ($t, $name, $data, $mtime) = @_;
    my $path = $t->testdir() . "/$name";
    $t->write_file("$name.new", $data);
    utime $mtime, $mtime, "$path.new" or die "utime: $!";
    rename "$path.new", $path or die "rename: $!";
}

sub query {
    my ($mode, $ip) = @_;
    return response_fields(http("GET / HTTP/1.0\r\nHost: localhost\r\n"
        . "X-Address: $ip\r\n\r\n")) if $mode eq 'http';
    my $type = $ip =~ /:/ ? 'TCP6' : 'TCP4';
    my $dst = $type eq 'TCP6' ? '::1' : '127.0.0.1';
    return response_fields(stream('127.0.0.1:' . port(8080))
        ->io("PROXY $type $ip $dst 12345 80\r\n"));
}

sub wait_for {
    my ($query, $predicate) = @_;
    my $deadline = time() + 5;
    my $r;
    do {
        $r = $query->();
        return $r if $predicate->($r);
        sleep 0.05;
    } while (time() < $deadline);
    return $r; # Caller assertions report failures rather than skipping them.
}
