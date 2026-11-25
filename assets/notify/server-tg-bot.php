<?php
/*
  LuckyStack: управление сервером из Telegram (служба server-tg-bot, от root).

  Опрашивает Telegram (getUpdates, long polling) и выполняет короткий фиксированный набор команд.
  Shell нет: каждая команда — заранее написанное действие с проверкой аргументов.

  Кто может командовать: только пользователи, чей личный chat id есть в NOTIFY_TG_CHATS
  (/etc/server-notify.conf). Проверяется отправитель (from.id), а не чат, поэтому в группе
  посторонний участник ничего не сделает. Остальным на /start бот отвечает только их chat id,
  чтобы его было проще добавить в панели; все писавшие копятся в /var/lib/server-notify/chats.json
  (страница «Уведомления» → «Найти chat id» берёт их оттуда).

  Команды:
    /status            — состояние сервера
    /bans              — активные баны CrowdSec и fail2ban
    /check IP          — где забанен IP и за что
    /unban IP          — снять баны с IP (CrowdSec + fail2ban), с подтверждением
    /allow IP [часы]   — добавить IP в доверенные (по умолчанию 24 ч, 0 — навсегда), с подтверждением
    /backup            — запустить бэкап сейчас, с подтверждением
  Подтверждение — кнопка под сообщением, действует 2 минуты и только для того, кто вызвал команду.
  Каждое действие пишется в журнал действий панели (ss_panel_audit, панель telegram).
  Включается в панели (System → Notifications, «Управление из Telegram» → NOTIFY_TG_BOT='y').

  Язык ответов: NOTIFY_LANG (ru|en) из /etc/server-notify.conf, а если он пуст, UI_LANG сервера
  из /etc/luckystack/setup.conf. Журнал бота всегда по-русски, как остальные журналы.
*/

$CONF  = '/etc/server-notify.conf';
$STATE = '/var/lib/server-notify';
$LOG   = '/var/log/server-tg-bot.log';
$LANG  = 'ru';
@mkdir($STATE, 0700, true);

function blog($m) { global $LOG; @file_put_contents($LOG, date('Y-m-d H:i:s').' '.$m."\n", FILE_APPEND); @chmod($LOG, 0600); }
function readconf() {
	global $CONF; $o = array();
	if(is_file($CONF)) foreach(file($CONF) as $l) if(preg_match("/^\s*([A-Z_][A-Z0-9_]*)=(.*)$/", $l, $m)) $o[$m[1]] = trim(trim($m[2]), "'\"");
	return $o;
}
// язык ответов: настройка уведомлений, иначе язык сервера, иначе русский
function bot_lang($cf) {
	$l = isset($cf['NOTIFY_LANG']) ? $cf['NOTIFY_LANG'] : '';
	if($l === '' && preg_match('/^UI_LANG=["\']?([a-z]+)/m', (string)@file_get_contents('/etc/luckystack/setup.conf'), $m)) $l = $m[1];
	return $l === 'en' ? 'en' : 'ru';
}
// L('по-русски', 'in English') — фраза на языке ответов
function L($ru, $en) { global $LANG; return $LANG === 'en' ? $en : $ru; }
function allowed_ids($cf) {
	$out = array();
	foreach(preg_split('/[\s,;]+/', trim((isset($cf['NOTIFY_TG_CHATS']) ? $cf['NOTIFY_TG_CHATS'] : '').' '.(isset($cf['NOTIFY_TG_CHAT']) ? $cf['NOTIFY_TG_CHAT'] : '')), -1, PREG_SPLIT_NO_EMPTY) as $c)
		if(preg_match('/^[0-9]+$/', $c)) $out[$c] = true;   // только личные (положительные) id — это id пользователей
	return $out;
}
function api($method, $params, $timeout = 30) {
	global $cf;
	$base = (isset($cf['NOTIFY_TG_API']) && preg_match('#^https?://[A-Za-z0-9.:\-]+$#', $cf['NOTIFY_TG_API'])) ? $cf['NOTIFY_TG_API'] : 'https://api.telegram.org';
	$ch = curl_init($base.'/bot'.$cf['NOTIFY_TG_TOKEN'].'/'.$method);
	curl_setopt_array($ch, array(CURLOPT_RETURNTRANSFER => true, CURLOPT_TIMEOUT => $timeout, CURLOPT_POST => true,
		CURLOPT_POSTFIELDS => json_encode($params), CURLOPT_HTTPHEADER => array('Content-Type: application/json')));
	$r = curl_exec($ch); curl_close($ch);
	$j = json_decode((string)$r, true);
	return is_array($j) ? $j : array('ok' => false, 'description' => 'нет ответа');
}
function say($chat, $text, $kb = null) {
	$p = array('chat_id' => $chat, 'text' => mb_substr($text, 0, 4000));
	if($kb) $p['reply_markup'] = array('inline_keyboard' => $kb);
	return api('sendMessage', $p);
}
function run($cmd) { $o = array(); exec($cmd.' 2>&1', $o, $rc); return array($rc, $o); }
function db() {
	static $db = null, $conf = null;
	if($conf === null) { $conf = array(); require '/usr/local/ispconfig/server/lib/config.inc.php'; }   // один раз: файл определяет константы
	if($db === null || !@$db->ping()) {
		$db = @new mysqli($conf['db_host'], $conf['db_user'], $conf['db_password'], $conf['db_database']);
		if($db->connect_errno) { $db = null; return null; }
		$db->set_charset('utf8mb4');
	}
	return $db;
}
function audit($uid, $action, $detail) {
	$db = db(); if(!$db) return;
	$st = @$db->prepare("INSERT INTO ss_panel_audit (created, username, ip, panel, action, detail) VALUES (NOW(), ?, '', 'telegram', ?, ?)");
	if($st) { $u = 'telegram:'.$uid; $st->bind_param('sss', $u, $action, $detail); $st->execute(); }
}
function valid_ip($ip) { return (bool)filter_var($ip, FILTER_VALIDATE_IP); }

