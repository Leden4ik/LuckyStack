#!/usr/bin/env bats
# Метапакеты php-* закрепляются на своей ветке PHP, чтобы apt full-upgrade не принёс новую.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs php
	PHP_META_PIN="${BATS_TEST_TMPDIR}/pin"
	PKGS=$'php-mysql 2:8.4+101+debsuryorg12.1+php+1 installed\nphp-common 2:101+debsuryorg12.1+php+1 installed\nphp-gd 2:8.4+101+debsuryorg12.1+php+1 config-files'
	dpkg-query() {
		case "$*" in
			*'${Depends}'*php-mysql*) echo "php8.4-mysql" ;;
			*'${Depends}'*php-common*) echo "psmisc" ;;
			*'${Depends}'*php-gd*) echo "php8.4-gd" ;;
			*) echo "$PKGS" ;;
		esac
	}
}

@test "php-mysql закрепляется на 8.4, php-common и неустановленные не трогаются" {
	_php_pin_meta
	grep -qx 'Package: php-mysql' "$PHP_META_PIN"
	grep -qx 'Pin: version 2:8.4+\*' "$PHP_META_PIN"
	grep -qx 'Pin-Priority: 1001' "$PHP_META_PIN"
	! grep -q 'php-common\|php-gd' "$PHP_META_PIN"
}

@test "повторный запуск файл не переписывает" {
	_php_pin_meta
	touch -d '-1 hour' "$PHP_META_PIN"; before="$(stat -c %Y "$PHP_META_PIN")"
	_php_pin_meta
	[ "$(stat -c %Y "$PHP_META_PIN")" = "$before" ]
}

@test "метапакетов нет: файл закрепления убирается" {
	_php_pin_meta
	PKGS=$'php-common 2:101+debsuryorg12.1+php+1 installed'
	_php_pin_meta
	[ ! -e "$PHP_META_PIN" ]
}
