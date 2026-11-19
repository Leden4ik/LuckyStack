#!/usr/bin/env bats
# Модернизация vhost панели: http2, TLSv1.3, QUIC и дубли заголовков безопасности

load helpers

setup() {
	load_libs ui ispconfig
	V="${BATS_TEST_TMPDIR}/ispconfig.vhost"
	export LS_NGINX_CONF="${BATS_TEST_TMPDIR}/nginx.conf"
	cat >"$V" <<'EOF'
server {
        listen 8080 ssl http2;
        server_name _;
        ssl_protocols TLSv1.2;
        add_header X-Content-Type-Options nosniff always;
        add_header X-Frame-Options SAMEORIGIN always;
        add_header Referrer-Policy same-origin always;
        add_header Strict-Transport-Security "max-age=15768000" always;
}
EOF
}

with_global_headers() {
	cat >"$LS_NGINX_CONF" <<'EOF'
http {
    more_set_headers 'X-Content-Type-Options: nosniff' always;
    more_set_headers 'X-Frame-Options: SAMEORIGIN' always;
    more_set_headers 'Referrer-Policy: strict-origin-when-cross-origin' always;
}
EOF
}

@test "http2 из listen переносится в http2 on, TLSv1.3 добавляется" {
	: >"$LS_NGINX_CONF"
	_modernize_vhost_file "$V" n
	grep -q '^ *listen 8080 ssl;' "$V"
	grep -q '^ *http2 on;' "$V"
	grep -q 'ssl_protocols TLSv1.2 TLSv1.3;' "$V"
}

@test "без глобальных заголовков свои заголовки панели остаются" {
	: >"$LS_NGINX_CONF"
	_modernize_vhost_file "$V" n
	grep -q 'add_header X-Frame-Options' "$V"
	grep -q 'add_header Referrer-Policy same-origin' "$V"
}

@test "при глобальных заголовках дубли убираются, Referrer-Policy панели остаётся строгим" {
	with_global_headers
	_modernize_vhost_file "$V" n
	! grep -q 'add_header X-Content-Type-Options' "$V"
	! grep -q 'add_header X-Frame-Options' "$V"
	grep -q "more_set_headers 'Referrer-Policy: same-origin' always;" "$V"
	grep -q 'Strict-Transport-Security' "$V"
}

@test "HTTP/3: добавляются http3 on, Alt-Svc и quic-listen" {
	: >"$LS_NGINX_CONF"
	_modernize_vhost_file "$V" y
	grep -q '^ *http3 on;' "$V"
	grep -q "Alt-Svc 'h3=\":8080\"" "$V"
	grep -q 'listen 8080 quic reuseport;' "$V"
}

@test "повторный прогон ничего не меняет" {
	with_global_headers
	_modernize_vhost_file "$V" y
	cp "$V" "${V}.1"
	run _modernize_vhost_file "$V" y
	[ "$status" -eq 2 ]
	cmp -s "$V" "${V}.1"
}
