/*
 * Copyright (C) Hanada
 */


#ifndef _NGX_GEOIP2_H_INCLUDED_
#define _NGX_GEOIP2_H_INCLUDED_


/* "0x" and 32 hexadecimal digits; also fits a signed int64 with 5 decimals. */
#define NGX_GEOIP2_VALUE_LEN  34

/* The absolute integer part must fit nginx's signed 64-bit float formatter. */
#define NGX_GEOIP2_FLOAT_LIMIT  9223372036854775808.0


#endif /* _NGX_GEOIP2_H_INCLUDED_ */
