#!/usr/bin/env bats
# Apache: наши файлы настроек кладутся с проверкой configtest и откатом, сайт по умолчанию
# собирается по HTTP_IP_POLICY, mpm_event считается по памяти.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	T="${BATS_TEST_TMPDIR}"
	export APACHE_ETC="$T/apache2"
	mkdir -p "$APACHE_ETC"/{conf,sites,mods}-{available,enabled}
	touch "$APACHE_ETC/mods-available/brotli.load"
	load_libs apache
	CALLS="$T/calls"; : >"$CALLS"
	# заглушки: a2en*/a2dis* ставят и снимают ссылку, configtest падает, если в настройках есть BROKEN
	a2enconf()  { [[ "$1" == -q ]] && shift; ln -sf "../conf-available/$1.conf" "$APACHE_ETC/conf-enabled/$1.conf"; }
	a2disconf() { [[ "$1" == -q ]] && shift; rm -f "$APACHE_ETC/conf-enabled/$1.conf"; }
	a2ensite()  { [[ "$1" == -q ]] && shift; ln -sf "../sites-available/$1.conf" "$APACHE_ETC/sites-enabled/$1.conf"; }
	a2dissite() { [[ "$1" == -q ]] && shift; rm -f "$APACHE_ETC/sites-enabled/$1.conf"; }
	# модули: включение = ссылка в mods-enabled (WAF смотрит на неё)
	a2enmod()   { local m; for m in "$@"; do [[ "$m" == -q ]] || ln -sf "../mods-available/$m.load" "$APACHE_ETC/mods-enabled/$m.load"; done; }
	a2dismod()  { local m; for m in "$@"; do [[ "$m" == -q ]] || rm -f "$APACHE_ETC/mods-enabled/$m.load"; done; }
	apt_install() { echo "apt $*" >>"$CALLS"; }
	make-ssl-cert() { :; }
	export MODSEC_DIR="$T/modsecurity"; mkdir -p "$MODSEC_DIR"
	echo "SecRuleEngine DetectionOnly" >"$MODSEC_DIR/modsecurity.conf-recommended"
	touch "$APACHE_ETC/mods-available/security2.load"
	apache2ctl() { ! grep -Rqs BROKEN "$APACHE_ETC"/conf-enabled/ "$APACHE_ETC"/sites-enabled/; }
	systemctl() { echo "systemctl $*" >>"$CALLS"; }
}

@test "новый файл кладётся, включается, Apache перечитывает настройки" {
	echo "Timeout 60" >"$T/new"
	_apache_put_conf zz-test "$T/new"
	[ "$(cat "$APACHE_ETC/conf-available/zz-test.conf")" = "Timeout 60" ]
	[ -L "$APACHE_ETC/conf-enabled/zz-test.conf" ]
	grep -qx "systemctl reload apache2" "$CALLS"
	[ ! -e "$T/new" ]
}

@test "configtest не прошёл: прежний файл возвращается" {
	echo "Timeout 60" >"$T/a"; _apache_put_conf zz-test "$T/a"
	: >"$CALLS"
	echo "BROKEN" >"$T/b"
	run _apache_put_conf zz-test "$T/b"
	[ "$status" -eq 1 ]
	[ "$(cat "$APACHE_ETC/conf-available/zz-test.conf")" = "Timeout 60" ]
	[ -L "$APACHE_ETC/conf-enabled/zz-test.conf" ]
	! grep -q reload "$CALLS"
}

@test "configtest не прошёл для нового файла: файла нет, он не включён" {
	echo "BROKEN" >"$T/b"
	run _apache_put_conf zz-new "$T/b"
	[ "$status" -eq 1 ]
	[ ! -e "$APACHE_ETC/conf-available/zz-new.conf" ]
	[ ! -e "$APACHE_ETC/conf-enabled/zz-new.conf" ]
}

