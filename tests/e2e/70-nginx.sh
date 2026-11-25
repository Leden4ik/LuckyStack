#!/usr/bin/env bash
# nginx: откат на прошлую сборку и возврат обратно, после каждого шага конфиг, панель и сайт
# отвечают. Полная пересборка (несколько минут) только с E2E_NGINX_BUILD=1.

ng_up() {   # nginx работает, конфиг проходит проверку, панель и сайт отвечают
	local what="$1" p s
	systemctl is-active --quiet nginx && nginx -t >/dev/null 2>&1 || { bad "nginx: ${what}: служба или конфиг"; return; }
	p="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 --resolve "${FQDN}:${PANEL_PORT}:127.0.0.1" "https://${FQDN}:${PANEL_PORT}/login/")"
	s=200   # сайт проверяем, только если его завёл набор hosting
	[[ -e "/etc/nginx/sites-enabled/100-${E2E_SITE}.vhost" ]] \
		&& s="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: ${E2E_SITE}" http://127.0.0.1/)"
	if [[ "$p" == 200 ]] && [[ "$s" =~ ^(200|301|302|404)$ ]]; then ok "nginx: ${what}: работает, панель 200, сайт ${s}"
	else bad "nginx: ${what}: панель ${p}, сайт ${s}"; fi
}

if [[ "${E2E_NGINX_BUILD:-0}" == 1 ]]; then
	ng_out="$(UPDATE_ITEMS=nginx luckyctl update nginx </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
	grep -q 'скомпилирован и установлен' <<<"$ng_out" && ok "nginx: пересборка $(nginx -v 2>&1 | grep -oE '[0-9.]+$')" || bad "nginx: пересборка не прошла"
	grep -q 'отвечают как до обновления' <<<"$ng_out" && ok "nginx: после пересборки сайты отвечают как раньше" || bad "nginx: проверка сайтов после пересборки"
	ng_up "после пересборки"
fi

# Прошлой сборки нет или она побайтно та же (пересборка из тех же исходников): подкладываем
# копию текущей с припиской в конце файла. Исполняемому файлу она не мешает, а механизм
# подмены и возврата проверяется по-настоящему. Настоящую прошлую сборку потом возвращаем.
ng_fake=0
if [[ ! -x /usr/sbin/nginx.backup ]] || cmp -s /usr/sbin/nginx /usr/sbin/nginx.backup; then
	[[ -e /usr/sbin/nginx.backup ]] && cp -a /usr/sbin/nginx.backup /root/.luckystack-e2e-nginx.backup
	cp -a /usr/sbin/nginx /usr/sbin/nginx.backup && printf '\nluckystack-e2e\n' >>/usr/sbin/nginx.backup
	ng_fake=1
fi
ng_h0="$(sha256sum /usr/sbin/nginx | cut -c1-64)"
luckyctl rollback nginx </dev/null >/dev/null 2>&1
[[ "$(sha256sum /usr/sbin/nginx | cut -c1-64)" != "$ng_h0" ]] && ok "nginx: откат на прошлую сборку" || bad "nginx: откат не подменил сборку"
ng_up "после отката"
luckyctl rollback nginx </dev/null >/dev/null 2>&1
[[ "$(sha256sum /usr/sbin/nginx | cut -c1-64)" == "$ng_h0" ]] && ok "nginx: повторный откат вернул новую сборку" || bad "nginx: новая сборка не вернулась"
ng_up "после возврата"
if ((ng_fake)); then
	if [[ -e /root/.luckystack-e2e-nginx.backup ]]; then mv -f /root/.luckystack-e2e-nginx.backup /usr/sbin/nginx.backup
	else rm -f /usr/sbin/nginx.backup; fi
fi
