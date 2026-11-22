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

# --- PHP: журнал изменений пакета и сборки Sury -----------------------------

php_setup() {
	CL="$REPO/tests/unit/fixtures/php7.4-changelog"
	SECREL_PHP_ETC="${BATS_TEST_TMPDIR}/etc-php"; mkdir -p "$SECREL_PHP_ETC/7.4/fpm"
	SECREL_DOC_DIR="${BATS_TEST_TMPDIR}/doc"; mkdir -p "$SECREL_DOC_DIR/php7.4-common"
	SECREL_CACHE="${BATS_TEST_TMPDIR}/cache"; mkdir -p "$SECREL_CACHE"
	# php.net: ветки 7.4 в списке поддерживаемых нет
	echo '{"8":{"8.4":{"version":"8.4.28"}}}' >"$SECREL_CACHE/php-active.json"; touch "$SECREL_CACHE/php-active.json"
	INST="1:7.4.33-37+debsuryorg12.1+php+1"; CAND="1:7.4.33-38+debsuryorg12.1+1"
	dpkg-query() { echo -n "$INST"; }
	apt-cache() { printf 'php7.4-fpm:\n  Installed: %s\n  Candidate: %s\n' "$INST" "$CAND"; }
	command -v dpkg >/dev/null || skip "нет dpkg"
}

@test "журнал изменений: версии, число CVE и даты" {
	run _secrel_deb_log "$REPO/tests/unit/fixtures/php7.4-changelog"
	[ "${#lines[@]}" -eq 6 ]
	[ "${lines[0]}" = "1:7.4.33-38+debsuryorg12.1+1|0|Fri, 20 Nov 2026 15:29:05 +0100" ]
	[ "${lines[4]}" = "1:7.4.33-36|12|Tue, 17 Nov 2026 15:59:33 +0100" ]
}

@test "CVE только в записях новее установленной сборки" {
	php_setup
	[ "$(_secrel_new_cves "$CL" "$INST")" = "0" ]
	[ "$(_secrel_new_cves "$CL" "1:7.4.33-35+debsuryorg12.1+1")" = "12" ]
}

@test "последний перенос исправлений: дата и число" {
	run _secrel_last_backport "$REPO/tests/unit/fixtures/php7.4-changelog"
	[[ "$output" == "17.11.2026|12|"* ]]
}

@test "PHP 7.4 от Sury со свежими исправлениями: не тревога, а пометка" {
	php_setup
	cp "$CL" "$SECREL_DOC_DIR/php7.4-common/changelog.Debian.gz"
	cp "$CL" "$SECREL_CACHE/php7.4-common_1_7.4.33-38+debsuryorg12.1+1.changelog"
	SECREL_BACKPORT_DAYS=100000
	run _secrel_php
	[[ "$output" == *"info|PHP 7.4.33: в репозитории новая сборка без исправлений безопасности"* ]]
	[[ "$output" == *"info|PHP 7.4: поддержка закончилась на php.net, но исправления безопасности переносит репозиторий пакетов (последний раз 17.11.2026, уязвимостей: 12)"* ]]
	[[ "$output" != *"warn|"* ]]
}

@test "новая сборка с исправлениями безопасности: предупреждение" {
	php_setup
	INST="1:7.4.33-35+debsuryorg12.1+1"
	cp "$CL" "$SECREL_CACHE/php7.4-common_1_7.4.33-38+debsuryorg12.1+1.changelog"
	run _secrel_php
	[[ "$output" == *"warn|PHP 7.4.33: в репозитории новая сборка с исправлениями безопасности (12), luckyctl update pkgs"* ]]
}

@test "старая ветка без перенесённых исправлений: как раньше, перейти на новую" {
	php_setup
	CAND="$INST"
	printf 'php7.4 (1:7.4.33-1) unstable; urgency=medium\n\n  * Build\n\n -- A <a@b>  Mon, 07 Nov 2022 10:00:00 +0100\n' >"$SECREL_DOC_DIR/php7.4-common/changelog.Debian.gz"
	run _secrel_php
	[[ "$output" == *"warn|PHP 7.4: поддержка закончилась, исправлений от php.net нет"* ]]
}
