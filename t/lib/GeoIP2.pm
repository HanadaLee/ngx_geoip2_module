package GeoIP2;

use warnings;
use strict;
use Exporter 'import';
use Socket qw/ AF_INET AF_INET6 inet_pton /;

our @EXPORT = qw/ mmdb mmdb_value mmdb_map mmdb_array sample_record
    sample_values response_fields /;

# Small synthetic databases, like the fixtures in nginx-tests/geoip.t.
# No downloaded GeoLite database, account, or MMDB writer is required.
# Encoding: https://maxmind.github.io/MaxMind-DB/

sub control {
    my ($type, $size) = @_;
    die 'test value too large' if $size >= 285;
    return pack('C', (($type < 8 ? $type : 0) << 5)
        | ($size < 29 ? $size : 29))
        . ($type < 8 ? '' : pack('C', $type - 7))
        . ($size < 29 ? '' : pack('C', $size - 29));
}

sub mmdb_value {
    my ($type, $bytes) = @_;
    return control($type, length $bytes) . $bytes;
}

sub mmdb_map {
    my (%fields) = @_;
    return control(7, scalar keys %fields)
        . join('', map { mmdb_value(2, $_) . $fields{$_} } sort keys %fields);
}

sub mmdb_array {
    return control(11, scalar @_) . join('', @_);
}

sub mmdb {
    my ($version, $entries, %options) = @_;
    my @nodes = ([undef, undef]);
    my $data = $options{padding} // '';

    for my $entry (@$entries) {
        my ($ip, $value) = @$entry;
        my $v6 = $ip =~ /:/;
        die 'IPv6 entry in IPv4 database' if $v6 && $version == 4;
        my $address = inet_pton($v6 ? AF_INET6 : AF_INET, $ip);
        die "invalid fixture address: $ip" unless defined $address;
        $address = ("\0" x 12) . $address if !$v6 && $version == 6;
        my @bits = split //, unpack('B*', $address);
        my $node = 0;
        for my $i (0 .. $#bits) {
            my $bit = $bits[$i];
            if ($i == $#bits) {
                my $offset = length $data;
                $nodes[$node][$bit] = \$offset;
                $data .= $value;
                last;
            }
            if (!defined $nodes[$node][$bit]) {
                $nodes[$node][$bit] = scalar @nodes;
                push @nodes, [undef, undef];
            }
            $node = $nodes[$node][$bit];
        }
    }

    my $count = scalar @nodes;
    my $tree = '';
    for my $node (@nodes) {
        for my $child (@$node) {
            my $pointer = !defined $child ? $count
                : ref $child ? $count + 16 + $$child : $child;
            $tree .= substr(pack('N', $pointer), 1);
        }
    }

    my $metadata = mmdb_map(
        node_count => mmdb_value(6, pack('N', $count)),
        record_size => mmdb_value(5, pack('n', 24)),
        ip_version => mmdb_value(5, pack('n', $version)),
        database_type => mmdb_value(2, 'GeoIP2-Test'),
        binary_format_major_version => mmdb_value(5, pack('n', 2)),
        binary_format_minor_version => mmdb_value(5, pack('n', 0)),
        build_epoch => mmdb_value(9, pack('N', $options{epoch} // 1234567890)),
        languages => mmdb_array(mmdb_value(2, 'en')),
        description => mmdb_map(en => mmdb_value(2, 'Synthetic test data')),
    );
    return $tree . ("\0" x 16) . $data . "\xab\xcd\xefMaxMind.com" . $metadata;
}

sub sample_record {
    my ($code) = @_;
    return mmdb_map(
        code => mmdb_value(2, $code),
        country => mmdb_map(names => mmdb_map(en => mmdb_value(2, 'Test land'))),
        subdivisions => mmdb_array(mmdb_map(code => mmdb_value(2, 'A1'))),
        bytes => mmdb_value(4, 'bytes'),
        empty => mmdb_value(2, ''),
        yes => control(14, 1), no => control(14, 0),
        uint16 => mmdb_value(5, pack('H*', 'ffff')),
        uint32 => mmdb_value(6, pack('H*', 'ffffffff')),
        int32 => mmdb_value(8, pack('H*', '80000000')),
        uint64 => mmdb_value(9, pack('H*', 'ffffffffffffffff')),
        uint128 => mmdb_value(10, pack('H*', '0123456789abcdeffedcba9876543210')),
        float => mmdb_value(15, pack('f>', -12.5)),
        double => mmdb_value(3, pack('d>', 123.125)),
        large => mmdb_value(3, pack('d>', -1e15)),
        positive => mmdb_value(3, pack('d>', 1e15)),
        nan => mmdb_value(3, pack('H*', '7ff8000000000000')),
        infinity => mmdb_value(3, pack('H*', '7ff0000000000000')),
        negative_infinity => mmdb_value(3, pack('H*', 'fff0000000000000')),
        limit => mmdb_value(3, pack('d>', 2**63)),
        negative_limit => mmdb_value(3, pack('d>', -(2**63))),
        large_float => mmdb_value(15, pack('f>', 1e30)),
        float_nan => mmdb_value(15, pack('H*', '7fc00000')),
    );
}

sub sample_values {
    return (
        bytes => 'bytes', empty => '', yes => '1', no => '0',
        uint16 => '65535', uint32 => '4294967295', int32 => '-2147483648',
        uint64 => '18446744073709551615',
        uint128 => '0x0123456789abcdeffedcba9876543210',
        float => '-12.50000', double => '123.12500',
        large => '-1000000000000000.00000', positive => '1000000000000000.00000',
        nan => 'missing', infinity => 'missing', negative_infinity => 'missing',
        limit => 'missing', negative_limit => 'missing', large_float => 'missing',
        float_nan => 'missing',
    );
}

sub response_fields {
    my ($response) = @_;
    $response =~ s/\A.*?\r\n\r\n//s if $response =~ /^HTTP\//;
    return { $response =~ /^([a-z0-9_]+)=([^\r\n]*)/gm };
}

1;
