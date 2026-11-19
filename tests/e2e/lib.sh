#!/usr/bin/env bash
# Общее для сквозных тестов: окружение сервера, счётчики, проверки.
# Подключается из run.sh, наборы *.sh выполняются в том же процессе.

E2E_DOM="lstest.example"
E2E_SITE="site.${E2E_DOM}"
E2E_BOX="box@${E2E_DOM}"
E2E_ENV=/root/.luckystack-e2e.env
E2E_API_USER=lstest

FQDN="$(hostname -f 2>/dev/null || hostname)"
PANEL_PORT="$(grep -oP '^ISPCONFIG_PANEL_PORT="?\K[0-9]+' /etc/luckystack/setup.conf 2>/dev/null | head -1)"
PANEL_PORT="${PANEL_PORT:-8080}"
SERVER_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | grep -oE 'src [0-9.]+' | awk '{print $2; exit}')"
M=(mariadb --defaults-extra-file=/root/.my.cnf)

E2E_OK=0
E2E_FAIL=0
E2E_FAILED=()

ok()   { printf '  \033[0;32mOK\033[0m   %s\n' "$1"; E2E_OK=$((E2E_OK + 1)); }
bad()  { printf '  \033[0;31mFAIL\033[0m %s\n' "$1"; E2E_FAIL=$((E2E_FAIL + 1)); E2E_FAILED+=("$1"); }
note() { printf '       %s\n' "$*"; }
# check "что проверяем" команда… — OK, если команда успешна
check() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }

# Пароли тестового клиента живут только на время прогона
e2e_env() {
	if [[ ! -f "$E2E_ENV" ]]; then
		(umask 077; printf 'API_PW=%s\nBOX_PW=%s\nDB_PW=%s\n' \
			"$(openssl rand -hex 12)" "$(openssl rand -hex 12)" "$(openssl rand -hex 12)" >"$E2E_ENV")
	fi
	set -a; . "$E2E_ENV"; set +a
}

# Вызов API ISPConfig: e2e_api create|delete
e2e_api() {
	E2E_TPL_ID="$("${M[@]}" -N dbispconfig -e 'SELECT COALESCE(MIN(template_id),1) FROM dns_template' 2>/dev/null)" \
	E2E_API_URL="https://${FQDN}:${PANEL_PORT}/remote/" E2E_DOM="$E2E_DOM" E2E_FQDN="$FQDN" \
		E2E_IP="$SERVER_IP" E2E_API_USER="$E2E_API_USER" php "$E2E_DIR/hosting.php" "$1"
}

# Дождаться, пока сервер ISPConfig применит все изменения из sys_datalog (до N секунд)
e2e_wait_datalog() {
	local max="${1:-300}" t=0 last applied
	while ((t < max)); do
		last="$("${M[@]}" -N dbispconfig -e 'SELECT COALESCE(MAX(datalog_id),0) FROM sys_datalog' 2>/dev/null)"
		applied="$("${M[@]}" -N dbispconfig -e 'SELECT COALESCE(MIN(updated),0) FROM server WHERE active=1' 2>/dev/null)"
		[[ -n "$last" && "$applied" -ge "$last" ]] && return 0
		# server.sh запускается cron раз в минуту; не ждём его
		/usr/local/ispconfig/server/server.sh >/dev/null 2>&1
		sleep 5; t=$((t + 5))
	done
	return 1
}

# Каталог web сайта E2E_SITE
e2e_webdir() { readlink -f "/var/www/${E2E_SITE}" 2>/dev/null; }
