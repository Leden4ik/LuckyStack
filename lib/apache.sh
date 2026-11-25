#!/bin/bash
# =============================================================================
# lib/apache.sh — Apache (вариант статьи Perfect Server) и наши настройки поверх него.
# apache2 + suExec + FCGID + mpm_event + проксирование в PHP-FPM.
# PHP-FPM ставится отдельным этапом (lib/php.sh) — одинаков для nginx и Apache.
#
# Apache берётся из пакетов: из дистрибутива или свежий от Sury (APACHE_SOURCE). Собирать
# его незачем: HTTP/2, TLS 1.3 и brotli есть в пакетах, а ISPConfig рассчитан на пакетный Apache.
#
# Наши настройки лежат отдельными файлами, конфиги пакета не правим (иначе обновления
# Debian спрашивали бы про изменённые файлы, а unattended-upgrades такие пакеты пропускает):
#   conf-available/zz-luckystack-hardening.conf  скрыть версию, TRACE, заголовки, закрыть секреты
#   conf-available/zz-luckystack-timeouts.conf   таймауты клиентов (NGX_TIGHT_TIMEOUTS)
#   conf-available/zz-luckystack-compress.conf   brotli
#   conf-available/zz-luckystack-mpm.conf        mpm_event по объёму памяти (этап tuning)
#   sites-available/00-luckystack-default.conf   запросы по IP и чужим именам (HTTP_IP_POLICY)
# Префикс zz-: conf-enabled читается по алфавиту, наш файл идёт после security.conf пакета и
# перекрывает его ServerTokens/ServerSignature. Префикс 00-: сайт по умолчанию должен быть первым.
# Каждый файл проходит apache2ctl configtest, не прошёл — возвращается прежний.
# =============================================================================

APACHE_DEFAULT_SITE=00-luckystack-default
: "${APACHE_ETC:=/etc/apache2}"   # каталог настроек Apache (тесты подменяют)

stage_apache() {
	_apache_repo || return 1
	ui_step "Установка Apache + suExec + FCGID"
	# БЕЗ libapache2-mod-php: используем PHP-FPM (mod_proxy_fcgi), как и ISPConfig.
	# mod_php несовместим с mpm_event и тянет лишнюю «системную» версию PHP.
	# Обработчик .php для дефолтной версии включает php-этап (a2enconf phpX.Y-fpm).
	# ssl-cert: самоподписанный сертификат для сайта по умолчанию на 443, пока нет своего.
	apt_install apache2 apache2-utils libapache2-mod-fcgid apache2-suexec-pristine ssl-cert

	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} a2enmod (suexec rewrite ssl actions include dav headers proxy_fcgi setenvif http2 brotli reqtimeout mpm_event)"
		ui_info "${UI_D}[dry-run]${UI_NC} усиление, таймауты, brotli, сайт по умолчанию (${HTTP_IP_POLICY:-landing})"
		ui_info "${UI_D}[dry-run]${UI_NC} systemctl enable --now apache2"
		ui_success "Apache (имитация) установлен."
		return 0
	fi

	ui_step "Включение модулей Apache"
	ui_spin "a2enmod (suexec, rewrite, ssl, actions, fcgid, dav, headers, proxy_fcgi, http2)" \
		a2enmod suexec rewrite ssl actions include dav_fs dav auth_digest headers \
			proxy_fcgi setenvif http2 || ui_warn "Часть модулей не включилась."

	# MPM event лучше для FPM-проксирования: отключаем prefork, включаем event
	a2dismod php8.* mpm_prefork >/dev/null 2>&1 || true
	a2enmod mpm_event >/dev/null 2>&1 || true

	sys_run "Перезапуск Apache" systemctl restart apache2
	sys_run "Автозагрузка Apache" systemctl enable apache2
	_apache_apply_all
	ui_success "Apache установлен и настроен ($(_apache_version))."
	return 0
}

stage_apache_summary() {
	echo "Apache: $(_apache_version) из ${APACHE_SOURCE:-distro}, FPM через mod_proxy_fcgi, по IP: ${HTTP_IP_POLICY:-landing}"
}

# Версия установленного Apache (2.4.62) или «не установлен».
_apache_version() {
	local v; v="$(apache2 -v 2>/dev/null | grep -oE 'Apache/[0-9.]+' | cut -d/ -f2)"
	echo "${v:-не установлен}"
}

