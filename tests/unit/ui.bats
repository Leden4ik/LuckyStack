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

@test "длинная строка рамки переносится по словам, продолжение под текстом пункта" {
	long='  \033[1;33m!\033[0m раз два три четыре пять шесть семь восемь девять десять одиннадцать'
	out="$(UI_WRAP=1 UI_BOX_INNER=30 ui_box_line "$long")"
	plain="$(printf '%s\n' "$out" | sed 's/\x1b\[[0-9;]*m//g')"
	[ "$(wc -l <<<"$plain")" -ge 3 ]
	# все строки одной ширины, рамка ровная
	while IFS= read -r l; do [ "$(printf '%s' "$l" | wc -m)" = "32" ]; done <<<"$plain"
	[[ "$(sed -n 1p <<<"$plain")" == "│   ! раз два"* ]]
	[[ "$(sed -n 2p <<<"$plain")" == "│     "[![:space:]]* ]]
}

@test "без терминала длинная строка не переносится (её читает панель)" {
	long="  ! $(printf 'слово%.0s ' {1..20})"
	out="$(UI_WRAP=auto UI_BOX_INNER=30 ui_box_line "$long" | cat)"
	[ "$(wc -l <<<"$out")" -eq 1 ]
}
