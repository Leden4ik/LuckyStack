#!/usr/bin/env bash
# Вебмейл: вход в Roundcube ящиком тестового клиента, страницы плагинов ISPConfig и запись
# настройки через их API (автоответ). Нужен набор hosting (ящик box@).

WM_RC=/opt/roundcube
[[ -f "$WM_RC/program/include/iniset.php" ]] || { note "Roundcube не с сайта разработчиков, набор пропущен"; return; }
[[ -n "$("${M[@]}" -N dbispconfig -e "SELECT 1 FROM mail_user WHERE email='${E2E_BOX}'" 2>/dev/null)" ]] \
	|| { note "нет ящика ${E2E_BOX}: сначала набор hosting"; return; }
e2e_env

wm_ver="$(grep -oE "RCMAIL_VERSION'?, *'[0-9.]+" "$WM_RC/program/include/iniset.php" | grep -oE '[0-9.]+$')"
wm_base="https://${FQDN}/roundcube/"
wm_jar="$(mktemp)"
wm_err0="$(wc -l </var/log/roundcube/errors.log 2>/dev/null || echo 0)"
wm_c() { curl -sk --max-time 30 --resolve "${FQDN}:443:127.0.0.1" -b "$wm_jar" -c "$wm_jar" "$@"; }
# скрытое поле _token со страницы
wm_tok() { grep -oE 'name="_token" value="[^"]+"' <<<"$1" | head -1 | sed 's/.*value="//; s/"$//'; }

wm_page="$(wm_c "$wm_base")"
wm_t="$(wm_tok "$wm_page")"
if [[ -n "$wm_t" ]]; then ok "вебмейл: Roundcube ${wm_ver}, страница входа"; else bad "вебмейл: страница входа Roundcube ${wm_ver}"; rm -f "$wm_jar"; return; fi

wm_r="$(wm_c -o /dev/null -w '%{http_code} %{redirect_url}' --data-urlencode "_token=${wm_t}" \
	--data "_task=login&_action=login&_timezone=Europe/Moscow" --data-urlencode "_user=${E2E_BOX}" \
	--data-urlencode "_pass=${BOX_PW}" "${wm_base}?_task=login")"
if [[ "$wm_r" == 302*"_task=mail"* ]]; then ok "вебмейл: вход ящиком ${E2E_BOX}"; else bad "вебмейл: вход (${wm_r})"; rm -f "$wm_jar"; return; fi
wm_inbox="$(wm_c "${wm_base}?_task=mail&_mbox=INBOX")"
grep -q 'id="messagelist"' <<<"$wm_inbox" && ok "вебмейл: папка Входящие" || bad "вебмейл: папка Входящие"

# страницы плагинов: своя форма (у account — обзор без формы), без сообщения об ошибке
for wm_p in "$WM_RC"/plugins/ispconfig3_*; do
	[[ -d "$wm_p" ]] || continue
	wm_p="$(basename "$wm_p")"
	[[ "$wm_p" == ispconfig3_account ]] && continue
	wm_body="$(wm_c "${wm_base}?_task=settings&_action=plugin.${wm_p}")"
	wm_msg="$(grep -oE 'display_message[(][^)]{0,160}' <<<"$wm_body" | grep -i 'error' | head -1)"
	if grep -qE '<form id="[a-z_]+"' <<<"$wm_body" && [[ -z "$wm_msg" ]]; then ok "вебмейл: плагин ${wm_p}"
	else bad "вебмейл: плагин ${wm_p} ${wm_msg:-без формы}"; fi
done

# запись через API ISPConfig: включить автоответ и выключить обратно
wm_ar() {   # wm_ar 1|0 — сохранить автоответ включённым или выключенным
	local form t en=""
	form="$(wm_c "${wm_base}?_task=settings&_action=plugin.ispconfig3_autoreply")"; t="$(wm_tok "$form")"
	[[ "$1" == 1 ]] && en="&_autoreplyenabled=1"
	wm_c --data-urlencode "_token=${t}" --data "_task=settings&_action=plugin.ispconfig3_autoreply.save${en}" \
		--data-urlencode "_autoreplysubject=e2e" --data-urlencode "_autoreplybody=e2e autoreply" \
		--data-urlencode "_autoreplystarton=$(date +%Y-%m-%d) 00:00" \
		--data-urlencode "_autoreplyendby=$(date -d '+7 day' +%Y-%m-%d) 00:00" "$wm_base"
}
wm_db() { "${M[@]}" -N dbispconfig -e "SELECT autoresponder FROM mail_user WHERE email='${E2E_BOX}'" 2>/dev/null; }
if [[ -d "$WM_RC/plugins/ispconfig3_autoreply" ]]; then
	wm_out="$(wm_ar 1)"
	[[ "$(wm_db)" == y ]] && grep -q 'confirmation' <<<"$wm_out" && ok "вебмейл: автоответ включился через API ISPConfig" \
		|| bad "вебмейл: автоответ не записался (в базе: $(wm_db))"
	wm_ar 0 >/dev/null
	[[ "$(wm_db)" == n ]] && ok "вебмейл: автоответ выключился обратно" || bad "вебмейл: автоответ не выключился"
fi

wm_t2="$(grep -oE '"request_token":"[^"]+"' <<<"$wm_inbox" | head -1 | cut -d'"' -f4)"
wm_c -o /dev/null "${wm_base}?_task=logout&_token=${wm_t2}"
rm -f "$wm_jar"
# новые ошибки Roundcube (давние предупреждения PHP в плагинах spam и wblist не считаем)
wm_new="$(tail -n +"$((wm_err0 + 1))" /var/log/roundcube/errors.log 2>/dev/null | grep -v 'PHP Warning:.*plugins/ispconfig3_\(spam\|wblist\)/')"
[[ -z "$wm_new" ]] && ok "вебмейл: новых ошибок в errors.log нет" || { bad "вебмейл: ошибки в errors.log"; sed 's/^/       /' <<<"$wm_new" | tail -5; }
