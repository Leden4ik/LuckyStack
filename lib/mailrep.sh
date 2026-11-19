#!/usr/bin/env bash
# =============================================================================
# mailrep.sh — репутация почты сервера:
#   обратная запись (PTR) внешнего IP и её совпадение с именем сервера;
#   IP в чёрных списках (Spamhaus ZEN, SpamCop, PSBL, Mailspike);
#   почтовые домены ISPConfig в Spamhaus DBL.
# Spamhaus не отвечает через публичные резолверы (1.1.1.1, 8.8.8.8 и т. п.), на такие
# запросы приходит служебный 127.255.255.x. Поэтому списки спрашиваем через локальный
# BIND, если он есть и сам ходит к Spamhaus, а иначе честно пишем, что проверить нельзя.
#
# mailrep_scan печатает строки «уровень|текст» (ok, warn, info), как secrel_scan.
# Показывает luckyctl check (раздел «Репутация почты») и luckyctl blacklist, ежедневный
# монитор шлёт warn уведомлением.
# =============================================================================

MAILREP_IP_LISTS="${MAILREP_IP_LISTS:-zen.spamhaus.org bl.spamcop.net psbl.surriel.com bl.mailspike.net}"

# A-записи ответа (только IPv4-адреса, без строк ошибок dig)
_mailrep_q() {
	local res="$1" name="$2"
	# shellcheck disable=SC2086  # res пустой или «@127.0.0.1»
	dig $res -4 +short +time=3 +tries=1 A "$name" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'
}

# Резолвер, через который Spamhaus отвечает: тестовая точка 127.0.0.2 обязана дать 127.0.0.2.
# Печатает «@127.0.0.1», пустую строку (системный) или ничего с кодом 1.
_mailrep_resolver() {
	local r
	if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
		_mailrep_q @127.0.0.1 2.0.0.127.zen.spamhaus.org | grep -qx '127.0.0.2' && { echo "@127.0.0.1"; return 0; }
	fi
	r="$(_mailrep_q "" 2.0.0.127.zen.spamhaus.org)"
	grep -qx '127.0.0.2' <<<"$r" && { echo ""; return 0; }
	return 1
}

# Внешний IPv4 сервера: адрес исходящего маршрута, а за NAT — A-запись имени сервера
_mailrep_ip() {
	local ip fqdn="$1"
	ip="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2; exit}')"
	if [[ -z "$ip" || "$ip" =~ ^(10\.|192\.168\.|172\.(1[6-9]|2[0-9]|3[01])\.|100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.) ]]; then
		ip="$(_mailrep_q "" "$fqdn" | head -1)"
	fi
	echo "$ip"
}

# Что значит код ответа списка
_mailrep_code() {
	local list="$1" code="$2"
	case "$list:$code" in
		zen.spamhaus.org:127.0.0.2|zen.spamhaus.org:127.0.0.9) echo "SBL, источник спама" ;;
		zen.spamhaus.org:127.0.0.3)  echo "CSS, рассылка спама с этого IP" ;;
		zen.spamhaus.org:127.0.0.[4-7]) echo "XBL, заражённая машина или открытый прокси" ;;
		zen.spamhaus.org:127.0.0.1[01]) echo "PBL, адрес не для отправки почты (так помечает провайдер)" ;;
		dbl.spamhaus.org:127.0.1.2)  echo "домен замечен в спаме" ;;
		dbl.spamhaus.org:127.0.1.4)  echo "фишинг" ;;
		dbl.spamhaus.org:127.0.1.5)  echo "вредоносное ПО" ;;
		dbl.spamhaus.org:127.0.1.6)  echo "управление ботнетом" ;;
		dbl.spamhaus.org:127.0.1.10[2-6]) echo "взломанный сайт на домене" ;;
		*) echo "код ${code}" ;;
	esac
}

