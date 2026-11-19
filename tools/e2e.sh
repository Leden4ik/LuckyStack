#!/usr/bin/env bash
# tools/e2e.sh root@хост [порт] [набор ...] — сквозные тесты на тестовом сервере.
# Берёт tests/e2e из последнего коммита, запускает на сервере и печатает итог.
# На сервере должен быть файл /etc/luckystack/e2e-allowed (защита от запуска на рабочем).
set -u
cd "$(dirname "$0")/.." || exit 1
target="${1:-}"; port=22
[[ -n "$target" ]] || { echo "укажите сервер: tools/e2e.sh root@хост [порт] [набор ...]"; exit 2; }
shift
[[ "${1:-}" =~ ^[0-9]+$ ]] && { port="$1"; shift; }
git -c core.autocrlf=false archive --format=tar HEAD tests/e2e \
	| ssh -p "$port" "$target" "d=\$(mktemp -d) && tar xf - -C \"\$d\" && bash \"\$d/tests/e2e/run.sh\" $*; rc=\$?; rm -rf \"\$d\"; exit \$rc"