// ---------- команды ----------
function cmd_status() {
	$host = trim(shell_exec('hostname -f 2>/dev/null') ?: gethostname());
	$up = (int)@file_get_contents('/proc/uptime');
	$load = implode(' ', array_slice(explode(' ', trim(@file_get_contents('/proc/loadavg'))), 0, 3));
	$df = trim(shell_exec("df -P / | awk 'NR==2{print \$5}'"));
	$mm = preg_split('/\s+/', trim(shell_exec("free -m | awk '/^Mem:/{print \$3, \$2}'")));
	$mem = count($mm) === 2 ? sprintf(L('%d из %d МБ', '%d of %d MB'), $mm[0], $mm[1]) : '?';
	$down = array();
	$units = 'mariadb mysql redis-server postfix dovecot named bind9 nginx apache2 rspamd crowdsec crowdsec-firewall-bouncer fail2ban pure-ftpd-mysql clamav-daemon '
		.trim(shell_exec("systemctl list-unit-files 'php*-fpm.service' --no-legend 2>/dev/null | awk '{sub(\".service\",\"\",\$1); print \$1}' | tr '\\n' ' '"));
	foreach(preg_split('/\s+/', trim($units)) as $u) {
		if($u === '') continue;
		exec('systemctl is-enabled --quiet '.escapeshellarg($u).' 2>/dev/null', $x, $en); if($en !== 0) continue;
		exec('systemctl is-active --quiet '.escapeshellarg($u).' 2>/dev/null', $x, $ac); if($ac !== 0) $down[] = $u;
	}
	$bk = '—';
	if(is_file('/etc/server-backup.conf')) {
		$dir = trim(shell_exec('. /etc/server-backup.conf 2>/dev/null; echo "${BACKUP_DIR:-/var/backups/server}"'));
		$newest = 0; foreach((array)glob(rtrim($dir, '/').'/[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9]', GLOB_ONLYDIR) as $d) $newest = max($newest, filemtime($d));
		$bk = $newest ? sprintf(L('последний %d дн. назад (%s)', 'last one %d days ago (%s)'), floor((time() - $newest) / 86400), date('Y-m-d H:i', $newest)) : L('снимков нет', 'no snapshots');
	}
	$reboot = is_file('/var/run/reboot-required') ? L('НУЖНА', 'REQUIRED') : L('не нужна', 'not needed');
	return L('Сервер ', 'Server ').$host."\n"
		.sprintf(L('Аптайм: %d д %d ч, нагрузка: %s', 'Uptime: %dd %dh, load: %s'), floor($up / 86400), floor($up % 86400 / 3600), $load)."\n"
		.sprintf(L('Диск /: %s, память: %s', 'Disk /: %s, memory: %s'), $df, $mem)."\n"
		.L('Службы: ', 'Services: ').($down ? L('НЕ работают: ', 'NOT running: ').implode(', ', $down) : L('все работают', 'all running'))."\n"
		.L('Бэкап: ', 'Backup: ').$bk."\n"
		.L('Перезагрузка: ', 'Reboot: ').$reboot;
}
function cmd_bans() {
	$t = '';
	if(trim(shell_exec('command -v cscli')) !== '') {
		list($rc, $o) = run('cscli decisions list -o json');
		$rows = array(); foreach((array)json_decode(implode("\n", $o), true) as $a) foreach((array)@$a['decisions'] as $d) $rows[] = $d;
		$t .= L('CrowdSec, локальных банов: ', 'CrowdSec, local bans: ').count($rows)."\n";
		foreach(array_slice($rows, 0, 10) as $d) $t .= '  '.$d['value'].' — '.$d['scenario'].' ('.$d['duration'].")\n";
	}
	if(trim(shell_exec('command -v fail2ban-client')) !== '') {
		list($rc, $o) = run('fail2ban-client banned');
		$s = implode(' ', $o); $n = preg_match_all("/'([0-9a-fA-F:.]+)'/", $s, $mm);
		$t .= L('fail2ban, банов: ', 'fail2ban, bans: ').$n.($n ? ': '.implode(', ', array_slice($mm[1], 0, 10)) : '')."\n";
	}
	return $t !== '' ? trim($t) : L('Ни CrowdSec, ни fail2ban не найдены.', 'Neither CrowdSec nor fail2ban is installed.');
}
function cmd_check($ip) {
	if(!valid_ip($ip)) return L('Нужен IP-адрес: /check 1.2.3.4', 'An IP address is needed: /check 1.2.3.4');
	$t = "IP $ip\n";
	if(trim(shell_exec('command -v cscli')) !== '') {
		list($rc, $o) = run('cscli allowlists check '.escapeshellarg($ip));
		foreach($o as $l) if(stripos($l, 'allowlisted by') !== false) $t .= L('Доверенный: ', 'Trusted: ').trim($l)."\n";
		list($rc, $o) = run('cscli decisions list -a -i '.escapeshellarg($ip).' -o json');
		$d = array(); foreach((array)json_decode(implode("\n", $o), true) as $a) foreach((array)@$a['decisions'] as $x) $d[] = $x['type'].' '.$x['origin'].' / '.$x['scenario'].' ('.$x['duration'].')';
		$t .= 'CrowdSec: '.($d ? implode('; ', $d) : L('нет решений', 'no decisions'))."\n";
	}
	if(trim(shell_exec('command -v fail2ban-client')) !== '') {
		list($rc, $o) = run('fail2ban-client banned '.escapeshellarg($ip));
		preg_match_all("/'([A-Za-z0-9_.-]+)'/", implode(' ', $o), $m);
		$t .= 'fail2ban: '.($m[1] ? L('забанен в ', 'banned in ').implode(', ', $m[1]) : L('не забанен', 'not banned'))."\n";
	}
	$db = db();
	if($db) { $r = @$db->query("SELECT target FROM ufw_block WHERE active='y'");
		if($r) while($x = $r->fetch_assoc()) if($x['target'] === $ip || (strpos($x['target'], '/') !== false && ip_in($ip, $x['target']))) $t .= L('Блок-лист ufw: ', 'ufw block list: ').$x['target']."\n"; }
	return trim($t);
}
function ip_in($ip, $cidr) {
	list($net, $mask) = explode('/', $cidr, 2); $mask = (int)$mask;
	$a = @inet_pton($ip); $b = @inet_pton($net); if($a === false || $b === false || strlen($a) !== strlen($b)) return false;
	$bytes = intdiv($mask, 8); $rem = $mask % 8;
	if($bytes && substr($a, 0, $bytes) !== substr($b, 0, $bytes)) return false;
	if($rem) { $mb = (0xff << (8 - $rem)) & 0xff; if((ord($a[$bytes]) & $mb) !== (ord($b[$bytes]) & $mb)) return false; }
	return true;
}
function do_unban($ip) {
	$t = '';
	if(trim(shell_exec('command -v cscli')) !== '') {
		list($rc, $o) = run('cscli decisions delete --ip '.escapeshellarg($ip));
		$t .= 'CrowdSec: '.(preg_match('/(\d+) decision\(s\) deleted/', implode(' ', $o), $m) ? L('снято решений ', 'decisions removed: ').$m[1] : trim(implode(' ', $o)))."\n";
	}
	if(trim(shell_exec('command -v fail2ban-client')) !== '') { list($rc, $o) = run('fail2ban-client unban '.escapeshellarg($ip)); $t .= L('fail2ban: снято банов ', 'fail2ban: bans removed: ').trim(implode(' ', $o))."\n"; }
	return trim($t) !== '' ? trim($t) : L('Нечего снимать.', 'Nothing to remove.');
}
function do_allow($ip, $hours, $uid) {
	$db = db(); if(!$db) return L('Нет связи с базой панели.', 'No connection to the panel database.');
	$c = L('из Telegram', 'from Telegram').' ('.$uid.')';
	$sec = $hours * 3600;
	$st = $db->prepare("INSERT INTO ss_trusted_ip (target, comment, expires, source, created, created_by, applied) VALUES (?, ?, IF(? > 0, NOW() + INTERVAL ? SECOND, NULL), 'panel', NOW(), ?, 'n')
		ON DUPLICATE KEY UPDATE comment = VALUES(comment), expires = VALUES(expires), applied = 'n', applied_at = NULL, note = NULL");
	if(!$st) return L('Таблицы доверенных IP нет (панель «Доверенные IP» не установлена).', 'There is no trusted IP table (the Trusted IPs panel is not installed).');
	$by = 'telegram:'.$uid; $st->bind_param('ssiis', $ip, $c, $sec, $sec, $by); $st->execute();
	if(is_file('/usr/local/ispconfig/server/scripts/ss-trusted-sync.php')) run('/usr/bin/php /usr/local/ispconfig/server/scripts/ss-trusted-sync.php');
	return $hours > 0
		? sprintf(L('%s добавлен в доверенные на %d ч. CrowdSec и fail2ban его больше не банят, текущие баны сняты.', '%s is trusted for %d h now. CrowdSec and fail2ban no longer ban it, its current bans are removed.'), $ip, $hours)
		: sprintf(L('%s добавлен в доверенные навсегда. CrowdSec и fail2ban его больше не банят, текущие баны сняты.', '%s is trusted permanently now. CrowdSec and fail2ban no longer ban it, its current bans are removed.'), $ip);
}
function do_backup() {
	$db = db();
	if($db && @$db->query("SELECT 1 FROM backup_job LIMIT 1") !== false) {
		$r = $db->query("SELECT id FROM backup_job WHERE status IN ('pending','running') LIMIT 1");
		if($r && $r->num_rows) return L('Бэкап уже идёт или стоит в очереди.', 'A backup is already running or queued.');
		$db->query("INSERT INTO backup_job (action, status, created) VALUES ('run', 'pending', NOW())");
		return L('Бэкап поставлен в очередь, запустится в течение минуты. Итог видно в панели (System → Backup / Restore), о сбое придёт уведомление.',
			'The backup is queued and will start within a minute. The result is in the panel (System → Backup / Restore), you will get a notification if it fails.');
	}
	if(!is_file('/usr/local/sbin/server-backup.sh')) return L('Бэкап не настроен.', 'Backups are not set up.');
	exec('nohup /usr/local/sbin/server-backup.sh >/dev/null 2>&1 &');
	return L('Бэкап запущен. О сбое придёт уведомление.', 'The backup has started. You will get a notification if it fails.');
}
function help_text() {
	return L("Команды:\n/status — состояние сервера\n/bans — активные баны\n/check IP — где забанен IP\n/unban IP — снять баны (с подтверждением)\n/allow IP [часы] — в доверенные, по умолчанию 24 ч, 0 — навсегда (с подтверждением)\n/backup — бэкап сейчас (с подтверждением)",
		"Commands:\n/status: server status\n/bans: active bans\n/check IP: where an IP is banned\n/unban IP: remove bans (with confirmation)\n/allow IP [hours]: trust an IP, 24 h by default, 0 means forever (with confirmation)\n/backup: back up now (with confirmation)");
}

// ---------- основной цикл ----------
$offset_file = $STATE.'/tg-offset';
$chats_file  = $STATE.'/chats.json';
$pending = array();      // токен подтверждения => [uid, chat, action, args, expires]
$replied_unknown = array();
blog('запуск');
while(true) {
	$cf = readconf();
	// бот работает только при явно включённом NOTIFY_TG_BOT='y' и заданном токене
	if(empty($cf['NOTIFY_TG_TOKEN']) || !isset($cf['NOTIFY_TG_BOT']) || $cf['NOTIFY_TG_BOT'] !== 'y') { sleep(30); continue; }
	$LANG = bot_lang($cf);
	$allowed = allowed_ids($cf);
	$offset = (int)@file_get_contents($offset_file);
	$r = api('getUpdates', array('offset' => $offset, 'timeout' => 25, 'allowed_updates' => array('message', 'callback_query')), 35);
	if(empty($r['ok'])) { blog('getUpdates: '.(isset($r['description']) ? $r['description'] : '?')); sleep(10); continue; }
	if(empty($r['result'])) { sleep(1); continue; }
	foreach($r['result'] as $u) {
		$offset = max($offset, (int)$u['update_id'] + 1);
		@file_put_contents($offset_file, (string)$offset);
		// просроченные подтверждения
		foreach($pending as $k => $p) if($p['expires'] < time()) unset($pending[$k]);

		if(isset($u['callback_query'])) {
			$cq = $u['callback_query']; $uid = (string)$cq['from']['id']; $data = (string)@$cq['data'];
			$chat = $cq['message']['chat']['id']; $mid = $cq['message']['message_id'];
			if(!isset($allowed[$uid])) { api('answerCallbackQuery', array('callback_query_id' => $cq['id'], 'text' => L('Нет доступа', 'No access'))); continue; }
			if(!preg_match('/^(ok|no):([a-f0-9]{16})$/', $data, $m) || !isset($pending[$m[2]]) || $pending[$m[2]]['uid'] !== $uid) {
				api('answerCallbackQuery', array('callback_query_id' => $cq['id'], 'text' => L('Подтверждение устарело, повторите команду', 'The confirmation has expired, send the command again')));
				continue;
			}
			$p = $pending[$m[2]]; unset($pending[$m[2]]);
			if($m[1] === 'no') { $res = L('Отменено.', 'Cancelled.'); audit($uid, $p['action'].'_cancel', implode(' ', $p['args'])); }
			else {
				if($p['action'] === 'unban')      $res = do_unban($p['args'][0]);
				elseif($p['action'] === 'allow')  $res = do_allow($p['args'][0], (int)$p['args'][1], $uid);
				else                              $res = do_backup();
				audit($uid, $p['action'], implode(' ', $p['args']).' → '.mb_substr($res, 0, 300));
			}
			api('answerCallbackQuery', array('callback_query_id' => $cq['id']));
			api('editMessageText', array('chat_id' => $chat, 'message_id' => $mid, 'text' => $p['question']."\n\n".$res));
			continue;
		}

		if(!isset($u['message']['chat']['id'])) continue;
		$msg = $u['message']; $chat = $msg['chat']; $uid = isset($msg['from']['id']) ? (string)$msg['from']['id'] : '';
		$text = trim((string)@$msg['text']);
		// копим писавших (для «Найти chat id» в панели)
		$known = @json_decode((string)@file_get_contents($chats_file), true); if(!is_array($known)) $known = array();
		$parts = array(); foreach(array('title', 'first_name', 'last_name') as $f) if(!empty($chat[$f])) $parts[] = $chat[$f];
		if(!empty($chat['username'])) $parts[] = '@'.$chat['username'];
		$known[(string)$chat['id']] = array('id' => (string)$chat['id'], 'type' => (string)@$chat['type'], 'name' => implode(' ', $parts), 'date' => date('Y-m-d H:i'));
		if(count($known) > 20) $known = array_slice($known, -20, null, true);
		@file_put_contents($chats_file, json_encode($known, JSON_UNESCAPED_UNICODE)); @chmod($chats_file, 0600);

		if(!isset($allowed[$uid])) {
			// незнакомцу — только его chat id и только на /start, не чаще раза в 10 минут
			if(preg_match('#^/start#', $text) && (!isset($replied_unknown[$uid]) || $replied_unknown[$uid] < time() - 600)) {
				$replied_unknown[$uid] = time();
				say($chat['id'], sprintf(L("Ваш chat id: %s\nЧтобы получать уведомления и управлять сервером, админ должен добавить его в панели ISPConfig: System → Notifications.",
					"Your chat id: %s\nTo get notifications and manage the server, the admin has to add it in the ISPConfig panel: System → Notifications."), $chat['id']));
			}
			blog("незнакомец $uid ({$chat['id']}): ".mb_substr($text, 0, 60));
			continue;
		}
		if($text === '' || $text[0] !== '/') continue;
		$a = preg_split('/\s+/', $text); $cmd = strtolower(preg_replace('/@.*$/', '', $a[0]));
		blog("команда от $uid: ".mb_substr($text, 0, 80));
		if($cmd === '/start' || $cmd === '/help') { say($chat['id'], help_text()); continue; }
		if($cmd === '/status') { say($chat['id'], cmd_status()); audit($uid, 'status', ''); continue; }
		if($cmd === '/bans')   { say($chat['id'], cmd_bans()); audit($uid, 'bans', ''); continue; }
		if($cmd === '/check')  { say($chat['id'], cmd_check(isset($a[1]) ? $a[1] : '')); audit($uid, 'check', isset($a[1]) ? $a[1] : ''); continue; }
		$q = null; $args = array();
		if($cmd === '/unban') {
			if(!isset($a[1]) || !valid_ip($a[1])) { say($chat['id'], L('Нужен IP-адрес: /unban 1.2.3.4', 'An IP address is needed: /unban 1.2.3.4')); continue; }
			$args = array($a[1]); $q = sprintf(L('Снять баны CrowdSec и fail2ban с %s?', 'Remove CrowdSec and fail2ban bans from %s?'), $a[1]);
		} elseif($cmd === '/allow') {
			if(!isset($a[1]) || !valid_ip($a[1])) { say($chat['id'], L('Нужен IP-адрес: /allow 1.2.3.4 [часы]', 'An IP address is needed: /allow 1.2.3.4 [hours]')); continue; }
			$hours = isset($a[2]) ? $a[2] : '24';
			if(!ctype_digit($hours) || (int)$hours > 8760) { say($chat['id'], L('Срок — целое число часов от 0 до 8760 (0 — навсегда).', 'The period is a whole number of hours from 0 to 8760 (0 means forever).')); continue; }
			$args = array($a[1], (int)$hours);
			$q = (int)$hours > 0
				? sprintf(L('Добавить %s в доверенные на %d ч? Его перестанут банить CrowdSec и fail2ban.', 'Trust %s for %d h? CrowdSec and fail2ban will stop banning it.'), $a[1], (int)$hours)
				: sprintf(L('Добавить %s в доверенные навсегда? Его перестанут банить CrowdSec и fail2ban.', 'Trust %s permanently? CrowdSec and fail2ban will stop banning it.'), $a[1]);
		} elseif($cmd === '/backup') {
			$q = L('Запустить бэкап сейчас?', 'Start a backup now?');
		} else { say($chat['id'], L('Неизвестная команда.', 'Unknown command.')."\n\n".help_text()); continue; }
		$tok = bin2hex(random_bytes(8));
		$pending[$tok] = array('uid' => $uid, 'action' => ltrim($cmd, '/'), 'args' => $args, 'question' => $q, 'expires' => time() + 120);
		say($chat['id'], $q."\n".L('(кнопка действует 2 минуты)', '(the button works for 2 minutes)'), array(array(array('text' => L('Подтвердить', 'Confirm'), 'callback_data' => 'ok:'.$tok), array('text' => L('Отмена', 'Cancel'), 'callback_data' => 'no:'.$tok))));
	}
}