# Почтовые домены: активные в ISPConfig, а без панели — домен имени сервера
_mailrep_domains() {
	local fqdn="$1" list=""
	if [[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] && declare -F _ispc_mysql >/dev/null; then
		list="$(_ispc_mysql -N -B -e "SELECT domain FROM mail_domain WHERE active='y' ORDER BY domain" 2>/dev/null)"
	fi
	[[ -n "$list" ]] || list="${fqdn#*.}"
	printf '%s\n' "$list" | grep -E '^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' | sort -u
}

_mailrep_ptr() {
	local ip="$1" fqdn="$2" ptr q fwd
	for q in "" -4; do
		# shellcheck disable=SC2086  # q пустой или «-4»
		ptr="$(dig $q +short +time=3 +tries=1 -x "$ip" 2>/dev/null | grep -E '^[A-Za-z0-9_.-]+\.?$' | sed 's/\.$//' | head -1)"
		[[ -n "$ptr" ]] && break
	done
	if [[ -z "$ptr" ]]; then
		echo "warn|PTR для ${ip} не задан: попросите хостера выставить ${fqdn}, без этого почту режут"
		return
	fi
	fwd="$(_mailrep_q "" "$ptr")"
	if ! grep -qxF "$ip" <<<"$fwd"; then
		echo "warn|PTR ${ip} → ${ptr}, но ${ptr} не указывает обратно на ${ip}"
	elif [[ "${ptr,,}" != "${fqdn,,}" ]]; then
		echo "warn|PTR ${ip} → ${ptr}, а сервер представляется как ${fqdn}. Лучше, чтобы совпадало"
	else
		echo "ok|PTR ${ip} → ${ptr}"
	fi
}

mailrep_scan() {
	local fqdn="${SERVER_FQDN:-$(hostname -f 2>/dev/null || hostname)}"
	command -v dig >/dev/null 2>&1 || { echo "info|нет dig (пакет bind9-dnsutils), проверка репутации пропущена"; return 0; }
	local ip res list rev ans code d bad=0 n=0
	ip="$(_mailrep_ip "$fqdn")"
	[[ -n "$ip" ]] || { echo "info|внешний IP не определён, проверка репутации пропущена"; return 0; }
	_mailrep_ptr "$ip" "$fqdn"

	if ! res="$(_mailrep_resolver)"; then
		echo "info|Spamhaus не отвечает через резолверы сервера (публичные DNS он не обслуживает), чёрные списки не проверены"
		return 0
	fi
	rev="$(awk -F. '{print $4"."$3"."$2"."$1}' <<<"$ip")"
	for list in $MAILREP_IP_LISTS; do
		ans="$(_mailrep_q "$res" "${rev}.${list}")"
		[[ -z "$ans" ]] && continue
		code="$(head -1 <<<"$ans")"
		[[ "$code" =~ ^127\.255\.255\. ]] && { echo "info|${list}: ответ не получен (${code})"; continue; }
		bad=$((bad + 1))
		echo "warn|IP ${ip} в списке ${list}: $(_mailrep_code "$list" "$code")"
	done
	((bad)) || echo "ok|IP ${ip} не в чёрных списках ($(wc -w <<<"$MAILREP_IP_LISTS") проверено)"
	[[ "$MAILREP_IP_LISTS" == *zen.spamhaus.org* ]] && ((bad)) && echo "info|проверить и снять из Spamhaus: https://check.spamhaus.org/"

	bad=0
	while read -r d; do
		[[ -n "$d" ]] || continue
		n=$((n + 1))
		code="$(_mailrep_q "$res" "${d}.dbl.spamhaus.org" | head -1)"
		[[ -z "$code" ]] && continue
		[[ "$code" =~ ^127\.255\.255\.|^127\.0\.1\.255$ ]] && { echo "info|DBL для ${d}: ответ не получен (${code})"; continue; }
		bad=$((bad + 1))
		echo "warn|домен ${d} в Spamhaus DBL: $(_mailrep_code dbl.spamhaus.org "$code")"
	done < <(_mailrep_domains "$fqdn")
	if ((bad)); then
		((n > bad)) && echo "ok|остальные почтовые домены не в Spamhaus DBL ($((n - bad)))"
		echo "info|заявка на снятие домена: https://check.spamhaus.org/ (сначала убедитесь, что спам с него больше не идёт)"
	elif ((n)); then
		echo "ok|почтовые домены не в Spamhaus DBL (${n})"
	fi
}

# luckyctl blacklist [--plain]
run_mail_reputation() {
	local plain=0 a lvl txt warn=0
	for a in "$@"; do [[ "$a" == "--plain" ]] && plain=1; done
	config_load >/dev/null 2>&1 || true
	if ((plain)); then mailrep_scan; return 0; fi
	ui_header "Репутация почты"
	ui_box_top "PTR, чёрные списки, Spamhaus DBL"
	while IFS='|' read -r lvl txt; do
		case "$lvl" in
			ok)   ui_box_line "  ${UI_G}✓${UI_NC} ${txt}" ;;
			warn) ui_box_line "  ${UI_Y}!${UI_NC} ${txt}"; warn=$((warn + 1)) ;;
			*)    ui_box_line "    ${UI_D}${txt}${UI_NC}" ;;
		esac
	done < <(mailrep_scan)
	ui_box_bottom
	((warn)) && ui_warn "Есть проблемы с репутацией (${warn})." || ui_success "С репутацией всё в порядке."
	return 0
}
