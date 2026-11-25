#!/usr/bin/env bash
# Сквозные тесты по расписанию на ТЕСТОВОМ сервере: раз в неделю все наборы, при ошибках
# уведомление через server-notify.sh. install кладёт копию этих тестов в /opt/luckystack/e2e
# (в установленный выпуск тесты не входят); после обновления тестов запустите install ещё раз.
#
#   bash tests/e2e/schedule.sh install [OnCalendar]   поставить таймер (по умолчанию «Sun 05:00»)
#   bash tests/e2e/schedule.sh remove                 убрать таймер
#   bash tests/e2e/schedule.sh status                 когда следующий запуск и чем кончился прошлый
#
# Как и сами тесты, работает только там, где есть /etc/luckystack/e2e-allowed.
set -uo pipefail

UNIT=luckystack-e2e
LOG=/var/log/luckystack/e2e-last.log
DEST=/opt/luckystack/e2e
RUN="${DEST}/run.sh"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "Нужен root."; exit 2; }
[[ -f /etc/luckystack/e2e-allowed ]] || { echo "Нет /etc/luckystack/e2e-allowed: это не тестовый сервер."; exit 2; }

case "${1:-status}" in
	install)
		when="${2:-Sun 05:00}"
		systemd-analyze calendar "$when" >/dev/null 2>&1 || { echo "Не понимаю время запуска: ${when}"; exit 2; }
		[[ -f "$HERE/run.sh" ]] || { echo "Рядом нет run.sh: запускайте schedule.sh из каталога тестов."; exit 2; }
		if [[ "$HERE" != "$DEST" ]]; then
			rm -rf "${DEST}.new" && mkdir -p "${DEST}.new" && cp -a "$HERE"/. "${DEST}.new"/ \
				&& rm -rf "$DEST" && mv "${DEST}.new" "$DEST" || { echo "Не удалось скопировать тесты в ${DEST}."; exit 1; }
		fi
		chmod -R go-w "$DEST"
		mkdir -p "$(dirname "$LOG")"
		cat >/etc/systemd/system/${UNIT}.service <<EOF
[Unit]
Description=LuckyStack: сквозные тесты (только тестовый сервер)
ConditionPathExists=/etc/luckystack/e2e-allowed
After=network-online.target

[Service]
Type=oneshot
Environment=E2E_NOTIFY=1
ExecStart=/bin/bash -c 'bash ${RUN} >${LOG} 2>&1'
TimeoutStartSec=2h
EOF
		cat >/etc/systemd/system/${UNIT}.timer <<EOF
[Unit]
Description=LuckyStack: сквозные тесты раз в неделю

[Timer]
OnCalendar=${when}
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF
		systemctl daemon-reload
		systemctl enable --now ${UNIT}.timer >/dev/null 2>&1 || { echo "Таймер не включился."; exit 1; }
		echo "Тесты по расписанию включены (${when}). Журнал прошлого прогона: ${LOG}"
		systemctl list-timers ${UNIT}.timer --no-pager | sed -n 1,2p ;;
	remove)
		systemctl disable --now ${UNIT}.timer >/dev/null 2>&1
		rm -f /etc/systemd/system/${UNIT}.service /etc/systemd/system/${UNIT}.timer
		rm -rf "$DEST"
		systemctl daemon-reload
		echo "Тесты по расписанию выключены." ;;
	status)
		systemctl list-timers ${UNIT}.timer --no-pager 2>/dev/null | sed -n 1,2p
		[[ -f "$LOG" ]] && { echo "Прошлый прогон ($(date -r "$LOG" '+%d.%m %H:%M')):"; grep -E '^Итог|^  - ' "$LOG" | head -12; } \
			|| echo "Прошлых прогонов нет." ;;
	*) echo "Использование: schedule.sh install [OnCalendar] | remove | status"; exit 2 ;;
esac
