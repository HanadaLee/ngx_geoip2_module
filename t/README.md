# GeoIP2 regression tests

These tests use the official `nginx-tests` Perl framework (`Test::Nginx`),
not the separate `Test::Nginx::Socket` distribution. Like its built-in GeoIP
tests, they generate small binary databases locally. No GeoLite download,
MaxMind account, Python package, or database writer is needed.

Build nginx with this module, HTTP rewrite, Stream, and Stream realip support.
Point `PERL5LIB` at the `lib` directory of an `nginx-tests` checkout:

```sh
TEST_NGINX_BINARY=/absolute/path/to/nginx \
PERL5LIB=/absolute/path/to/nginx-tests/lib \
prove -v t/*.t
```

For dynamic builds, load the GeoIP2 modules through `TEST_NGINX_GLOBALS`
(with absolute paths). `Test::Nginx` loads a dynamic core Stream module
automatically; use `TEST_NGINX_MODULES` if it is outside the binary directory.

Tests start only temporary nginx instances on loopback ports. Database
replacement tests operate only on files created in their temporary directories.
Do not point `TEST_NGINX_BINARY` at a wrapper that controls a production service.

Coverage:

- `geoip2.t`, `stream_geoip2.t`: IPv4/IPv6/mapped addresses, zero and negative
  lookup caches, database isolation, nested/array paths, missing values,
  metadata, scalar types and unsafe floating-point values.
- `geoip2_proxy.t`: trusted/untrusted peers, recursive and repeated XFF,
  explicit source precedence.
- `stream_geoip2_realip.t`: default source after PROXY protocol realip handling.
- `geoip2_config.t`: missing/extra arguments, metadata names, invalid options,
  missing/corrupt/duplicate databases and duplicate variable names.
- `geoip2_escape.t`: URI escaping of Unicode and binary values in both modules,
  unescaped defaults, option ordering and independent raw/escaped variables.
- `geoip2_reload.t`: older or preserved timestamps, atomic replacement,
  zero/negative cache invalidation, failed reload recovery, missing files,
  unchanged files and disabled auto reload.

For memory checks, compile nginx with AddressSanitizer/UndefinedBehaviorSanitizer
and `-DNGX_DEBUG_PALLOC=1`, which makes small pool allocations individually
visible to AddressSanitizer. Run the lookup tests with both native and
byte-array uint128 builds of libmaxminddb when testing both representations.
The nginx module and libmaxminddb must use matching headers and ABI.
