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
import http.server, json, sys, urllib.parse
log = sys.argv[1]
class H(http.server.BaseHTTPRequestHandler):
    def _h(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode("utf-8", "replace")
        if "json" in (self.headers.get("Content-Type") or ""):
            try: q = json.loads(body)
            except Exception: q = body
        else:
            q = {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}
        with open(log, "a") as f:
            f.write(json.dumps({"method": self.path.rsplit("/", 1)[-1], "body": q}, ensure_ascii=False) + "\n")
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
