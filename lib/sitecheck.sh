#!/usr/bin/env bash
# =============================================================================
# sitecheck.sh — как отвечают сайты, до и после обновления.
#
# Перед luckyctl update запоминаем код ответа каждого активного сайта ISPConfig (https и http),
# панели, Roundcube и phpMyAdmin, после обновления спрашиваем ещё раз и сравниваем. Запросы идут
# на 127.0.0.1 с нужным именем (curl --resolve), поэтому DNS, CDN и внешний firewall на результат
# не влияют.
#
# Сломался адрес, который отвечал, а после обновления не отвечает (000), отдаёт 5xx или вместо
# 2xx/3xx отдаёт 4xx. Такие адреса перепроверяются несколько раз: службы могут ещё
# перезапускаться. Сломавшееся попадает в UPD_FAILED, то есть в итог обновления, в журнал
# панели и в уведомление.
#
# luckyctl sites показывает ответы сейчас и что поменялось с прошлой проверки.
# =============================================================================

SC_DIR="${SC_DIR:-/var/lib/luckystack/sitecheck}"
SC_PAR="${SC_PAR:-8}"                # запросов одновременно
SC_TIMEOUT="${SC_TIMEOUT:-15}"       # секунд на запрос
SC_RETRIES="${SC_RETRIES:-3}"        # перепроверок сломавшихся
SC_RETRY_WAIT="${SC_RETRY_WAIT:-10}" # пауза перед перепроверкой
SC_KEEP="${SC_KEEP:-20}"             # сколько замеров хранить
SC_ISPC_CONF="${SC_ISPC_CONF:-/usr/local/ispconfig/server/lib/config.inc.php}"

# Порт панели ISPConfig из её vhost (nginx или Apache)
_sc_panel_port() {
	local p
	p="$(grep -m1 -oE 'listen[[:space:]]+[0-9]+' /etc/nginx/sites-available/ispconfig.vhost 2>/dev/null | grep -oE '[0-9]+$')"
	[[ -n "$p" ]] || p="$(grep -m1 -oE '^[[:space:]]*Listen[[:space:]]+[0-9]+' /etc/apache2/sites-available/ispconfig.vhost 2>/dev/null | grep -oE '[0-9]+$')"
	echo "${p:-${ISPCONFIG_PANEL_PORT:-8080}}"
}

# Что проверять: строки «метка<TAB>url<TAB>имя<TAB>порт»
_sc_targets() {
	[[ -f "$SC_ISPC_CONF" ]] || return 0
	local fq port d
	fq="${SERVER_FQDN:-$(hostname -f 2>/dev/null)}"
	if [[ -n "$fq" ]]; then
		port="$(_sc_panel_port)"
		printf 'панель ISPConfig\thttps://%s:%s/login/\t%s\t%s\n' "$fq" "$port" "$fq" "$port"
		printf 'Roundcube\thttps://%s/roundcube/\t%s\t443\n' "$fq" "$fq"
		printf 'phpMyAdmin\thttps://%s/phpmyadmin/\t%s\t443\n' "$fq" "$fq"
	fi
	declare -F _ispc_mysql >/dev/null || return 0
	while read -r d; do
		# пропускаем пустое, wildcard и всё, что не похоже на имя
		[[ -n "$d" && "$d" != *'*'* && "$d" != *[[:space:]/:]* ]] || continue
		printf 'https://%s/\thttps://%s/\t%s\t443\n' "$d" "$d" "$d"
		printf 'http://%s/\thttp://%s/\t%s\t80\n' "$d" "$d" "$d"
	done < <(_ispc_mysql -N -B -e "SELECT domain FROM web_domain WHERE active='y' AND type IN ('vhost','alias','subdomain','vhostsubdomain','vhostalias') ORDER BY domain" 2>/dev/null)
}

# Один запрос: «метка<TAB>код» (000 — не ответил)
_sc_probe() {
	local code
	code="$(curl -sk --noproxy '*' -o /dev/null -w '%{http_code}' -A 'LuckyStack-sitecheck' \
		--max-time "$SC_TIMEOUT" --resolve "$3:$4:127.0.0.1" "$2" 2>/dev/null)"
	[[ "$code" =~ ^[0-9]{3}$ ]] || code=000
	printf '%s\t%s\n' "$1" "$code"
}