# --- Источник пакетов ----------------------------------------------------------
# APACHE_SOURCE=distro (по умолчанию) — Apache из дистрибутива, обновления безопасности от Debian/Ubuntu.
# APACHE_SOURCE=sury — свежая ветка 2.4 от Ondřej Surý (packages.sury.org/apache2, на Ubuntu ppa:ondrej/apache2).
# Переход обратно на distro убирает репозиторий; уже стоящий Apache от Sury остаётся до переустановки.
_apache_repo() {
	local list=/etc/apt/sources.list.d/apache2-sury.list
	if [[ "${APACHE_SOURCE:-distro}" != "sury" ]]; then
		if [[ -f "$list" && "${DRY_RUN:-0}" != "1" ]]; then
			rm -f "$list"
			ui_info "Репозиторий Apache от Sury отключён (APACHE_SOURCE=distro). Установленная версия останется до переустановки пакета."
			apt_update
		fi
		return 0
	fi
	ui_step "Подключение репозитория Apache (Ondřej Surý)"
	if [[ "${DRY_RUN:-0}" == "1" ]]; then
		ui_info "${UI_D}[dry-run]${UI_NC} packages.sury.org/apache2 (Debian) или ppa:ondrej/apache2 (Ubuntu)"
		return 0
	fi
	apt_install lsb-release ca-certificates apt-transport-https gnupg2 curl
	if [[ "${OS_ID:-debian}" == "ubuntu" ]]; then
		apt_install software-properties-common
		if grep -rqs "ondrej/apache2" /etc/apt/sources.list.d/ 2>/dev/null; then
			ui_info "PPA ppa:ondrej/apache2 уже подключён."
		elif ! ui_spin "Добавление PPA ppa:ondrej/apache2" env DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:ondrej/apache2; then
			ui_error "Не удалось добавить ppa:ondrej/apache2."
			return 1
		fi
		apt_update
		return 0
	fi
	local key=/etc/apt/trusted.gpg.d/apache2-sury.gpg codename
	if ! _php_sury_key_ok "$key"; then
		local tmp; tmp="$(mktemp)" || return 1
		if ui_spin "Загрузка GPG-ключа Sury" curl -fsSL --retry 3 --retry-delay 5 --max-time 60 \
				-o "$tmp" https://packages.sury.org/apache2/apt.gpg && _php_sury_key_ok "$tmp"; then
			install -m 644 -o root -g root "$tmp" "$key"
			rm -f "$tmp"
		else
			rm -f "$tmp"
			ui_error "Не удалось скачать ключ репозитория Apache (https://packages.sury.org/apache2/apt.gpg)."
			return 1
		fi
	fi
	codename="$(os_codename)"
	[[ -n "$codename" ]] || { ui_error "Не удалось определить кодовое имя релиза, репозиторий Apache не добавлен."; return 1; }
	echo "deb https://packages.sury.org/apache2/ ${codename} main" >"$list"
	apt_update
}

# --- Общий помощник ------------------------------------------------------------
# _apache_put_conf ИМЯ ФАЙЛ [conf|site] [restart] — положить ФАЙЛ как conf-available/ИМЯ.conf
# (или sites-available), включить и проверить configtest. Не прошло — вернуть прежний файл.
# restart: перезапуск вместо reload (ServerLimit меняется только так). Код 0 — применено
# или уже так, 1 — configtest не прошёл. ФАЙЛ удаляется в любом случае.
_apache_put_conf() {
	local name="$1" src="$2" kind="${3:-conf}" how="${4:-reload}" dir en dis f prev="" was_on=0
	case "$kind" in
		site) dir=${APACHE_ETC}/sites-available; en=a2ensite; dis=a2dissite ;;
		*)    dir=${APACHE_ETC}/conf-available;  en=a2enconf; dis=a2disconf ;;
	esac
	f="$dir/$name.conf"
	local link="${dir%-available}-enabled/$name.conf"
	if [[ -f "$f" && -e "$link" ]] && cmp -s "$src" "$f"; then rm -f "$src"; return 0; fi
	[[ -f "$f" ]] && { prev="$(mktemp)"; cp -a "$f" "$prev"; }
	[[ -e "$link" ]] && was_on=1
	install -m 644 "$src" "$f"; rm -f "$src"
	"$en" -q "$name" >>"$SETUP_LOG" 2>&1
	if apache2ctl configtest >>"$SETUP_LOG" 2>&1; then
		rm -f "$prev"
		systemctl "$how" apache2 >>"$SETUP_LOG" 2>&1 || true
		return 0
	fi
	if [[ -n "$prev" ]]; then mv -f "$prev" "$f"; else rm -f "$f"; fi
	((was_on)) || "$dis" -q "$name" >>"$SETUP_LOG" 2>&1
	return 1
}

