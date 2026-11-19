#!/usr/bin/env bash
# Хостинг: API-пользователь, клиент с сайтом, базой, ящиком и DNS-зоной; всё ли это работает.

e2e_env
"${M[@]}" -e 'SELECT 1' >/dev/null 2>&1 || { bad "доступ к MariaDB по /root/.my.cnf"; return; }

# Временный API-пользователь со всеми функциями, пускаем только с самого сервера
funcs="$(php -r '$function_list = []; foreach (glob("/usr/local/ispconfig/interface/web/*/lib/remote.conf.php") as $x) include $x; echo implode(";", array_keys($function_list));')"
hash="$(openssl passwd -6 "$API_PW")"
"${M[@]}" dbispconfig -e "DELETE FROM remote_user WHERE remote_username='${E2E_API_USER}';
	INSERT INTO remote_user (sys_userid,sys_groupid,sys_perm_user,sys_perm_group,sys_perm_other,remote_username,remote_password,remote_access,remote_ips,remote_functions)
	VALUES (1,1,'riud','riud','','${E2E_API_USER}','${hash}','y','${SERVER_IP},127.0.0.1','${funcs}');" \
	&& ok "временный API-пользователь ${E2E_API_USER}" || { bad "временный API-пользователь"; return; }

# Если прошлый прогон оборвался, сначала убираем его клиента
e2e_api delete >/dev/null 2>&1 && e2e_wait_datalog 300 >/dev/null

while read -r line; do
	case "$line" in OK*) ok "${line#OK   }" ;; FAIL*) bad "${line#FAIL }" ;; *) note "$line" ;; esac
done < <(e2e_api create 2>&1)
e2e_wait_datalog 300 && ok "ISPConfig применил изменения" || bad "ISPConfig не применил изменения за 5 минут"

# --- сайт ---
wd="$(e2e_webdir)"
check "vhost ${E2E_SITE}" test -f "/etc/nginx/sites-enabled/100-${E2E_SITE}.vhost" -o -f "/etc/apache2/sites-enabled/100-${E2E_SITE}.vhost"
if command -v nginx >/dev/null 2>&1; then check "nginx -t" nginx -t; fi
if [[ -n "$wd" && -d "$wd/web" ]]; then
	cat >"$wd/web/lstest.php" <<PHP
<?php \$m = @new mysqli('localhost', 'lstestdb', '${DB_PW}', 'lstestdb');
echo 'php ', PHP_VERSION, \$m->connect_errno ? ' db fail' : ' db ok';
PHP
	chown "$(stat -c %U:%G "$wd/web")" "$wd/web/lstest.php"
	r="$(curl -s --max-time 15 -H "Host: ${E2E_SITE}" http://127.0.0.1/lstest.php)"
	[[ "$r" == *"db ok"* ]] && ok "сайт отвечает, PHP и база работают (${r})" || bad "сайт + PHP + база: ${r:-нет ответа}"
else
	bad "каталог сайта ${E2E_SITE} не создан"
fi
wu="$(stat -c %U "$wd/web" 2>/dev/null)"
check "пул PHP-FPM сайта (${wu:-?})" bash -c "ls /etc/php/*/fpm/pool.d/${wu:-none}.conf"

# --- DNS ---
if systemctl is-active --quiet named 2>/dev/null || systemctl is-active --quiet bind9 2>/dev/null; then
	check "DNS: SOA зоны ${E2E_DOM}" bash -c "dig +short SOA ${E2E_DOM} @127.0.0.1 | grep -q ."
	check "DNS: MX зоны ${E2E_DOM}" bash -c "dig +short MX ${E2E_DOM} @127.0.0.1 | grep -q ."
fi

# --- почта ---
if command -v postfix >/dev/null 2>&1; then
	t="$(date +%s)"
	# Отправитель из тестового домена: домен сервера может оказаться в Spamhaus DBL, тогда
	# антиспам справедливо унесёт письмо в «Спам», а проверяем мы доставку.
	printf 'From: e2e@%s\r\nTo: %s\r\nDate: %s\r\nMessage-ID: <%s.1@%s>\r\nSubject: e2e local %s\r\n\r\nhello\r\n' \
		"$E2E_DOM" "$E2E_BOX" "$(date -R)" "$t" "$E2E_DOM" "$t" >/tmp/e2e-m1.eml
	check "почта: приём на 25" curl -s --max-time 20 --url smtp://127.0.0.1:25 --mail-from "e2e@${E2E_DOM}" \
		--mail-rcpt "$E2E_BOX" --upload-file /tmp/e2e-m1.eml
	printf 'From: %s\r\nTo: %s\r\nDate: %s\r\nMessage-ID: <%s.2@%s>\r\nSubject: e2e submission %s\r\n\r\nhello2\r\n' \
		"$E2E_BOX" "$E2E_BOX" "$(date -R)" "$t" "$E2E_DOM" "$t" >/tmp/e2e-m2.eml
	check "почта: отправка на 587 (STARTTLS, пароль)" curl -s -k --max-time 20 --url "smtp://${FQDN}:587" --ssl-reqd \
		--mail-from "$E2E_BOX" --mail-rcpt "$E2E_BOX" -u "${E2E_BOX}:${BOX_PW}" --upload-file /tmp/e2e-m2.eml
	rm -f /tmp/e2e-m1.eml /tmp/e2e-m2.eml
	# Свои письма ищем по теме: первым в новом ящике лежит приветствие ISPConfig
	imap_find() {
		curl -s -k --max-time 20 "imaps://${FQDN}/${2:-INBOX}" -u "${E2E_BOX}:${BOX_PW}" -X "SEARCH SUBJECT \"$1\"" \
			| tr -d '\r' | grep -oE '[0-9]+' | tail -1
	}
	junk() { [[ -n "$(imap_find "$1" Junk)" ]] && echo ", а лежит в «Спаме»"; }
	n1=""; n2=""
	for _ in $(seq 1 24); do
		n1="$(imap_find "e2e local ${t}")"; n2="$(imap_find "e2e submission ${t}")"
		[[ -n "$n1" && -n "$n2" ]] && break
		sleep 5
	done
	[[ -n "$n1" ]] && ok "почта: письмо с 25 во входящих (IMAPS)" || bad "почта: письма с 25 нет во входящих$(junk "e2e local ${t}")"
	[[ -n "$n2" ]] && ok "почта: письмо с 587 во входящих (IMAPS)" || bad "почта: письма с 587 нет во входящих$(junk "e2e submission ${t}")"
	check "почта: POP3S" bash -c "curl -s -k --max-time 20 'pop3s://${FQDN}/' -u '${E2E_BOX}:${BOX_PW}' | grep -q ."
	check "почта: ManageSieve 4190" bash -c "timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/4190; head -c 300 <&3' | grep -q IMPLEMENTATION"
	if command -v rspamd >/dev/null 2>&1; then
		# письмо прошло проверку антиспама: Rspamd записал его Message-ID в журнал
		if grep -qsF "${t}.1@${E2E_DOM}" /var/log/rspamd/rspamd.log || journalctl -u rspamd --since "-10 min" --no-pager 2>/dev/null | grep -F "${t}.1@${E2E_DOM}" >/dev/null; then
			ok "почта: письмо проверил антиспам (Rspamd)"
		else
			bad "почта: Rspamd письмо не проверял"
		fi
	fi
fi