# Цели со stdin, по SC_PAR запросов сразу; результат по алфавиту
_sc_run() {
	local tmp n=0 label url host port
	tmp="$(mktemp -d)" || return 1
	while IFS=$'\t' read -r label url host port; do
		[[ -n "$url" ]] || continue
		_sc_probe "$label" "$url" "$host" "$port" >"$tmp/$n" &
		n=$((n + 1))
		((n % SC_PAR == 0)) && wait
	done
	wait
	((n)) && cat "$tmp"/* | LC_ALL=C sort -t$'\t' -k1,1
	rm -rf "$tmp"
	return 0
}

# Замер: файл в SC_DIR, путь печатается. Код 1, если проверять нечего.
sc_snapshot() {
	local f old
	mkdir -p "$SC_DIR" && chmod 700 "$SC_DIR" || return 1
	f="${SC_DIR}/$(date +%Y%m%d-%H%M%S)-${1:-check}.tsv"
	_sc_targets | _sc_run >"$f"
	if [[ ! -s "$f" ]]; then rm -f "$f"; return 1; fi
	old="$(ls -1t "$SC_DIR"/*.tsv 2>/dev/null)"
	tail -n +$((SC_KEEP + 1)) <<<"$old" | while read -r o; do [[ -n "$o" ]] && rm -f "$o"; done
	echo "$f"
}

# 000 и 5xx: адрес не работает
_sc_bad() { [[ "$1" == 000 || "$1" == 5* ]]; }

# Стало хуже: перестал отвечать или отдаёт 5xx, или вместо 2xx/3xx отдаёт 4xx
_sc_regress() {
	local b="$1" a="$2"
	[[ "$b" == "$a" ]] && return 1
	_sc_bad "$a" && ! _sc_bad "$b" && return 0
	[[ "$a" == 4* && ("$b" == 2* || "$b" == 3*) ]] && return 0
	return 1
}

# Что поменялось: «метка<TAB>было<TAB>стало» для адресов, которые есть в обоих замерах
_sc_diff() {
	awk -F'\t' 'NR == FNR { b[$1] = $2; next } ($1 in b) && b[$1] != $2 { print $1 "\t" b[$1] "\t" $2 }' "$1" "$2"
}

# Метки адресов, которым стало хуже
_sc_regressed() {
	local l b a
	while IFS=$'\t' read -r l b a; do
		_sc_regress "$b" "$a" && echo "$l"
	done < <(_sc_diff "$1" "$2")
	return 0
}

# Перепроверить то, что сломалось, и поправить замер «после» на месте
_sc_recheck() {
	local before="$1" after="$2" i re tg new
	for ((i = 1; i <= SC_RETRIES; i++)); do
		re="$(_sc_regressed "$before" "$after")"
		[[ -n "$re" ]] || return 0
		sleep "$SC_RETRY_WAIT"
		tg="$(_sc_targets | awk -F'\t' 'NR == FNR { w[$0] = 1; next } ($1 in w)' <(printf '%s\n' "$re") -)"
		new="$(_sc_run <<<"$tg")"
		[[ -n "$new" ]] || continue
		awk -F'\t' -v OFS='\t' 'NR == FNR { n[$1] = $2; next } { if ($1 in n) $2 = n[$1]; print }' \
			<(printf '%s\n' "$new") "$after" >"${after}.tmp" && mv -f "${after}.tmp" "$after"
	done
	return 0
}

# Адреса, которые не работают (000/5xx), через запятую, не больше N
_sc_bad_list() {
	local f="$1" max="${2:-5}" l c out=() n=0
	while IFS=$'\t' read -r l c; do
		_sc_bad "$c" || continue
		n=$((n + 1))
		((n <= max)) && out+=("${l} ${c}")
	done <"$f"
	((n)) || return 0
	local s; s="$(printf '%s, ' "${out[@]}")"; s="${s%, }"
	((n > max)) && s+=" и ещё $((n - max))"
	echo "$s"
}

# Перед обновлением: замер и короткая сводка. Печатает путь к замеру (stdout), сообщения в stderr не идут.
sc_before_update() {
	local f bad
	f="$(sc_snapshot before)" || return 1
	bad="$(_sc_bad_list "$f" 5)"
	ui_info "Запомнил ответы: адресов $(wc -l <"$f")${bad:+. Уже сейчас не работают: ${bad}}" >&2
	echo "$f"
}

# После обновления: сравнить с замером до него.
# $1 — замер до, $2 — 1, если nginx в этот раз пересобирался, $3 — 1, если обновлялся ISPConfig
sc_after_update() {
	local before="$1" nginx_rebuilt="${2:-0}" ispc_updated="${3:-0}" after l b a total
	local -a bad=() chg=()
	echo ""
	ui_step "Обновление: сайты отвечают как раньше?"
	after="$(sc_snapshot after)" || { ui_warn "Не удалось проверить сайты после обновления."; return 0; }
	_sc_recheck "$before" "$after"
	while IFS=$'\t' read -r l b a; do
		if _sc_regress "$b" "$a"; then bad+=("${l}: ${b} → ${a}"); else chg+=("${l}: ${b} → ${a}"); fi
	done < <(_sc_diff "$before" "$after")
	total="$(wc -l <"$after")"
	if ((${#chg[@]})); then
		ui_info "Ответ изменился, но не в худшую сторону (${#chg[@]}):"
		for l in "${chg[@]}"; do ui_info "  ${l}"; done
	fi
	if ((${#bad[@]} == 0)); then
		ui_success "Сайты и панель отвечают как до обновления (адресов: ${total})."
		return 0
	fi

	ui_warn "После обновления перестали нормально отвечать ${#bad[@]} из ${total}:"
	for l in "${bad[@]}"; do ui_warn "  ${l}"; done
	local short; short="$(printf '%s; ' "${bad[@]:0:3}")"; short="${short%; }"
	((${#bad[@]} > 3)) && short+=" и ещё $((${#bad[@]} - 3))"

	# nginx пересобран в этот раз: прошлая сборка лежит рядом, предложим вернуть её сразу
	if ((nginx_rebuilt)) && [[ -t 0 && -z "${UPDATE_ITEMS:-}" ]] && declare -F _nginx_rollback >/dev/null \
	   && ui_confirm "nginx в этот раз пересобран. Вернуть прошлую сборку и проверить сайты ещё раз?" y; then
		if ( _nginx_rollback ); then
			local again left
			again="$(sc_snapshot after-rollback)" && _sc_recheck "$before" "$again"
			left="$(_sc_regressed "$before" "${again:-$after}" | wc -l)"
			if [[ -n "$again" ]] && ((left == 0)); then
				ui_success "После отката nginx сайты отвечают как до обновления."
				UPD_FAILED+=("Сайты ломались после пересборки nginx, вернул прошлую сборку: ${short}")
				return 0
			fi
			ui_warn "Откат nginx не помог (не работает ${left}). Новую сборку можно вернуть: $(ls_hint --rollback nginx)"
		fi
	elif ((nginx_rebuilt)); then
		ui_info "nginx в этот раз пересобран, вернуть прошлую сборку: $(ls_hint --rollback nginx)"
	fi
	UPD_FAILED+=("Сайты после обновления: перестали отвечать ${#bad[@]} (${short})")
	if ((ispc_updated)); then
		ui_info "ISPConfig обновлялся. Его бэкап перед обновлением: /var/backup/ispconfig_*, снимки LuckyStack: $(ls_hint --restore)"
	fi
	ui_info "Какие файлы поменяло это обновление: $(ls_hint --changes)"
	return 0
}

# luckyctl sites: ответы сейчас и отличия от прошлой проверки. Код 1, если что-то не работает.
run_sitecheck() {
	config_load >/dev/null 2>&1 || true
	local last cur l c b a nbad=0 nwarn=0 total when
	last="$(ls -1t "$SC_DIR"/*.tsv 2>/dev/null)"; last="${last%%$'\n'*}"
	ui_header "Как отвечают сайты"
	ui_info "Запросы идут на этот же сервер (127.0.0.1) по имени сайта, DNS не участвует."
	cur="$(sc_snapshot check)" || { ui_info "Проверять нечего: нет ни панели ISPConfig, ни сайтов."; return 0; }
	total="$(wc -l <"$cur")"
	ui_box_top "Адреса и коды ответа"
	while IFS=$'\t' read -r l c; do
		if _sc_bad "$c"; then ui_box_line "  ${UI_R}✗${UI_NC} ${l}  ${UI_R}${c}${UI_NC}"; nbad=$((nbad + 1))
		elif [[ "$c" == 4* ]]; then ui_box_line "  ${UI_Y}!${UI_NC} ${l}  ${c}"; nwarn=$((nwarn + 1))
		else ui_box_line "  ${UI_G}✓${UI_NC} ${l}  ${UI_D}${c}${UI_NC}"; fi
	done <"$cur"
	ui_box_bottom
	if [[ -n "$last" && -f "$last" ]]; then
		when="$(date -r "$last" '+%d.%m %H:%M' 2>/dev/null)"
		local diff; diff="$(_sc_diff "$last" "$cur")"
		if [[ -z "$diff" ]]; then
			ui_info "С прошлой проверки (${when}) ничего не изменилось."
		else
			ui_info "С прошлой проверки (${when}) изменилось:"
			while IFS=$'\t' read -r l b a; do
				if _sc_regress "$b" "$a"; then ui_warn "  ${l}: ${b} → ${a}"; else ui_info "  ${l}: ${b} → ${a}"; fi
			done <<<"$diff"
		fi
	fi
	((nwarn)) && ui_info "Ответ 4xx (${nwarn}) бывает и нормальным: пустой сайт, закрытый каталог, вход по паролю."
	if ((nbad)); then
		ui_warn "Не отвечают или отдают ошибку сервера: ${nbad} из ${total}."
		return 1
	fi
	ui_success "Все адреса отвечают (${total})."
	return 0
}