# _apache_drop_conf ИМЯ — выключить и удалить наш conf (настройку выключили).
_apache_drop_conf() {
	[[ -f "${APACHE_ETC}/conf-available/$1.conf" ]] || return 0
	a2disconf -q "$1" >>"$SETUP_LOG" 2>&1
	rm -f "${APACHE_ETC}/conf-available/$1.conf"
	apache2ctl configtest >>"$SETUP_LOG" 2>&1 && systemctl reload apache2 >>"$SETUP_LOG" 2>&1
	return 0
}

# Всё, что относится к самому Apache: при установке и в luckyctl update.
_apache_apply_all() {
	command -v apache2ctl >/dev/null 2>&1 || return 0
	_apache_hardening
	_apache_timeouts
	_apache_compress
	_apache_default_vhost
	return 0
}

# --- Усиление ------------------------------------------------------------------
# Всегда: скрыть версию, выключить TRACE, закрыть скрытые файлы и каталоги (кроме .well-known).
# HARDEN_CONF_CUSTOM=y (как у nginx): заголовки безопасности и запрет секретных файлов и дампов.
# HARDEN_HSTS=y: HSTS на https-ответах. Заголовки ставятся через setifempty: если сайт (PHP)
# уже отдал свой, второй не добавляется (у nginx для этого понадобилась отдельная защита от дублей).
_apache_hardening() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} Apache: усиление (zz-luckystack-hardening.conf)"; return 0; }
	command -v apache2ctl >/dev/null 2>&1 || return 0
	a2enmod -q headers rewrite >>"$SETUP_LOG" 2>&1
	local t; t="$(mktemp)"
	{
		echo "# luckystack: усиление Apache. Файл пересоздаётся при luckyctl update, свои правки держите в другом файле."
		echo "ServerTokens Prod"
		echo "ServerSignature Off"
		echo "TraceEnable Off"
		echo ""
		echo "# скрытые файлы и каталоги (.env, .git и т.п.), кроме .well-known (ACME)"
		echo '<FilesMatch "^\.">'
		echo "    Require all denied"
		echo "</FilesMatch>"
		echo '<DirectoryMatch "/\.(?!well-known)">'
		echo "    Require all denied"
		echo "</DirectoryMatch>"
		if [[ "${HARDEN_CONF_CUSTOM:-n}" == "y" ]]; then
			echo ""
			echo "# секретные файлы и дампы (как deny-secrets у nginx)"
			echo '<FilesMatch "(?i)(^(composer\.(json|lock)|package(-lock)?\.json|Dockerfile|yarn\.lock)|\.(bak|old|sql|sql\.gz|ini|sh|log))$">'
			echo "    Require all denied"
			echo "</FilesMatch>"
			echo ""
			echo "<IfModule mod_headers.c>"
			echo '    Header setifempty X-Content-Type-Options "nosniff"'
			echo '    Header setifempty X-Frame-Options "SAMEORIGIN"'
			echo '    Header setifempty Referrer-Policy "strict-origin-when-cross-origin"'
			[[ "${HARDEN_HSTS:-n}" == "y" ]] && \
				echo '    Header setifempty Strict-Transport-Security "max-age=15552000; includeSubDomains" "expr=%{HTTPS} == '"'on'"'"'
			echo "</IfModule>"
		fi
	} >"$t"
	if _apache_put_conf zz-luckystack-hardening "$t"; then
		if [[ "${HARDEN_CONF_CUSTOM:-n}" == "y" ]]; then
			ui_success "Apache: усиление применено (с заголовками безопасности и запретом секретных файлов)."
		else
			ui_success "Apache: усиление применено (версия скрыта, TRACE выключен, скрытые файлы закрыты)."
		fi
	else
		ui_warn "Apache: configtest не принял усиление, оставил прежнее (${SETUP_LOG})."
		return 1
	fi
}

