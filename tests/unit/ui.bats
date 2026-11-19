#!/usr/bin/env bats
# Видимая длина строки для рамок: цвета не считаются, кириллица — по символам

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs ui
}

@test "цвет текстом \\033[...m не считается" {
	s='\033[0;90m[ ]\033[0m \033[0;32m 1)\033[0m PHP 8.5'
	[ "$(ui_vislen "$s")" = "15" ]
}

@test "настоящий ESC тоже не считается" {
	s="$(printf '\033[0;32mok\033[0m')"
	[ "$(ui_vislen "$s")" = "2" ]
}

@test "кириллица считается по символам" {
	[ "$(ui_vislen 'Готово')" = "6" ]
}

@test "строка рамки дополняется до ширины" {
	out="$(UI_BOX_INNER=40 ui_box_line '\033[0;32m1)\033[0m stable')"
	plain="$(printf '%s' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
	[ "$(printf '%s' "$plain" | wc -m)" = "42" ]
}
