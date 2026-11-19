#!/usr/bin/env bash
# Сквозные тесты LuckyStack на ТЕСТОВОМ сервере с уже установленным стеком.
# Заводят через API ISPConfig клиента с сайтом, базой, ящиком и DNS-зоной, проверяют, что всё
# работает, гоняют бэкап с восстановлением и уведомления, а в конце убирают за собой.
#
#   bash tests/e2e/run.sh [набор ...]      наборы: hosting restore notify health (по умолчанию все)
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
((${#want[@]})) || want=(hosting restore notify health)
declare -A file=([hosting]=10-hosting.sh [restore]=20-restore.sh [notify]=30-notify.sh [health]=40-health.sh)

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
	[[ -n "${file[$s]:-}" ]] || { echo "Нет набора «${s}». Есть: ${!file[*]}"; continue; }
	echo; echo "== ${s}"
	# shellcheck disable=SC1090
	. "$E2E_DIR/${file[$s]}"
done
# уборка нужна, только если заводили клиента
[[ " ${want[*]} " == *" hosting "* ]] && e2e_cleanup

echo
echo "Итог: OK ${E2E_OK}, FAIL ${E2E_FAIL}"
((E2E_FAIL == 0)) || printf '  - %s\n' "${E2E_FAILED[@]}"
exit $((E2E_FAIL > 0))