# --- Таймауты ------------------------------------------------------------------
# Медленные атаки держат соединения открытыми; по умолчанию Apache ждёт 300 с на шаг.
# Клиентам — коротко, а PHP-FPM (ProxyTimeout) оставляем 300 с, как было: Timeout задаёт и время
# ожидания ответа скрипта, и долгий импорт в phpMyAdmin не должен обрываться.
_apache_timeouts() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} Apache: таймауты клиентов"; return 0; }
	command -v apache2ctl >/dev/null 2>&1 || return 0
	if [[ "${NGX_TIGHT_TIMEOUTS:-y}" != "y" ]]; then
		_apache_drop_conf zz-luckystack-timeouts
		return 0
	fi
	a2enmod -q reqtimeout >>"$SETUP_LOG" 2>&1
	local t; t="$(mktemp)"
	cat >"$t" <<'CONF'
# luckystack: таймауты клиентов (NGX_TIGHT_TIMEOUTS=n в setup.conf убирает этот файл)
Timeout 60
KeepAliveTimeout 5
<IfModule mod_proxy.c>
    # ответ PHP-FPM ждём, как раньше ждали по умолчанию
    ProxyTimeout 300
</IfModule>
<IfModule reqtimeout_module>
    RequestReadTimeout handshake=5 header=15-40,MinRate=500 body=60,MinRate=500
</IfModule>
CONF
	if _apache_put_conf zz-luckystack-timeouts "$t"; then
		ui_success "Apache: короткие таймауты клиентов."
	else
		ui_warn "Apache: configtest не принял таймауты, оставил прежние."
		return 1
	fi
}

# --- Сжатие --------------------------------------------------------------------
# brotli для текстовых ответов, gzip (mod_deflate из пакета) остаётся для клиентов без brotli.
_apache_compress() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} Apache: brotli"; return 0; }
	command -v apache2ctl >/dev/null 2>&1 || return 0
	[[ -f ${APACHE_ETC}/mods-available/brotli.load ]] || { ui_info "Apache: модуля brotli нет в этой сборке, остаётся gzip."; return 0; }
	a2enmod -q brotli deflate filter >>"$SETUP_LOG" 2>&1
	local t; t="$(mktemp)"
	cat >"$t" <<'CONF'
# luckystack: brotli для текстовых ответов. Клиентам без brotli отвечает mod_deflate (gzip).
<IfModule mod_brotli.c>
    BrotliCompressionQuality 5
    AddOutputFilterByType BROTLI_COMPRESS;DEFLATE text/html text/plain text/xml text/css text/javascript application/javascript application/json application/xml application/rss+xml application/manifest+json image/svg+xml font/ttf font/otf
</IfModule>
CONF
	if _apache_put_conf zz-luckystack-compress "$t"; then
		ui_success "Apache: сжатие brotli включено."
	else
		ui_warn "Apache: configtest не принял настройки brotli."
		return 1
	fi
}

# --- Сайт по умолчанию -----------------------------------------------------------
# Что отдавать по IP и чужому имени (HTTP_IP_POLICY, как у nginx):
#   landing  — /var/www/html (стартовая, /roundcube и /phpmyadmin по IP) [по умолчанию]
#   redirect — 301 на https://SERVER_FQDN
#   deny     — 403 (рвать соединение, как nginx 444, Apache не умеет)
# Всегда: /.well-known/acme-challenge/ доступен (выпуск сертификатов), а если есть сайт хоста
# по FQDN на 443, http://FQDN переадресуется на https.
# На 443 чужое имя получает 403 с сертификатом сервера. Без этого Apache отдавал первый сайт
# из списка, и по его сертификату было видно, какие сайты живут на сервере.
# Стандартный 000-default пакета выключается (файл остаётся).
_apache_default_vhost() {
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} Apache: сайт по умолчанию (${HTTP_IP_POLICY:-landing})"; return 0; }
	command -v apache2ctl >/dev/null 2>&1 || return 0
	a2enmod -q rewrite ssl >>"$SETUP_LOG" 2>&1
	local pol="${HTTP_IP_POLICY:-landing}" fqdn="${SERVER_FQDN:-}" crt key t rules=""
	if [[ "$pol" == redirect && "$fqdn" != *.* ]]; then
		ui_warn "HTTP_IP_POLICY=redirect без публичного SERVER_FQDN, оставляю стартовую страницу по IP."
		pol=landing
	fi
	crt="${ISPC_SSL_DIR:-/usr/local/ispconfig/interface/ssl}/ispserver.crt"; key="${crt%.crt}.key"
	if [[ ! -s "$crt" || ! -s "$key" ]]; then
		crt=/etc/ssl/certs/ssl-cert-snakeoil.pem; key=/etc/ssl/private/ssl-cert-snakeoil.key
		[[ -s "$crt" ]] || make-ssl-cert generate-default-snakeoil >>"$SETUP_LOG" 2>&1
	fi
	if [[ "$fqdn" == *.* && -e ${APACHE_ETC}/sites-enabled/luckystack-host-fqdn.conf ]]; then
		rules+="    RewriteCond %{HTTP_HOST} ^${fqdn//./\\.}(:80)?\$ [NC]"$'\n'
		rules+="    RewriteRule ^/(.*)\$ https://${fqdn}/\$1 [R=301,L]"$'\n'
	fi
	case "$pol" in
		redirect) rules+="    RewriteRule ^/(.*)\$ https://${fqdn}/\$1 [R=301,L]"$'\n' ;;
		deny)     rules+="    RewriteRule ^ - [F]"$'\n' ;;
	esac
	t="$(mktemp)"
	cat >"$t" <<APA
