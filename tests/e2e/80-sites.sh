#!/usr/bin/env bash
# Проверка сайтов: luckyctl sites замечает, что сайт сломался и что починился, а обновление
# пишет, что сайты отвечают как раньше. Нужен набор hosting.
#
# Главной сайта на время теста становится свой index.php. Ломаем и чиним его содержимое, а не
# переименовываем файлы: nginx держит открытые файлы в кэше (open_file_cache, до минуты), и
# переименованная стартовая страница ещё какое-то время отдавалась бы как раньше.

st_wd="$(e2e_webdir)"
[[ -n "$st_wd" && -d "$st_wd/web" ]] || { note "нет сайта ${E2E_SITE}: сначала набор hosting"; return; }
st_url="http://${E2E_SITE}/"
st_own="$(stat -c %U:%G "$st_wd/web")"
st_run() { TERM=dumb luckyctl sites </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g'; }
st_php() { printf '%s\n' "$1" >"$st_wd/web/index.php"; chown "$st_own" "$st_wd/web/index.php"; }
# st_wait ШАБЛОН_КОДА [ТЕКСТ] — ждём, пока главная 3 раза подряд отвечает таким кодом (и текстом),
# до 2 минут. Один удачный ответ мало: OPcache перечитывает файл раз в 2 секунды, а кэш файлов
# у каждого процесса nginx свой, и следующий запрос может ещё попасть на старое.
st_wait() {
	local i n=0 r
	sleep 3
	for i in $(seq 1 120); do
		r="$(curl -s -w '|%{http_code}' --max-time 10 -H "Host: ${E2E_SITE}" http://127.0.0.1/)"
		# shellcheck disable=SC2053  # $1 — шаблон кода (200, 5*)
		if [[ "${r##*|}" == $1 && ( -z "${2:-}" || "$r" == *"$2"* ) ]]; then n=$((n + 1)); ((n >= 3)) && return 0
		else n=0; fi
		sleep 1
	done
	return 1
}

for st_f in index.html standard_index.html; do [[ -f "$st_wd/web/$st_f" ]] && mv "$st_wd/web/$st_f" "$st_wd/web/$st_f.e2e"; done
st_php '<?php echo "e2e ok";'
st_wait '200' 'e2e ok' || note "главная не перешла на index.php за 2 минуты"

st_out="$(st_run)"
grep -qF "$st_url" <<<"$st_out" && ok "сайты: luckyctl sites видит ${st_url}" || bad "сайты: ${st_url} нет в luckyctl sites"

# ломаем: ошибка PHP на главной
st_php '<?php e2e_no_such_function();'
st_wait '5*'
st_out="$(st_run)"
grep -F "${st_url}: " <<<"$st_out" | grep -qE '[0-9]{3} → 5[0-9]{2}' && ok "сайты: поломка замечена (→ 5xx)" \
	|| { bad "сайты: поломка не замечена"; sed "s/^/       /" <<<"$st_out" | tail -8; }

# чиним
st_php '<?php echo "e2e ok";'
st_wait '200' 'e2e ok'
st_out="$(st_run)"
grep -F "${st_url}: " <<<"$st_out" | grep -qE '5[0-9]{2} → 200' && ok "сайты: починка замечена (5xx → 200)" \
	|| { bad "сайты: починка не замечена"; sed "s/^/       /" <<<"$st_out" | tail -8; }

# обновление с проверкой сайтов до и после (пункт notify, быстрый)
st_out="$(UPDATE_ITEMS=notify luckyctl update notify </dev/null 2>&1 | sed 's/\x1b\[[0-9;]*m//g')"
grep -q 'отвечают как до обновления' <<<"$st_out" && ok "сайты: обновление проверило сайты до и после" || bad "сайты: проверка сайтов при обновлении"

rm -f "$st_wd/web/index.php"
for st_f in index.html standard_index.html; do [[ -f "$st_wd/web/$st_f.e2e" ]] && mv "$st_wd/web/$st_f.e2e" "$st_wd/web/$st_f"; done
