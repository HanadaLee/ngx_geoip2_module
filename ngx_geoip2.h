/*
 * Copyright (C) Hanada
 */


#ifndef _NGX_GEOIP2_H_INCLUDED_
#define _NGX_GEOIP2_H_INCLUDED_


/* "0x" and 32 hexadecimal digits; also fits a signed int64 with 5 decimals. */
#define NGX_GEOIP2_VALUE_LEN  34

/* The absolute integer part must fit nginx's signed 64-bit float formatter. */
#define NGX_GEOIP2_FLOAT_LIMIT  9223372036854775808.0


static ngx_int_t
ngx_geoip2_escape_uri(ngx_pool_t *pool, ngx_str_t *value)
{
    u_char     *p;
    uintptr_t   n;

    n = ngx_escape_uri(NULL, value->data, value->len, NGX_ESCAPE_URI_COMPONENT);
    if (n == 0) {
        return NGX_OK;
    }

    p = ngx_pnalloc(pool, value->len + 2 * n);
    if (p == NULL) {
        return NGX_ERROR;
    }

    (void) ngx_escape_uri(p, value->data, value->len, NGX_ESCAPE_URI_COMPONENT);

    value->data = p;
    value->len += 2 * n;

    return NGX_OK;
}


static ngx_int_t
ngx_geoip2_file_changed(ngx_file_info_t *a, ngx_file_info_t *b)
{
    if (ngx_file_uniq(a) != ngx_file_uniq(b)
        || ngx_file_size(a) != ngx_file_size(b)
        || ngx_file_mtime(a) != ngx_file_mtime(b))
    {
        return 1;
    }

#if (NGX_WIN32)
    return a->dwVolumeSerialNumber != b->dwVolumeSerialNumber
           || a->ftLastWriteTime.dwHighDateTime
              != b->ftLastWriteTime.dwHighDateTime
           || a->ftLastWriteTime.dwLowDateTime
              != b->ftLastWriteTime.dwLowDateTime;
#else
    if (a->st_dev != b->st_dev || a->st_ctime != b->st_ctime) {
        return 1;
    }

#if (NGX_GEOIP2_HAVE_STAT_ST_MTIM)
    return a->st_mtim.tv_nsec != b->st_mtim.tv_nsec
           || a->st_ctim.tv_nsec != b->st_ctim.tv_nsec;
#elif (NGX_GEOIP2_HAVE_STAT_ST_MTIMESPEC)
    return a->st_mtimespec.tv_nsec != b->st_mtimespec.tv_nsec
           || a->st_ctimespec.tv_nsec != b->st_ctimespec.tv_nsec;
#else
    return 0;
#endif
#endif
}


static ngx_int_t
ngx_geoip2_open(const char *name, MMDB_s *mmdb, ngx_file_info_t *fi,
    ngx_log_t *log)
{
    int              status;
    ngx_file_info_t  before;

    if (ngx_file_info(name, &before) == NGX_FILE_ERROR) {
        ngx_log_error(NGX_LOG_ERR, log, ngx_errno,
                      ngx_file_info_n " \"%s\" failed", name);
        return NGX_ERROR;
    }

    status = MMDB_open(name, MMDB_MODE_MMAP, mmdb);
    if (status != MMDB_SUCCESS) {
        ngx_log_error(NGX_LOG_ERR, log, 0, "MMDB_open(\"%s\") failed: %s",
                      name, MMDB_strerror(status));
        return NGX_ERROR;
    }

    if (ngx_file_info(name, fi) == NGX_FILE_ERROR) {
        ngx_log_error(NGX_LOG_ERR, log, ngx_errno,
                      ngx_file_info_n " \"%s\" failed", name);
        MMDB_close(mmdb);
        return NGX_ERROR;
    }

    if (ngx_geoip2_file_changed(&before, fi)) {
        ngx_log_error(NGX_LOG_WARN, log, 0,
                      "GeoIP2 database \"%s\" changed while opening", name);
        MMDB_close(mmdb);
        return NGX_ERROR;
    }

    return NGX_OK;
}


#endif /* _NGX_GEOIP2_H_INCLUDED_ */