# luckystack: запросы по IP и чужим именам (HTTP_IP_POLICY=${pol}). Пересоздаётся при luckyctl update.
<VirtualHost *:80>
    DocumentRoot /var/www/html
    <Directory /var/www/html>
        Options -Indexes +FollowSymLinks
        AllowOverride None
        Require all granted
    </Directory>
    RewriteEngine On
    RewriteRule ^/\.well-known/acme-challenge/ - [L]
${rules}</VirtualHost>
<VirtualHost *:443>
    SSLEngine on
    SSLCertificateFile ${crt}
    SSLCertificateKeyFile ${key}
    RewriteEngine On
    RewriteRule ^ - [F]
</VirtualHost>
APA
	if _apache_put_conf "$APACHE_DEFAULT_SITE" "$t" site; then
		if [[ -e ${APACHE_ETC}/sites-enabled/000-default.conf ]]; then
			a2dissite -q 000-default >>"$SETUP_LOG" 2>&1
			apache2ctl configtest >>"$SETUP_LOG" 2>&1 && systemctl reload apache2 >>"$SETUP_LOG" 2>&1
		fi
		ui_success "Apache: сайт по умолчанию (по IP: ${pol}, на 443 чужое имя получает отказ)."
	else
		ui_warn "Apache: configtest не принял сайт по умолчанию, оставил как было."
		return 1
	fi
}

# --- mpm_event по памяти (этап tuning) -------------------------------------------
# PHP работает в PHP-FPM, поток Apache лёгкий: потоков можно больше, чем по умолчанию (150).
# ServerLimit меняется только перезапуском, поэтому restart (и только когда значения изменились).
_apache_mpm_tune() {
	local ram="${1:-1024}" mrw=150 tpc=25 sl
	command -v apache2ctl >/dev/null 2>&1 || return 0
	((ram >= 2048)) && mrw=250
	((ram >= 4096)) && mrw=400
	((ram >= 8192)) && mrw=600
	sl=$(( (mrw + tpc - 1) / tpc ))
	[[ "${DRY_RUN:-0}" == "1" ]] && { ui_info "${UI_D}[dry-run]${UI_NC} Apache mpm_event: MaxRequestWorkers ${mrw}"; return 0; }
	local t; t="$(mktemp)"
	cat >"$t" <<CONF
# luckystack: mpm_event по объёму памяти (${ram} МБ). Пересчитывается этапом tuning.
<IfModule mpm_event_module>
    StartServers 2
    ServerLimit ${sl}
    ThreadsPerChild ${tpc}
    MaxRequestWorkers ${mrw}
    MinSpareThreads 25
    MaxSpareThreads 75
    MaxConnectionsPerChild 10000
</IfModule>
CONF
	if _apache_put_conf zz-luckystack-mpm "$t" conf restart; then
		ui_success "Apache mpm_event: MaxRequestWorkers ${mrw} (RAM ${ram} МБ)."
	else
		ui_warn "Apache: configtest не принял настройки mpm_event."
		return 1
	fi
}
