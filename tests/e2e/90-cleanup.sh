#!/usr/bin/env bash
# Уборка: удаляем тестового клиента со всем содержимым и временного API-пользователя.
# Выполняется всегда, даже если наборы упали.

if [[ -f "$E2E_ENV" ]]; then
	e2e_env
	while read -r line; do
		case "$line" in OK*) ok "уборка: ${line#OK   }" ;; FAIL*) bad "уборка: ${line#FAIL }" ;; esac
	done < <(e2e_api delete 2>&1)
	e2e_wait_datalog 300 || bad "уборка: ISPConfig не применил удаление за 5 минут"
	[[ ! -e "/etc/nginx/sites-enabled/100-${E2E_SITE}.vhost" && ! -e "/etc/apache2/sites-enabled/100-${E2E_SITE}.vhost" ]] \
		&& ok "уборка: сайт удалён" || bad "уборка: vhost ${E2E_SITE} остался"
fi
"${M[@]}" dbispconfig -e "DELETE FROM remote_user WHERE remote_username='${E2E_API_USER}'" 2>/dev/null \
	&& ok "уборка: временный API-пользователь удалён" || bad "уборка: API-пользователь остался"
# на случай оборванного прогона возвращаем настройки
[[ -f /root/.luckystack-e2e-backup.conf ]] && mv -f /root/.luckystack-e2e-backup.conf /etc/server-backup.conf
[[ -f /root/.luckystack-e2e-notify.conf ]] && mv -f /root/.luckystack-e2e-notify.conf /etc/server-notify.conf
rm -f "$E2E_ENV"
