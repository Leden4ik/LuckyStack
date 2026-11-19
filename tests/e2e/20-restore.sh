#!/usr/bin/env bash
# Бэкап и восстановление: снимок → портим базу, файл сайта и письма → restore → всё на месте.

C=/etc/server-backup.conf
[[ -x /usr/local/sbin/server-backup.sh && -f "$C" ]] || { note "серверный бэкап не настроен, набор пропущен"; return; }
wd="$(e2e_webdir)"
mb="/var/vmail/${E2E_DOM}/box/Maildir"
[[ -n "$wd" && -d "$mb" ]] || { bad "нет тестового сайта или ящика (набор hosting не прошёл)"; return; }

cp -a "$C" /root/.luckystack-e2e-backup.conf
# в снимок нужны сайты и почта
for k in BACKUP_INCLUDE_WWW BACKUP_INCLUDE_MAIL; do
	if grep -q "^${k}=" "$C"; then sed -i "s/^${k}=.*/${k}=y/" "$C"; else echo "${k}=y" >>"$C"; fi
done

mails() { find "$mb" -type f \( -path '*/cur/*' -o -path '*/new/*' \) | wc -l; }
"${M[@]}" lstestdb -e "CREATE TABLE IF NOT EXISTS t (v VARCHAR(20)); DELETE FROM t; INSERT INTO t VALUES ('before');
	CREATE TABLE IF NOT EXISTS t2 (x INT); INSERT INTO t2 VALUES (1);"
echo before >"$wd/web/marker.txt"
chown "$(stat -c %U:%G "$wd/web")" "$wd/web/marker.txt"
m0="$(mails)"

TERM=dumb luckyctl backup </dev/null >/dev/null 2>&1
snap="$(ls -1dt /var/backups/server/2*/ 2>/dev/null | head -1)"
[[ -n "$snap" && -d "$snap/mysql" ]] && ok "снимок $(basename "$snap")" || { bad "снимок не создан"; cp -a /root/.luckystack-e2e-backup.conf "$C"; return; }

"${M[@]}" lstestdb -e "UPDATE t SET v='after'; DROP TABLE t2;"
rm -f "$wd/web/marker.txt"
find "$mb" -type f \( -path '*/cur/*' -o -path '*/new/*' \) -delete

/usr/local/sbin/server-backup.sh --restore "$(basename "$snap")" --db --www --vmail --yes >/dev/null 2>&1 \
	&& ok "restore отработал" || bad "restore вернул ошибку"
sleep 3
[[ "$("${M[@]}" -N lstestdb -e 'SELECT v FROM t' 2>/dev/null)" == before ]] && ok "база: строка вернулась" || bad "база: строка не вернулась"
[[ "$("${M[@]}" -N lstestdb -e 'SELECT COUNT(*) FROM t2' 2>/dev/null)" == 1 ]] && ok "база: удалённая таблица вернулась" || bad "база: таблица не вернулась"
[[ "$(cat "$wd/web/marker.txt" 2>/dev/null)" == before ]] && ok "сайт: файл вернулся" || bad "сайт: файл не вернулся"
[[ "$(stat -c %U "$wd/web/marker.txt" 2>/dev/null)" == "$(stat -c %U "$wd/web")" ]] && ok "сайт: владелец файла прежний" || bad "сайт: владелец файла другой"
[[ "$(mails)" == "$m0" && "$m0" -gt 0 ]] && ok "почта: письма вернулись (${m0})" || bad "почта: было ${m0}, стало $(mails)"
for s in mariadb nginx apache2 postfix dovecot; do
	systemctl list-unit-files "${s}.service" >/dev/null 2>&1 && systemctl is-enabled --quiet "$s" 2>/dev/null || continue
	check "после restore служба ${s} работает" systemctl is-active --quiet "$s"
done
r="$(curl -s --max-time 15 -H "Host: ${E2E_SITE}" http://127.0.0.1/lstest.php)"
[[ "$r" == *"db ok"* ]] && ok "после restore сайт и база работают" || bad "после restore сайт: ${r:-нет ответа}"

cp -a /root/.luckystack-e2e-backup.conf "$C" && rm -f /root/.luckystack-e2e-backup.conf
# снимок с тестовыми данными не оставляем
[[ "$snap" == /var/backups/server/2* ]] && rm -rf -- "${snap:?}"
