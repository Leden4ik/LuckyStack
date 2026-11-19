#!/usr/bin/env bash
# =============================================================================
# secrel.sh — вышли ли исправления безопасности для того, что стоит на сервере:
#   nginx (наша сборка) — по официальному списку уязвимостей nginx.org;
#   OpenSSL внутри сборки nginx — последний выпуск той же ветки на GitHub;
#   PHP — обновление в репозитории пакетов, выпуск на php.net, конец поддержки ветки.
# Сеть спрашиваем не чаще раза в сутки (кэш), без сети проверка просто пропускается.
#
# secrel_scan печатает строки «уровень|текст»: ok, warn, info. Их показывает
# luckyctl check (раздел «Исправления безопасности»), а ежедневный монитор шлёт warn
# уведомлением: luckyctl cve --plain.
# =============================================================================

SECREL_TTL_MIN="${SECREL_TTL_MIN:-1380}"
SECREL_NGINX_URL="${SECREL_NGINX_URL:-https://nginx.org/en/security_advisories.html}"
SECREL_PHP_URL="${SECREL_PHP_URL:-https://www.php.net/releases/active.php}"
SECREL_OPENSSL_URL="${SECREL_OPENSSL_URL:-https://api.github.com/repos/openssl/openssl/releases?per_page=60}"

_secrel_cache_dir() {
	local d="${LS_VAR_DIR:-/var/lib/luckystack}/secrel"
	mkdir -p "$d" 2>/dev/null && [[ -w "$d" ]] && { echo "$d"; return; }
	d="${TMPDIR:-/tmp}/luckystack-secrel-${EUID}"
	mkdir -m 700 "$d" 2>/dev/null
	[[ -d "$d" && -O "$d" ]] && echo "$d"   # чужой каталог с тем же именем не берём
}

# _secrel_fetch имя url → путь к файлу в кэше (свежее суток) или ничего
_secrel_fetch() {
	local dir f
	dir="${SECREL_CACHE:-$(_secrel_cache_dir)}" || return 1
	[[ -n "$dir" ]] || return 1
	f="$dir/$1"
	if [[ -z "$(find "$f" -mmin -"$SECREL_TTL_MIN" 2>/dev/null)" ]]; then
		curl -fsSL --connect-timeout 10 --max-time 25 "$2" -o "$f.tmp" 2>/dev/null && [[ -s "$f.tmp" ]] && mv -f "$f.tmp" "$f"
		rm -f "$f.tmp"
	fi
	[[ -s "$f" ]] && echo "$f"
}