@test "без изменений Apache не трогается" {
	echo "Timeout 60" >"$T/a"; _apache_put_conf zz-test "$T/a"
	: >"$CALLS"
	echo "Timeout 60" >"$T/a"; _apache_put_conf zz-test "$T/a"
	[ ! -s "$CALLS" ]
}

@test "restart вместо reload для mpm (ServerLimit)" {
	_apache_mpm_tune 4096
	grep -qx "systemctl restart apache2" "$CALLS"
	grep -q "MaxRequestWorkers 400" "$APACHE_ETC/conf-available/zz-luckystack-mpm.conf"
	grep -q "ServerLimit 16" "$APACHE_ETC/conf-available/zz-luckystack-mpm.conf"
}

@test "mpm по памяти: 1 ГБ — 150, 8 ГБ — 600 (ServerLimit 24)" {
	_apache_mpm_tune 1024
	grep -q "MaxRequestWorkers 150" "$APACHE_ETC/conf-available/zz-luckystack-mpm.conf"
	_apache_mpm_tune 16000
	grep -q "MaxRequestWorkers 600" "$APACHE_ETC/conf-available/zz-luckystack-mpm.conf"
	grep -q "ServerLimit 24" "$APACHE_ETC/conf-available/zz-luckystack-mpm.conf"
}

@test "усиление: базовое всегда, заголовки и секреты только с HARDEN_CONF_CUSTOM=y" {
	HARDEN_CONF_CUSTOM=n _apache_hardening
	f="$APACHE_ETC/conf-available/zz-luckystack-hardening.conf"
	grep -qx "ServerTokens Prod" "$f"
	grep -qx "TraceEnable Off" "$f"
	! grep -q "X-Frame-Options" "$f"
	HARDEN_CONF_CUSTOM=y HARDEN_HSTS=y _apache_hardening
	# только если ответ (PHP, vhost) ещё не несёт такой заголовок, иначе дубль
	grep -q "Header set X-Frame-Options \"SAMEORIGIN\" \"expr=-z resp('X-Frame-Options')\"" "$f"
	! grep -q setifempty "$f"
	grep -q "expr=%{HTTPS} == 'on' && -z resp('Strict-Transport-Security')" "$f"
	grep -q 'sql' "$f"
}

@test "таймауты выключаются настройкой" {
	_apache_timeouts
	[ -f "$APACHE_ETC/conf-available/zz-luckystack-timeouts.conf" ]
	NGX_TIGHT_TIMEOUTS=n _apache_timeouts
	[ ! -e "$APACHE_ETC/conf-available/zz-luckystack-timeouts.conf" ]
	[ ! -e "$APACHE_ETC/conf-enabled/zz-luckystack-timeouts.conf" ]
}

@test "сайт по умолчанию: landing отдаёт /var/www/html, на 443 отказ, 000-default выключен" {
	ln -s ../sites-available/000-default.conf "$APACHE_ETC/sites-enabled/000-default.conf"
	HTTP_IP_POLICY=landing SERVER_FQDN=srv.example.org _apache_default_vhost
	f="$APACHE_ETC/sites-available/00-luckystack-default.conf"
	grep -q "DocumentRoot /var/www/html" "$f"
	grep -q 'acme-challenge/ - \[L\]' "$f"
	[ "$(grep -c 'RewriteRule ^ - \[F\]' "$f")" = 1 ]   # только на 443
	# своё имя, иначе vhost берёт глобальный ServerName (FQDN) и перехватывает сайт хоста
	[ "$(grep -c 'ServerName luckystack-default.invalid' "$f")" = 2 ]
	! grep -q "R=301" "$f"
	[ ! -e "$APACHE_ETC/sites-enabled/000-default.conf" ]
}

@test "сайт по умолчанию: deny — 403 и на 80, redirect — 301 на FQDN" {
	HTTP_IP_POLICY=deny SERVER_FQDN=srv.example.org _apache_default_vhost
	f="$APACHE_ETC/sites-available/00-luckystack-default.conf"
	[ "$(grep -c 'RewriteRule ^ - \[F\]' "$f")" = 2 ]
	HTTP_IP_POLICY=redirect SERVER_FQDN=srv.example.org _apache_default_vhost
	grep -q 'RewriteRule ^/(.\*)\$ https://srv.example.org/\$1 \[R=301,L\]' "$f"
}

