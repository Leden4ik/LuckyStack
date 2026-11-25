#!/usr/bin/env bash
# Версии PHP: add-php, сайт на новой версии, защита remove-php (версию с сайтом не удалить),
# возврат сайта и удаление версии. Нужен набор hosting (сайт с lstest.php).

ph_site="$("${M[@]}" -N dbispconfig -e "SELECT domain_id, server_php_id FROM web_domain WHERE domain='${E2E_SITE}'" 2>/dev/null)"
[[ -n "$ph_site" ]] || { note "нет сайта ${E2E_SITE}: сначала набор hosting"; return; }
read -r ph_did ph_old <<<"$ph_site"

# свободная версия: есть в репозитории, но не стоит
ph_v=""
for v in 8.3 8.1 8.0; do
	dpkg -l "php${v}-fpm" 2>/dev/null | grep -q '^ii' && continue
	apt-cache show "php${v}-fpm" >/dev/null 2>&1 && { ph_v="$v"; break; }
done
[[ -n "$ph_v" ]] || { note "нет свободной версии PHP для проверки, набор пропущен"; return; }

# версия PHP у сайта через очередь ISPConfig, как это делает панель
ph_set() {
	php -r 'require "/usr/local/ispconfig/server/lib/config.inc.php"; require "/usr/local/ispconfig/server/lib/app.inc.php";
		$app->db->datalogUpdate("web_domain", array("server_php_id" => (int)$argv[2]), "domain_id", (int)$argv[1]);' "$ph_did" "$1" >/dev/null 2>&1
	e2e_wait_datalog 180
}
# ждём, пока lstest.php ответит нужной версией (пул перезапускается)
ph_wait() {
	local i r
	for i in $(seq 1 12); do
		r="$(curl -s --max-time 10 -H "Host: ${E2E_SITE}" http://127.0.0.1/lstest.php)"
		[[ "$r" == "php $1."* ]] && return 0
		sleep 5
	done
	echo "$r"; return 1
}

# на какой версии сайт сейчас (на неё же вернём)
ph_was="$(curl -s --max-time 10 -H "Host: ${E2E_SITE}" http://127.0.0.1/lstest.php | grep -oE '^php [0-9]+\.[0-9]+' | cut -d' ' -f2)"
[[ -n "$ph_was" ]] || { bad "php: lstest.php на сайте не отвечает"; return; }

luckyctl add-php "$ph_v" </dev/null >/dev/null 2>&1
check "php: add-php ${ph_v}, PHP-FPM запущен" systemctl is-active --quiet "php${ph_v}-fpm"
ph_id="$("${M[@]}" -N dbispconfig -e "SELECT server_php_id FROM server_php WHERE name='PHP ${ph_v}'" 2>/dev/null)"
[[ -n "$ph_id" ]] && ok "php: PHP ${ph_v} есть в ISPConfig (выбор у сайтов)" || { bad "php: PHP ${ph_v} не зарегистрирована в ISPConfig"; return; }

ph_set "$ph_id"
ph_r="$(ph_wait "$ph_v")" && ok "php: сайт работает на PHP ${ph_v}" || bad "php: сайт на PHP ${ph_v} отвечает «${ph_r}»"

# защита: версию, на которой есть сайт, удалить нельзя
luckyctl remove-php "$ph_v" </dev/null >/dev/null 2>&1; ph_rc=$?
if ((ph_rc != 0)) && dpkg -l "php${ph_v}-fpm" 2>/dev/null | grep -q '^ii'; then ok "php: remove-php не удаляет версию, на которой есть сайт"
else bad "php: remove-php удалил версию с живым сайтом"; fi

ph_set "$ph_old"
ph_r="$(ph_wait "$ph_was")" && ok "php: сайт вернулся на PHP ${ph_was}" || bad "php: сайт после возврата отвечает «${ph_r}»"

luckyctl remove-php "$ph_v" </dev/null >/dev/null 2>&1
if ! dpkg -l "php${ph_v}-fpm" 2>/dev/null | grep -q '^ii' \
   && [[ -z "$("${M[@]}" -N dbispconfig -e "SELECT 1 FROM server_php WHERE name='PHP ${ph_v}'" 2>/dev/null)" ]]; then
	ok "php: remove-php ${ph_v} удалил пакеты и запись в ISPConfig"
else bad "php: PHP ${ph_v} удалилась не полностью"; fi
