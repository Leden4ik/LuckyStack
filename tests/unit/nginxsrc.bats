#!/usr/bin/env bats
# После сборки nginx в каталоге сборки остаются только текущие версии исходников.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs nginx
	NGX_SRC="${BATS_TEST_TMPDIR}/src/nginx"; NGX_MOD="$NGX_SRC/modules"
	NGINX_VER=1.30.8; OPENSSL_VER=3.5.9; PCRE2_VER=10.49; ZLIBNG_VER=2.3.3; LIBMAXMINDDB_VER=1.14.1
	GEOIP2_VER=3.4; NGINX_DEV_KIT=0.3.4; CACHEPURGE_VER=3.0.4
	mkdir -p "$NGX_MOD"
	for d in nginx-1.30.6 nginx-1.30.7 nginx-1.30.8; do mkdir -p "$NGX_SRC/$d"; done
	for d in pcre2-10.47 pcre2-10.49 zlib-ng-2.3.3 libmaxminddb-1.13.3 libmaxminddb-1.14.1 ngx_cache_purge ngx_cache_purge-3.0.4 \
	         ngx_devel_kit-0.3.4 quictls ngx_brotli headers-more-nginx-module; do mkdir -p "$NGX_MOD/$d"; done
	touch "$NGX_MOD/openssl-3.6.3.tar.gz" "$NGX_MOD/openssl-3.5.9.tar.gz"
}

@test "старые версии удаляются, текущие, git-модули и собранный OpenSSL остаются" {
	_nginx_prune_sources
	for d in nginx-1.30.6 nginx-1.30.7; do [ ! -e "$NGX_SRC/$d" ]; done
	[ -d "$NGX_SRC/nginx-1.30.8" ]
	for d in pcre2-10.47 libmaxminddb-1.13.3 ngx_cache_purge openssl-3.6.3.tar.gz; do [ ! -e "$NGX_MOD/$d" ]; done
	for d in pcre2-10.49 zlib-ng-2.3.3 libmaxminddb-1.14.1 ngx_cache_purge-3.0.4 ngx_devel_kit-0.3.4 quictls ngx_brotli \
	         headers-more-nginx-module openssl-3.5.9.tar.gz; do [ -e "$NGX_MOD/$d" ]; done
}

@test "без пути к каталогу сборки ничего не удаляется" {
	NGX_SRC=""
	_nginx_prune_sources
	[ -d "$NGX_MOD/pcre2-10.47" ]
}
