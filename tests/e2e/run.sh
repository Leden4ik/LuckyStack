#!/usr/bin/env bash
# Сквозные тесты LuckyStack на ТЕСТОВОМ сервере с уже установленным стеком.
# Заводят через API ISPConfig клиента с сайтом, базой, ящиком и DNS-зоной, проверяют, что всё
# работает, гоняют бэкап с восстановлением и уведомления, а в конце убирают за собой.
#
#   bash tests/e2e/run.sh [набор ...]      наборы (по умолчанию все, по порядку):
#     hosting  клиент с сайтом, базой, ящиком и DNS; сайт, почта, DNS работают
#     webmail  вход в Roundcube, плагины ISPConfig, запись настройки через их API
#     php      add-php, сайт на новой версии, защита remove-php, удаление версии
#     nginx    откат на прошлую сборку и обратно (E2E_NGINX_BUILD=1 — ещё и пересборка)
#     sites    luckyctl sites замечает поломку и починку, update проверяет сайты
#     restore  бэкап и восстановление;  notify  уведомления;  health  команды luckyctl
#   E2E_NOTIFY=1  при ошибках прислать уведомление (для запуска по расписанию)
#   E2E_KEEP=1 bash tests/e2e/run.sh hosting   оставить демо-клиента (для скриншотов), убрать: run.sh cleanup
#   tools/e2e.sh root@хост [порт] [набор ...]   то же с рабочей машины
#
# Тесты создают и удаляют данные, поэтому работают только там, где есть файл
# /etc/luckystack/e2e-allowed (создайте его руками на тестовом сервере).
set -uo pipefail
E2E_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Нужен root."; exit 2; }
[[ -f /etc/luckystack/e2e-allowed ]] || {
	echo "Нет /etc/luckystack/e2e-allowed: это не тестовый сервер, тесты не запускаю."
	exit 2
}
[[ -f /usr/local/ispconfig/server/lib/config.inc.php ]] || { echo "ISPConfig не установлен."; exit 2; }

# shellcheck source=tests/e2e/lib.sh
. "$E2E_DIR/lib.sh"

want=("$@")
((${#want[@]})) || want=(hosting webmail php nginx sites restore notify health)
declare -A file=([hosting]=10-hosting.sh [restore]=20-restore.sh [notify]=30-notify.sh [health]=40-health.sh
	[webmail]=50-webmail.sh [php]=60-php.sh [nginx]=70-nginx.sh [sites]=80-sites.sh)

cleanup_done=0
e2e_cleanup() {
	((cleanup_done)) && return
	cleanup_done=1
	echo; echo "== уборка"
	# shellcheck source=tests/e2e/90-cleanup.sh
	. "$E2E_DIR/90-cleanup.sh"
}
trap 'e2e_cleanup; exit 130' INT TERM

echo "Сервер ${FQDN} (${SERVER_IP}), панель :${PANEL_PORT}, $(luckyctl version 2>/dev/null | grep -m1 -oE 'LuckyStack [0-9.]+')"
for s in "${want[@]}"; do
	[[ "$s" == cleanup ]] && { e2e_cleanup; continue; }
	[[ -n "${file[$s]:-}" ]] || { echo "Нет набора «${s}». Есть: ${!file[*]}"; continue; }
	echo; echo "== ${s}"
	# shellcheck disable=SC1090
	. "$E2E_DIR/${file[$s]}"
done
# уборка нужна, только если заводили клиента
if [[ " ${want[*]} " == *" hosting "* ]]; then
	if [[ "${E2E_KEEP:-0}" == 1 ]]; then echo; echo "Демо-клиент оставлен (E2E_KEEP=1). Убрать: run.sh cleanup"
	else e2e_cleanup; fi
fi

echo
echo "Итог: OK ${E2E_OK}, FAIL ${E2E_FAIL}"
((E2E_FAIL == 0)) || printf '  - %s\n' "${E2E_FAILED[@]}"
# по расписанию: о провале сообщаем через уведомления сервера
if [[ "${E2E_NOTIFY:-0}" == 1 ]] && ((E2E_FAIL > 0)) && [[ -x /usr/local/sbin/server-notify.sh ]]; then
	/usr/local/sbin/server-notify.sh -e monitor -l warn "Сквозные тесты: ошибок ${E2E_FAIL} из $((E2E_OK + E2E_FAIL))" \
		"$(printf '%s\n' "${E2E_FAILED[@]}")" >/dev/null 2>&1 || true
fi
exit $((E2E_FAIL > 0))
