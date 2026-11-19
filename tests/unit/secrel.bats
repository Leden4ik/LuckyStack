#!/usr/bin/env bats
# Исправления безопасности: разбор списка уязвимостей nginx.org и сравнение версий.
# fixtures/nginx-advisories.html — настоящие записи со страницы nginx.org (ноябрь 2026).

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs secrel
	ADV="$REPO/tests/unit/fixtures/nginx-advisories.html"
}

@test "сравнение версий" {
	_secrel_ge 1.30.7 1.30.6
	_secrel_ge 1.30.7 1.30.7
	_secrel_ge 1.10.0 1.9.5
	_secrel_ge 3.5.10 3.5.9
	! _secrel_ge 1.30.6 1.30.7
	! _secrel_ge 1.9.5 1.10.0
}

@test "разбор страницы nginx.org: все записи и номер CVE даже с опечаткой" {
	run _secrel_nginx_parse "$ADV"
	[ "${#lines[@]}" -eq 6 ]
	[[ "$output" == *"Memory corruption in HTTP/2 flow control|major|CVE-2026-123007|1.31.9+, 1.30.7+|1.9.5-1.31.8"* ]]
	# на сайте написано CVE-CVE-2026-121810
	[[ "$output" == *"|CVE-2026-121810|"* ]]
}

@test "исправленная ветка не считается уязвимой, хотя попадает в общий диапазон" {
	_secrel_nginx_affects 1.30.6 "1.31.9+, 1.30.7+" "1.9.5-1.31.8"
	! _secrel_nginx_affects 1.30.7 "1.31.9+, 1.30.7+" "1.9.5-1.31.8"
	! _secrel_nginx_affects 1.31.9 "1.31.9+, 1.30.7+" "1.9.5-1.31.8"
	# старая ветка, для которой исправления нет, уязвима
	_secrel_nginx_affects 1.28.3 "1.31.9+, 1.30.7+" "1.9.5-1.31.8"
}

@test "несколько диапазонов и уязвимость только в mainline" {
	_secrel_nginx_affects 1.30.5 "1.31.7+, 1.30.6+" "1.31.2-1.31.6, 1.30.0-1.30.5"
	! _secrel_nginx_affects 1.29.9 "1.31.7+, 1.30.6+" "1.31.2-1.31.6, 1.30.0-1.30.5"
	! _secrel_nginx_affects 1.30.6 "1.31.9+" "1.31.4-1.31.8"
	_secrel_nginx_affects 1.31.8 "1.31.9+" "1.31.4-1.31.8"
}

@test "в какой версии исправлено" {
	[ "$(_secrel_nginx_fixed_in 1.30.6 '1.31.9+, 1.30.7+')" = "1.30.7" ]
	[ "$(_secrel_nginx_fixed_in 1.31.8 '1.31.9+, 1.30.7+')" = "1.31.9" ]
	[ "$(_secrel_nginx_fixed_in 1.28.0 '1.31.9+, 1.30.7+')" = "1.31.9" ]
}

@test "отчёт по уязвимому nginx 1.30.6" {
	run _secrel_nginx_report 1.30.6 "$ADV"
	[ "${lines[0]}" = "warn|nginx 1.30.6: уязвимостей 2 (серьёзных 1), исправлено в 1.30.7: luckyctl update nginx" ]
	[[ "${lines[1]}" == "info|серьёзные: Memory corruption in HTTP/2 flow control (CVE-2026-123007)" ]]
}

@test "отчёт по исправленному nginx 1.30.7" {
	run _secrel_nginx_report 1.30.7 "$ADV"
	[ "$output" = "ok|nginx 1.30.7: известных уязвимостей нет (nginx.org)" ]
}

@test "версия PHP из номера пакета" {
	[ "$(_secrel_upstream '8.4.27-2+0~deb.sury.org.1+debian12')" = "8.4.27" ]
	[ "$(_secrel_upstream '1:7.4.33-37+debsuryorg12.1+php+1')" = "7.4.33" ]
	[ "$(_secrel_upstream '8.3.6-0ubuntu0.24.04.5')" = "8.3.6" ]
}