@test "redirect без настоящего FQDN превращается в landing" {
	HTTP_IP_POLICY=redirect SERVER_FQDN=localhost _apache_default_vhost
	f="$APACHE_ETC/sites-available/00-luckystack-default.conf"
	! grep -q "R=301" "$f"
	grep -q "HTTP_IP_POLICY=landing" "$f"
}

@test "есть сайт хоста по FQDN: http://FQDN уходит на https при любой политике" {
	touch "$APACHE_ETC/sites-enabled/luckystack-host-fqdn.conf"
	HTTP_IP_POLICY=landing SERVER_FQDN=srv.example.org _apache_default_vhost
	f="$APACHE_ETC/sites-available/00-luckystack-default.conf"
	grep -q 'RewriteCond %{HTTP_HOST} ^srv\\.example\\.org(:80)?\$ \[NC\]' "$f"
	grep -q 'https://srv.example.org/\$1 \[R=301,L\]' "$f"
}

@test "WAF: наблюдение по умолчанию, исключены порты панели и служебные пути" {
	ISPCONFIG_PANEL_PORT=8443 _apache_waf
	f="$MODSEC_DIR/zz-luckystack.conf"
	grep -qx "SecRuleEngine DetectionOnly" "$f"
	grep -q '^SecRule SERVER_PORT "@rx ^(8443|8081)\$"' "$f"
	grep -q 'phpmyadmin|roundcube' "$f"
	grep -qx "SecRequestBodyLimitAction ProcessPartial" "$f"
	[ -f "$MODSEC_DIR/modsecurity.conf" ]
	[ -L "$APACHE_ETC/mods-enabled/security2.load" ]
}

@test "WAF: блокировка включает SecRuleEngine On, off выключает модуль" {
	APACHE_WAF=block _apache_waf
	grep -qx "SecRuleEngine On" "$MODSEC_DIR/zz-luckystack.conf"
	APACHE_WAF=off _apache_waf
	[ ! -e "$APACHE_ETC/mods-enabled/security2.load" ]
}

@test "WAF: непонятный режим превращается в наблюдение" {
	APACHE_WAF=strict _apache_waf
	grep -qx "SecRuleEngine DetectionOnly" "$MODSEC_DIR/zz-luckystack.conf"
}

@test "brotli: клиентам с br выключается gzip (deflate.conf пакета стоит в цепочке раньше)" {
	_apache_compress
	f="$APACHE_ETC/conf-available/zz-luckystack-compress.conf"
	grep -q 'SetEnvIfNoCase Accept-Encoding .* no-gzip' "$f"
	grep -q 'BROTLI_COMPRESS;DEFLATE text/html' "$f"
}

@test "WAF и CrowdSec: бан по сообщениям WAF только в режиме блокировки" {
	export WEBSERVER=apache CROWDSEC_ETC="$T/crowdsec"; mkdir -p "$CROWDSEC_ETC/collections"
	cscli() { echo "cscli $*" >>"$CALLS"; }
	# наблюдение: коллекцию, поставленную пакетом CrowdSec, убираем
	touch "$CROWDSEC_ETC/collections/modsecurity.yaml"
	_apache_waf_crowdsec detect
	grep -q "cscli collections remove crowdsecurity/modsecurity" "$CALLS"
	# блокировка: ставим, если нет
	rm -f "$CROWDSEC_ETC/collections/modsecurity.yaml"; : >"$CALLS"
	_apache_waf_crowdsec block
	grep -q "cscli collections install crowdsecurity/modsecurity" "$CALLS"
	# nginx не трогаем
	: >"$CALLS"; WEBSERVER=nginx _apache_waf_crowdsec detect
	! grep -q cscli "$CALLS"
}
