#!/usr/bin/env bash
# Уведомления: Telegram подменён заглушкой на 127.0.0.1, проверяем, что сообщения доходят
# до обоих чатов и что монитор замечает упавшую службу.

C=/etc/server-notify.conf
N=/usr/local/sbin/server-notify.sh
[[ -x "$N" && -f "$C" ]] || { note "уведомления не установлены, набор пропущен"; return; }
command -v python3 >/dev/null 2>&1 || { note "нет python3 для заглушки Telegram, набор пропущен"; return; }

LOG=/root/.luckystack-e2e-tg.log
: >"$LOG"
python3 - "$LOG" >/dev/null 2>&1 <<'PY' &
import http.server, json, os, sys, urllib.parse
log = sys.argv[1]
queue = log + ".updates"   # что отдать боту на getUpdates (файл забирается один раз)
class H(http.server.BaseHTTPRequestHandler):
    def _h(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        if "json" in (self.headers.get("Content-Type") or ""):
            try: q = json.loads(body)
            except Exception: q = body
        else:
            q = {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}
        method = self.path.rsplit("/", 1)[-1]
        if method == "getUpdates":
            res = "[]"
            if os.path.exists(queue):
                with open(queue) as f: res = f.read().strip() or "[]"
                os.remove(queue)
            out = ('{"ok":true,"result":' + res + '}').encode()
        else:
            with open(log, "a") as f:
                f.write(json.dumps({"method": method, "body": q}, ensure_ascii=False) + "\n")
            out = b'{"ok":true,"result":{"message_id":1}}'
        self.send_response(200); self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out))); self.end_headers(); self.wfile.write(out)
    do_POST = _h
    do_GET = _h
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 18080), H).serve_forever()
PY
tg_pid=$!
sleep 1

cp -a "$C" /root/.luckystack-e2e-notify.conf
# отметки монитора «об этом уже сообщали» не трогаем: после теста вернём как было
mkdir -p /root/.luckystack-e2e-mon && cp -a /var/lib/server-monitor/. /root/.luckystack-e2e-mon/ 2>/dev/null
for kv in "NOTIFY_TG_TOKEN='123:e2e'" "NOTIFY_TG_CHATS='111 222'" "NOTIFY_TG_API='http://127.0.0.1:18080'" \
          "NOTIFY_EVENTS='monitor backup malware login'"; do
	k="${kv%%=*}"
	if grep -q "^${k}=" "$C"; then sed -i "s|^${k}=.*|${kv}|" "$C"; else echo "$kv" >>"$C"; fi
done

"$N" -e monitor -l warn "e2e проверка" "тестовое сообщение" >/dev/null 2>&1
n="$(grep -c '"sendMessage"' "$LOG")"
[[ "$n" == 2 ]] && ok "уведомление ушло в оба чата" || bad "уведомление: отправок ${n}, ждали 2"
grep -q 'e2e проверка' "$LOG" && ok "текст уведомления дошёл" || bad "текст уведомления не дошёл"

: >"$LOG"
"$N" -e digest -l info "e2e" "выключенное событие" >/dev/null 2>&1
[[ "$(grep -c sendMessage "$LOG")" == 0 ]] && ok "выключенное событие не отправляется" || bad "выключенное событие всё равно ушло"

# Язык уведомлений: при NOTIFY_LANG=en тема и строки текста переводятся (тем же переводом, что консоль)
if [[ -r /opt/luckystack/current/lang/en.lng ]]; then
	: >"$LOG"
	if grep -q '^NOTIFY_LANG=' "$C"; then sed -i "s|^NOTIFY_LANG=.*|NOTIFY_LANG='en'|" "$C"; else echo "NOTIFY_LANG='en'" >>"$C"; fi
	"$N" -e monitor -l warn "Сводка за сутки" "Бэкап: последний 1 дн. назад" >/dev/null 2>&1
	grep -q 'Daily summary' "$LOG" && grep -q 'Backup: last one 1 days ago' "$LOG" \
		&& ok "уведомление на английском (NOTIFY_LANG=en)" || bad "уведомление не перевелось на английский"
	sed -i "s|^NOTIFY_LANG=.*|NOTIFY_LANG=''|" "$C"
	: >"$LOG"
	"$N" -e monitor -l warn "Сводка за сутки" "Бэкап: последний 1 дн. назад" >/dev/null 2>&1
	grep -q 'Сводка за сутки' "$LOG" && ok "без NOTIFY_LANG уведомление на языке сервера (русском)" || bad "уведомление без NOTIFY_LANG не на русском"
