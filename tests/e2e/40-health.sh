#!/usr/bin/env bash
# Команды luckyctl на живом сервере: проверка здоровья, состояние, исправления, репутация.

out="$(TERM=dumb luckyctl check </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
fails="$(grep -oE 'ОШИБКА: [0-9]+' <<<"$out" | grep -oE '[0-9]+$')"
[[ "${fails:-x}" == 0 ]] && ok "luckyctl check: ошибок нет ($(grep -oE 'OK: [0-9]+' <<<"$out"), $(grep -oE 'ВНИМАНИЕ: [0-9]+' <<<"$out"))" \
	|| { bad "luckyctl check: ошибок ${fails:-?}"; grep -E '✗' <<<"$out" | sed 's/^/       /' | head -10; }
check "luckyctl status" bash -c 'TERM=dumb luckyctl status </dev/null'
check "luckyctl version" bash -c 'luckyctl version </dev/null | grep -q LuckyStack'
check "luckyctl cve --plain" bash -c 'luckyctl cve --plain </dev/null | grep -qE "^(ok|warn|info)\|"'
if command -v postfix >/dev/null 2>&1; then
	check "luckyctl blacklist --plain" bash -c 'luckyctl blacklist --plain </dev/null | grep -qE "^(ok|warn|info)\|"'
fi
check "luckyctl paths" bash -c 'luckyctl paths </dev/null | grep -q /opt/luckystack'
