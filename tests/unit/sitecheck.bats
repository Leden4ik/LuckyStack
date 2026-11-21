#!/usr/bin/env bats
# Проверка сайтов до и после обновления: curl и база ISPConfig подменены, сеть не нужна.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs sitecheck
	SC_DIR="${BATS_TEST_TMPDIR}/sc"
	SC_ISPC_CONF="${BATS_TEST_TMPDIR}/config.inc.php"; : >"$SC_ISPC_CONF"
	SC_RETRY_WAIT=0
	SERVER_FQDN="srv.example.net"
	ISPCONFIG_PANEL_PORT=8080
	UPD_FAILED=()
	ui_header() { :; }; ui_box_top() { :; }; ui_box_line() { :; }; ui_box_bottom() { :; }
	_sc_panel_port() { echo 8080; }
	ls_hint() { echo "luckyctl ${1#--}${2:+ $2}"; }
	_ispc_mysql() { printf '%s\n' a.example.com b.example.com '*.wild.example.com'; }
	# коды ответа: по умолчанию 200, переопределяются в CODES_FILE строками «url код»
	CODES_FILE="${BATS_TEST_TMPDIR}/codes"; : >"$CODES_FILE"
	curl() {
		local url="${*: -1}" c
		c="$(awk -v u="$url" '$1 == u { c = $2 } END { print c }' "$CODES_FILE")"
		printf '%s' "${c:-200}"
	}
	export -f curl 2>/dev/null || true
}

code() { echo "$1 $2" >>"$CODES_FILE"; }

@test "что считается поломкой" {
	_sc_regress 200 502
	_sc_regress 301 000
	_sc_regress 200 404
	_sc_regress 302 403
	! _sc_regress 200 200
	! _sc_regress 502 200
	! _sc_regress 404 200
	! _sc_regress 200 301
	! _sc_regress 502 503
	! _sc_regress 403 404
}

@test "адреса: панель, Roundcube, phpMyAdmin и каждый сайт по https и http, без wildcard" {
	run _sc_targets
	[[ "$output" == *$'панель ISPConfig\thttps://srv.example.net:8080/login/\tsrv.example.net\t8080'* ]]
	[[ "$output" == *$'https://a.example.com/\thttps://a.example.com/\ta.example.com\t443'* ]]
	[[ "$output" == *$'http://b.example.com/\thttp://b.example.com/\tb.example.com\t80'* ]]
	[[ "$output" != *wild* ]]
	[ "$(wc -l <<<"$output")" -eq 7 ]
}

@test "без ISPConfig проверять нечего" {
	rm -f "$SC_ISPC_CONF"
	run sc_snapshot before
	[ "$status" -eq 1 ]
}

@test "замер: код каждого адреса, по алфавиту" {
	code https://b.example.com/ 502
	f="$(sc_snapshot before)"
	[ -s "$f" ]
	grep -qx $'https://b.example.com/\t502' "$f"
	grep -qx $'http://a.example.com/\t200' "$f"
	[ "$(wc -l <"$f")" -eq 7 ]
}

@test "после обновления всё как было: ошибок нет" {
	before="$(sc_snapshot before)"
	sc_after_update "$before" 0 0
	[ "${#UPD_FAILED[@]}" -eq 0 ]
}

@test "сайт стал отдавать 502: попадает в ошибки обновления" {
	before="$(sc_snapshot before)"
	code https://a.example.com/ 502
	sc_after_update "$before" 0 0
	[ "${#UPD_FAILED[@]}" -eq 1 ]
	[[ "${UPD_FAILED[0]}" == *"перестали отвечать 1"*"https://a.example.com/: 200 → 502"* ]]
}

@test "сайт, который поднялся при перепроверке, ошибкой не считается" {
	before="$(sc_snapshot before)"
	code https://a.example.com/ 000
	# после первой паузы сайт уже отвечает
	sleep() { code https://a.example.com/ 200; }
	sc_after_update "$before" 0 0
	[ "${#UPD_FAILED[@]}" -eq 0 ]
}

@test "сайт починился после обновления: это не ошибка" {
	code http://b.example.com/ 502
	before="$(sc_snapshot before)"
	: >"$CODES_FILE"
	sc_after_update "$before" 0 0
	[ "${#UPD_FAILED[@]}" -eq 0 ]
}

@test "luckyctl sites: код 1, если адрес не работает, и разница с прошлой проверкой" {
	run run_sitecheck
	[ "$status" -eq 0 ]
	code https://srv.example.net:8080/login/ 000
	run run_sitecheck
	[ "$status" -eq 1 ]
	ls "$SC_DIR"/*.tsv >/dev/null
}

@test "старые замеры удаляются" {
	SC_KEEP=3
	for i in 1 2 3 4 5; do
		f="$(sc_snapshot before)"; touch -d "-${i} minutes" "$f"; mv "$f" "${SC_DIR}/old-${i}.tsv"
	done
	sc_snapshot check >/dev/null
	[ "$(ls "$SC_DIR"/*.tsv | wc -l)" -le 3 ]
}