# a >= b для версий из чисел через точку (без внешних команд: на странице nginx.org под
# сотню записей, и sort на каждое сравнение заметно тормозит); остальное — через sort -V
_secrel_ge() {
	local -a a b
	local i x y
	IFS=. read -ra a <<<"$1"
	IFS=. read -ra b <<<"$2"
	for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
		x="${a[i]:-0}"; y="${b[i]:-0}"
		if [[ ! "$x" =~ ^[0-9]+$ || ! "$y" =~ ^[0-9]+$ ]]; then
			[[ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" == "$2" ]]
			return
		fi
		((10#$x > 10#$y)) && return 0
		((10#$x < 10#$y)) && return 1
	done
	return 0
}
_secrel_mm() { echo "${1%.*}"; }   # 1.30.6 → 1.30

# Список уязвимостей nginx.org в строки «название|серьёзность|CVE|не уязвимы|уязвимы»
_secrel_nginx_parse() {
	sed -n 's:.*<li><p>\(.*\)</p></li>.*:\1:p' "$1" \
		| sed -E 's:</?b>::g; s:<a [^>]*>::g; s:</a>::g; s:<br>:\t:g' \
		| awk -F'\t' '{
			t = $1; sev = ""; cve = ""; nv = ""; vu = ""
			for (i = 2; i <= NF; i++) {
				if ($i ~ /^Severity: /)       { sev = substr($i, 11) }
				else if ($i ~ /^Not vulnerable: /) { nv = substr($i, 17) }
				else if ($i ~ /^Vulnerable: /)     { vu = substr($i, 13) }
				else if (match($i, /CVE-[0-9]+-[0-9]+/) && cve == "") { cve = substr($i, RSTART, RLENGTH) }
			}
			if (vu != "") print t "|" sev "|" cve "|" nv "|" vu
		}'
}

# _secrel_nginx_affects версия "не уязвимы" "уязвимы" → 0, если версия уязвима.
# «Уязвимы: 1.9.5-1.31.8» перекрывает и исправленные ветки, поэтому сначала смотрим
# «Не уязвимы: 1.31.9+, 1.30.7+»: та же ветка и не ниже, или не ниже самой свежей.
_secrel_nginx_affects() {
	local v="$1" nv="$2" vu="$3" x max="" r a b
	local IFS=','
	for x in $nv; do
		x="${x// /}"; x="${x%+}"
		[[ "$x" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
		[[ "${x%.*}" == "${v%.*}" ]] && _secrel_ge "$v" "$x" && return 1
		[[ -z "$max" ]] || _secrel_ge "$x" "$max" && max="$x"
	done
	[[ -n "$max" ]] && _secrel_ge "$v" "$max" && return 1
	for r in $vu; do
		r="${r// /}"
		a="${r%-*}"; b="${r#*-}"
		[[ "$a" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$b" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
		_secrel_ge "$v" "$a" && _secrel_ge "$b" "$v" && return 0
	done
	return 1
}

# Версия, в которой исправлено: из той же ветки, иначе самая свежая
_secrel_nginx_fixed_in() {
	local v="$1" nv="$2" x best="" max=""
	local IFS=','
	for x in $nv; do
		x="${x// /}"; x="${x%+}"
		[[ "$x" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
		[[ "${x%.*}" == "${v%.*}" ]] && best="$x"
		[[ -z "$max" ]] || _secrel_ge "$x" "$max" && max="$x"
	done
	echo "${best:-$max}"
}

# _secrel_nginx_report версия файл_списка → строки «уровень|текст»
_secrel_nginx_report() {
	local v="$1" file="$2" t sev cve nv vu n=0 major=0 fix="" f names=""
	while IFS='|' read -r t sev cve nv vu; do
		_secrel_nginx_affects "$v" "$nv" "$vu" || continue
		n=$((n + 1))
		[[ "$sev" == major ]] && { major=$((major + 1)); names+="${names:+; }${t} (${cve})"; }
		f="$(_secrel_nginx_fixed_in "$v" "$nv")"
		[[ -z "$fix" ]] || _secrel_ge "$f" "$fix" && fix="$f"
	done < <(_secrel_nginx_parse "$file")
	if ((n == 0)); then
		echo "ok|nginx ${v}: известных уязвимостей нет (nginx.org)"
		return
	fi
	echo "warn|nginx ${v}: уязвимостей ${n} (серьёзных ${major}), исправлено в ${fix}: luckyctl update nginx"
	[[ -n "$names" ]] && echo "info|серьёзные: ${names}"
}

_secrel_nginx() {
	[[ -x /usr/sbin/nginx ]] || return 0
	# nginx из пакетов дистрибутива исправляется через apt, номер версии там не растёт
	dpkg -S /usr/sbin/nginx >/dev/null 2>&1 && return 0
	local v f ossl latest series
	v="$(/usr/sbin/nginx -v 2>&1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
	[[ -n "$v" ]] || return 0
	if f="$(_secrel_fetch nginx-advisories.html "$SECREL_NGINX_URL")"; then
		_secrel_nginx_report "$v" "$f"
	else
		echo "info|nginx ${v}: nginx.org недоступен, проверка уязвимостей пропущена"
	fi
	# OpenSSL, вшитый в сборку nginx: исправления в нём приходят только с пересборкой
	ossl="$(/usr/sbin/nginx -V 2>&1 | grep -oE 'built with OpenSSL [0-9]+\.[0-9]+\.[0-9]+' | grep -oE '[0-9.]+$')"
	[[ -n "$ossl" ]] || return 0
	series="$(_secrel_mm "$ossl")"
	if f="$(_secrel_fetch openssl-releases.json "$SECREL_OPENSSL_URL")"; then
		latest="$(grep -oE "\"tag_name\": *\"openssl-${series//./\\.}\.[0-9]+\"" "$f" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1)"
		if [[ -n "$latest" ]] && ! _secrel_ge "$ossl" "$latest"; then
			echo "warn|OpenSSL в nginx ${ossl}, вышел ${latest}: luckyctl update nginx"
		elif [[ -n "$latest" ]]; then
			echo "ok|OpenSSL в nginx ${ossl}: последний в ветке ${series}"
		fi
	fi
}

# 1:8.4.27-2+0~deb.sury.org.1+debian12 → 8.4.27
_secrel_upstream() { local x="${1#*:}"; echo "${x%%[-+~]*}"; }

# Последняя версия ветки на php.net и есть ли у выпуска пометка security: «8.4.28 security»
_secrel_php_net() {
	local f="$1" br="$2"
	command -v php >/dev/null 2>&1 || return 1
	php -r '$j = json_decode(file_get_contents($argv[1]), true); if (!is_array($j)) exit(2);
		foreach ($j as $maj) foreach ((array)$maj as $b => $r) if ($b === $argv[2]) {
			echo $r["version"] ?? "", in_array("security", (array)($r["tags"] ?? [])) ? " security" : "", "\n"; exit(0); }
		exit(1);' "$f" "$br" 2>/dev/null
}

_secrel_php() {
	local d br pkg inst cand ui uc net f rc nv sec
	f="$(_secrel_fetch php-active.json "$SECREL_PHP_URL")" || f=""
	for d in /etc/php/*/fpm; do
		[[ -d "$d" ]] || continue
		br="$(basename "$(dirname "$d")")"
		[[ "$br" =~ ^[0-9]+\.[0-9]+$ ]] || continue
		pkg="php${br}-fpm"
		inst="$(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null)" || continue
		[[ -n "$inst" ]] || continue
		cand="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/ {print $2; exit}')"
		ui="$(_secrel_upstream "$inst")"
		if [[ -n "$cand" && "$cand" != "(none)" ]] && dpkg --compare-versions "$cand" gt "$inst"; then
			uc="$(_secrel_upstream "$cand")"
			if [[ "$uc" != "$ui" ]]; then
				echo "warn|PHP ${ui}, в репозитории ${uc}: luckyctl update pkgs"
			else
				echo "warn|PHP ${ui}: в репозитории новая сборка, luckyctl update pkgs"
			fi
			continue
		fi
		[[ -n "$f" ]] || { echo "ok|PHP ${ui}: последняя версия в репозитории"; continue; }
		net="$(_secrel_php_net "$f" "$br")"; rc=$?
		if ((rc == 1)); then
			echo "warn|PHP ${br}: поддержка закончилась, исправлений от php.net нет. Переведите сайты на новую версию"
			continue
		fi
		nv="${net%% *}"; sec=""; [[ "$net" == *" security" ]] && sec=" с исправлениями безопасности"
		if ((rc == 0)) && [[ "$nv" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ! _secrel_ge "$ui" "$nv"; then
			echo "info|PHP ${ui}: на php.net вышел ${nv}${sec}, в репозитории пакетов его пока нет"
		else
			echo "ok|PHP ${ui}: последняя версия"
		fi
	done
}

secrel_scan() {
	_secrel_nginx
	_secrel_php
}

# luckyctl security [--plain]
run_security_releases() {
	local plain=0 a lvl txt warn=0
	for a in "$@"; do [[ "$a" == "--plain" ]] && plain=1; done
	if ((plain)); then secrel_scan; return 0; fi
	ui_header "Исправления безопасности"
	ui_box_top "nginx, OpenSSL, PHP"
	while IFS='|' read -r lvl txt; do
		case "$lvl" in
			ok)   ui_box_line "  ${UI_G}✓${UI_NC} ${txt}" ;;
			warn) ui_box_line "  ${UI_Y}!${UI_NC} ${txt}"; warn=$((warn + 1)) ;;
			*)    ui_box_line "    ${UI_D}${txt}${UI_NC}" ;;
		esac
	done < <(secrel_scan)
	ui_box_bottom
	((warn)) && ui_warn "Есть что обновить (${warn})." || ui_success "Всё актуально."
	return 0
}
