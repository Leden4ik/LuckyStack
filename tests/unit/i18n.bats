#!/usr/bin/env bats
# Перевод интерфейса: точные строки, шаблоны с %s, оформление в начале строки.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs i18n
	LANG_DIR="${BATS_TEST_TMPDIR}/lang"; mkdir -p "$LANG_DIR"
	cat >"$LANG_DIR/en.lng" <<'EOF'
_I18N["Готово"]="Done"
_I18N["Обновлён nginx до %s"]="nginx updated to %s"
_I18N["Обновлён %s"]="%s updated"
_I18N["Сайты и панель отвечают как до обновления (адресов: %s)."]="Sites and the panel respond as before the update (addresses: %s)."
_I18N["Roundcube %s, вышел %s: luckyctl update security"]="Roundcube %s, %s is out: luckyctl update security"
_I18N["порт %s (web) слушается"]="port %s (web) is listening"
EOF
	i18n_load en
}

@test "точная строка" {
	[ "$(t 'Готово')" = "Done" ]
}

@test "шаблон с одним значением, точки и скобки в ключе не ломают выражение" {
	[ "$(t 'Обновлён nginx до 1.30.8')" = "nginx updated to 1.30.8" ]
	[ "$(t 'Сайты и панель отвечают как до обновления (адресов: 49).')" = "Sites and the panel respond as before the update (addresses: 49)." ]
}

@test "длинное начало шаблона важнее короткого" {
	[ "$(t 'Обновлён nginx до 1.31.10')" = "nginx updated to 1.31.10" ]
	[ "$(t 'Обновлён Roundcube')" = "Roundcube updated" ]
}

@test "два значения подставляются по порядку" {
	[ "$(t 'Roundcube 1.6.21, вышел 1.6.22: luckyctl update security')" = "Roundcube 1.6.21, 1.6.22 is out: luckyctl update security" ]
}

@test "отступ, цвет и значок в начале строки сохраняются" {
	s='  \033[0;32m✓\033[0m порт 443 (web) слушается'
	[ "$(t "$s")" = '  \033[0;32m✓\033[0m port 443 (web) is listening' ]
}

@test "непереведённое остаётся как есть, русский ничего не меняет" {
	[ "$(t 'Такой строки нет')" = "Такой строки нет" ]
	i18n_load ru
	[ "$(t 'Готово')" = "Готово" ]
}
