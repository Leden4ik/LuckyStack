#!/usr/bin/env bats
# Репутация почты: ответы DNS подменены, сеть не нужна.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs mailrep
	SERVER_FQDN="mail.example.net"
	MAILREP_IP_LISTS="zen.spamhaus.org bl.spamcop.net"
	# сервер 203.0.113.5, локальный BIND есть и отвечает Spamhaus
	ip() { echo "1.1.1.1 via 203.0.113.1 dev eth0 src 203.0.113.5 uid 0"; }
	systemctl() { [[ "$*" == "is-active --quiet named" ]]; }
	DNS_PTR="mail.example.net."
	DNS_ZEN=""
	DNS_DBL=""
	DNS_PUBLIC_BLOCKED=1
	dig() {
		local a name="${*: -1}" loc=0
		for a in "$@"; do [[ "$a" == "@127.0.0.1" ]] && loc=1; [[ "$a" == "-x" ]] && { echo "$DNS_PTR"; return; }; done
		if [[ "$name" == *.spamhaus.org || "$name" == *.spamcop.net ]] && ((DNS_PUBLIC_BLOCKED)) && ((!loc)); then
			echo "127.255.255.254"; return
		fi
		case "$name" in
			2.0.0.127.zen.spamhaus.org) echo "127.0.0.2"; echo "127.0.0.10" ;;
			5.113.0.203.zen.spamhaus.org) [[ -n "$DNS_ZEN" ]] && echo "$DNS_ZEN" ;;
			example.net.dbl.spamhaus.org) [[ -n "$DNS_DBL" ]] && echo "$DNS_DBL" ;;
			mail.example.net) echo "203.0.113.5" ;;
		esac
		return 0
	}
}

@test "чистый сервер: PTR совпадает, IP и домен не в списках" {
	run mailrep_scan
	[[ "$output" == *"ok|PTR 203.0.113.5 → mail.example.net"* ]]
	[[ "$output" == *"ok|IP 203.0.113.5 не в чёрных списках (2 проверено)"* ]]
	[[ "$output" == *"ok|почтовые домены не в Spamhaus DBL (1)"* ]]
	[[ "$output" != *"warn|"* ]]
}

@test "IP в ZEN и домен в DBL — предупреждения с расшифровкой" {
	DNS_ZEN="127.0.0.3"
	DNS_DBL="127.0.1.2"
	run mailrep_scan
	[[ "$output" == *"warn|IP 203.0.113.5 в списке zen.spamhaus.org: CSS, рассылка спама с этого IP"* ]]
	[[ "$output" == *"warn|домен example.net в Spamhaus DBL: домен замечен в спаме"* ]]
	[[ "$output" == *"https://check.spamhaus.org/"* ]]
}

@test "без локального BIND публичный резолвер не считается чистым ответом" {
	systemctl() { return 1; }
	run mailrep_scan
	[[ "$output" == *"info|Spamhaus не отвечает через резолверы сервера"* ]]
	[[ "$output" != *"не в чёрных списках"* ]]
}

@test "PTR указывает на другое имя или не задан" {
	DNS_PTR="vps-123.hoster.example."
	run _mailrep_ptr 203.0.113.5 mail.example.net
	[[ "$output" == "warn|PTR 203.0.113.5 → vps-123.hoster.example, но vps-123.hoster.example не указывает обратно на 203.0.113.5" ]]
	DNS_PTR=""
	run _mailrep_ptr 203.0.113.5 mail.example.net
	[[ "$output" == "warn|PTR для 203.0.113.5 не задан"* ]]
}

@test "коды списков" {
	[ "$(_mailrep_code zen.spamhaus.org 127.0.0.4)" = "XBL, заражённая машина или открытый прокси" ]
	[ "$(_mailrep_code zen.spamhaus.org 127.0.0.11)" = "PBL, адрес не для отправки почты (так помечает провайдер)" ]
	[ "$(_mailrep_code dbl.spamhaus.org 127.0.1.104)" = "взломанный сайт на домене" ]
	[ "$(_mailrep_code bl.spamcop.net 127.0.0.2)" = "код 127.0.0.2" ]
}