fi

# Бот отвечает на языке уведомлений: отдаём ему /status и /backup от разрешённого id 111
BOT=/usr/local/sbin/server-tg-bot.php
if [[ -f "$BOT" ]] && command -v php >/dev/null 2>&1; then
	bot_was=""; systemctl is-active --quiet server-tg-bot 2>/dev/null && { bot_was=1; systemctl stop server-tg-bot; }
	mkdir -p /root/.luckystack-e2e-bot
	cp -a /var/lib/server-notify/tg-offset /var/lib/server-notify/chats.json /root/.luckystack-e2e-bot/ 2>/dev/null
	rm -f /var/lib/server-notify/tg-offset
	if grep -q '^NOTIFY_TG_BOT=' "$C"; then sed -i "s|^NOTIFY_TG_BOT=.*|NOTIFY_TG_BOT='y'|" "$C"; else echo "NOTIFY_TG_BOT='y'" >>"$C"; fi
	if grep -q '^NOTIFY_LANG=' "$C"; then sed -i "s|^NOTIFY_LANG=.*|NOTIFY_LANG='en'|" "$C"; else echo "NOTIFY_LANG='en'" >>"$C"; fi
	upd() {   # $1 = update_id, $2 = команда
		printf '[{"update_id":%s,"message":{"message_id":%s,"from":{"id":111},"chat":{"id":111,"type":"private"},"text":"%s"}}]' "$1" "$1" "$2" >"${LOG}.updates"
	}
	waitlog() { local i; for i in $(seq 1 30); do grep -q "$1" "$LOG" && return 0; sleep 0.5; done; return 1; }
	php "$BOT" >/dev/null 2>&1 &
	bot_pid=$!
	: >"$LOG"; upd 9001 /status
	waitlog 'Uptime:' && grep -q 'Services:' "$LOG" && ok "бот отвечает по-английски (NOTIFY_LANG=en)" || bad "бот не ответил по-английски на /status"
	: >"$LOG"; upd 9002 /backup
	waitlog 'Start a backup now' && grep -q '"Confirm"' "$LOG" && ok "вопрос и кнопки бота на английском" || bad "вопрос бота не на английском"
	sed -i "s|^NOTIFY_LANG=.*|NOTIFY_LANG=''|" "$C"
	: >"$LOG"; upd 9003 /status
	waitlog 'Аптайм:' && ok "без NOTIFY_LANG бот отвечает на языке сервера (русском)" || bad "бот без NOTIFY_LANG ответил не по-русски"
	kill "$bot_pid" 2>/dev/null; wait "$bot_pid" 2>/dev/null
	rm -f "${LOG}.updates" /var/lib/server-notify/tg-offset /var/lib/server-notify/chats.json
	cp -a /root/.luckystack-e2e-bot/. /var/lib/server-notify/ 2>/dev/null; rm -rf /root/.luckystack-e2e-bot
	mysql --defaults-file=/etc/mysql/debian.cnf dbispconfig -e "DELETE FROM ss_panel_audit WHERE username='telegram:111'" 2>/dev/null
	[[ -n "$bot_was" ]] && systemctl start server-tg-bot
fi

# Монитор видит упавшую службу (берём ту, что точно есть и не держит сайт)
svc=""
for s in rspamd redis-server clamav-daemon; do systemctl is-active --quiet "$s" 2>/dev/null && { svc="$s"; break; }; done
if [[ -n "$svc" && -x /usr/local/sbin/server-monitor.sh ]]; then
	: >"$LOG"
	systemctl stop "$svc"
	/usr/local/sbin/server-monitor.sh >/dev/null 2>&1
	systemctl start "$svc"
	grep -q "$svc" "$LOG" && ok "монитор сообщил об остановленной службе ${svc}" || bad "монитор не сообщил об остановке ${svc}"
	check "служба ${svc} снова работает" systemctl is-active --quiet "$svc"
fi

cp -a /root/.luckystack-e2e-notify.conf "$C" && rm -f /root/.luckystack-e2e-notify.conf
if [[ -d /root/.luckystack-e2e-mon ]]; then
	rm -f /var/lib/server-monitor/*-notified
	cp -a /root/.luckystack-e2e-mon/. /var/lib/server-monitor/ 2>/dev/null
	rm -rf /root/.luckystack-e2e-mon
fi
kill "$tg_pid" 2>/dev/null; wait "$tg_pid" 2>/dev/null
rm -f "$LOG"
