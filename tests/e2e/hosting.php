<?php
// Тестовый хостинг через remote API ISPConfig: клиент, сайт, база, ящик, DNS-зона.
// php hosting.php create|delete. Параметры из окружения (их задаёт lib.sh): E2E_API_URL,
// E2E_API_USER, API_PW, BOX_PW, DB_PW, E2E_DOM, E2E_FQDN, E2E_IP.
$mode = $argv[1] ?? 'create';
$dom  = getenv('E2E_DOM');
$site = 'site.' . $dom;
$fqdn = getenv('E2E_FQDN');
$url  = getenv('E2E_API_URL');
// Свой сервер: проверка сертификата здесь не цель (её делает luckyctl check), а на тестовом
// он может быть из тестового центра Let's Encrypt
$c = new SoapClient(null, ['location' => $url . 'index.php', 'uri' => $url, 'trace' => 1, 'exceptions' => 1,
	'stream_context' => stream_context_create(['ssl' => ['verify_peer' => false, 'verify_peer_name' => false]])]);
$s = $c->login(getenv('E2E_API_USER'), getenv('API_PW'));

function step($name, $fn) {
	try { $r = $fn(); echo "OK   $name\n"; return $r; }
	catch (SoapFault $e) { echo "FAIL $name: " . $e->getMessage() . "\n"; return false; }
}

if ($mode === 'delete') {
	$cl = $c->client_get_by_username($s, 'lstestcli');
	if ($cl) step('API: client_delete_everything', fn() => $c->client_delete_everything($s, $cl['client_id']));
	else echo "OK   API: тестового клиента нет\n";
	$c->logout($s);
	exit(0);
}

$cid = step('API: client_add', fn() => $c->client_add($s, 0, [
	'company_name' => 'LuckyStack e2e', 'contact_name' => 'e2e', 'customer_no' => 'LSE2E',
	'username' => 'lstestcli', 'password' => getenv('BOX_PW'), 'email' => 'box@' . $dom,
	'language' => 'ru', 'usertheme' => 'default', 'country' => 'RU', 'street' => '', 'zip' => '', 'city' => '',
	'state' => '', 'telephone' => '', 'mobile' => '', 'fax' => '', 'internet' => '', 'icq' => '', 'notes' => '',
	'default_mailserver' => 1, 'default_webserver' => 1, 'default_dnsserver' => 1, 'default_dbserver' => 1,
	'limit_maildomain' => -1, 'limit_mailbox' => -1, 'limit_mailalias' => -1, 'limit_mailaliasdomain' => -1,
	'limit_mailforward' => -1, 'limit_mailcatchall' => -1, 'limit_mailrouting' => 0, 'limit_mailfilter' => -1,
	'limit_fetchmail' => -1, 'limit_mailquota' => -1, 'limit_spamfilter_wblist' => -1, 'limit_spamfilter_user' => -1,
	'limit_spamfilter_policy' => -1, 'limit_web_domain' => -1, 'limit_web_quota' => -1, 'web_php_options' => 'no,php-fpm',
	'limit_web_aliasdomain' => -1, 'limit_web_subdomain' => -1, 'limit_ftp_user' => -1, 'limit_shell_user' => 0,
	'ssh_chroot' => 'no,jailkit', 'limit_webdav_user' => 0, 'limit_dns_zone' => -1, 'limit_dns_record' => -1,
	'limit_database' => -1, 'limit_cron' => 0, 'limit_cron_type' => 'url', 'limit_cron_frequency' => 5,
	'limit_traffic_quota' => -1, 'limit_client' => 0, 'parent_client_id' => 0, 'locked' => 'n', 'canceled' => 'n',
	'added_date' => date('Y-m-d'), 'added_by' => 'admin',
]));
if (!$cid) exit(1);

$wid = step('API: sites_web_domain_add', fn() => $c->sites_web_domain_add($s, $cid, [
	'server_id' => 1, 'ip_address' => '*', 'ipv6_address' => '', 'domain' => $site, 'type' => 'vhost',
	'parent_domain_id' => 0, 'vhost_type' => 'name', 'hd_quota' => -1, 'traffic_quota' => -1,
	'cgi' => 'n', 'ssi' => 'n', 'suexec' => 'y', 'errordocs' => 1, 'is_subdomainwww' => 1, 'subdomain' => 'none',
	'php' => 'php-fpm', 'ruby' => 'n', 'redirect_type' => '', 'redirect_path' => '', 'ssl' => 'n',
	'ssl_letsencrypt' => 'n', 'stats_type' => '', 'allow_override' => 'All', 'apache_directives' => '',
	'nginx_directives' => '', 'php_open_basedir' => '/', 'pm' => 'ondemand', 'pm_max_requests' => 0,
	'pm_process_idle_timeout' => 10, 'custom_php_ini' => '', 'backup_interval' => 'none', 'backup_copies' => 1,
	'active' => 'y', 'traffic_quota_lock' => 'n', 'http_port' => '80', 'https_port' => '443',
	'server_php_id' => 0, 'added_date' => date('Y-m-d'), 'added_by' => 'admin',
], true));

$dbu = step('API: sites_database_user_add', fn() => $c->sites_database_user_add($s, $cid, [
	'server_id' => 1, 'database_user' => 'lstestdb', 'database_password' => getenv('DB_PW')]));
if ($wid && $dbu) step('API: sites_database_add', fn() => $c->sites_database_add($s, $cid, [
	'server_id' => 1, 'parent_domain_id' => $wid, 'type' => 'mysql', 'database_name' => 'lstestdb',
	'database_user_id' => $dbu, 'database_ro_user_id' => 0, 'database_charset' => 'utf8mb4',
	'remote_access' => 'n', 'remote_ips' => '', 'backup_interval' => 'none', 'backup_copies' => 1, 'active' => 'y']));

$mid = step('API: mail_domain_add', fn() => $c->mail_domain_add($s, $cid, [
	'server_id' => 1, 'domain' => $dom, 'active' => 'y']));
if ($mid) step('API: mail_user_add', fn() => $c->mail_user_add($s, $cid, [
	'server_id' => 1, 'email' => 'box@' . $dom, 'login' => 'box@' . $dom, 'password' => getenv('BOX_PW'),
	'name' => 'e2e box', 'uid' => 5000, 'gid' => 5000, 'maildir' => "/var/vmail/$dom/box",
	'quota' => 104857600, 'cc' => '', 'homedir' => '/var/vmail', 'autoresponder' => 'n',
	'autoresponder_start_date' => null, 'autoresponder_end_date' => null, 'autoresponder_subject' => '',
	'autoresponder_text' => '', 'move_junk' => 'y', 'custom_mailfilter' => '', 'postfix' => 'y',
	'access' => 'y', 'disableimap' => 'n', 'disablepop3' => 'n', 'disabledeliver' => 'n',
	'disablesmtp' => 'n', 'disablesieve' => 'n', 'disablelda' => 'n', 'disabledoveadm' => 'n']));

// DNS-зона по первому шаблону (его сидит установщик)
$tpl = (int)(getenv('E2E_TPL_ID') ?: 1);
step('API: dns_templatezone_add', fn() => $c->dns_templatezone_add($s, $cid, $tpl, $dom, getenv('E2E_IP'),
	"ns1.$fqdn", "ns2.$fqdn", "admin@$fqdn", ''));

$c->logout($s);
