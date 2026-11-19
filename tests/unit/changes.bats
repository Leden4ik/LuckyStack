#!/usr/bin/env bats
# Журнал изменений файлов: новый, изменённый, удалённый файл и вложенные шаги.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs changes
	W="$(mktemp -d)"
	CH_WATCH="$W/etc"
	CH_LOG="$W/changes.log"
	CH_SUMS="$W/sums"
	CH_ANY_USER=1
	mkdir -p "$W/etc/sub"
	echo a >"$W/etc/keep.conf"
	echo b >"$W/etc/sub/old.conf"
	echo c >"$W/etc/edit.conf"
	touch -d '2026-01-01 00:00' "$W/etc/keep.conf" "$W/etc/sub/old.conf" "$W/etc/edit.conf"
}

teardown() { rm -rf "$W"; }

step() {
	echo new >"$W/etc/sub/new.conf"
	echo cc >"$W/etc/edit.conf"
	rm -f "$W/etc/sub/old.conf"
}

@test "шаг: новый, изменённый и удалённый файлы попадают в журнал" {
	ch_run "обновление: тест" step
	run cut -f2- "$CH_LOG"
	[[ "$output" == *$'обновление: тест\t+\t'"$W/etc/sub/new.conf"* ]]
	[[ "$output" == *$'обновление: тест\t~\t'"$W/etc/edit.conf"* ]]
	[[ "$output" == *$'обновление: тест\t-\t'"$W/etc/sub/old.conf"* ]]
	[[ "$output" != *"keep.conf"* ]]
}

@test "код возврата шага сохраняется" {
	run ch_run "падает" false
	[ "$status" -ne 0 ]
}

@test "вложенный шаг не пишет отдельно, всё уходит во внешний" {
	inner() { ch_run "внутренний" step; }
	ch_run "внешний" inner
	run cut -f2 "$CH_LOG"
	[[ "$output" == *"внешний"* ]]
	[[ "$output" != *"внутренний"* ]]
}

@test "шаг без изменений ничего не пишет" {
	ch_run "пусто" true
	[ ! -s "$CH_LOG" ]
}

@test "временные каталоги не считаются" {
	mkdir -p "$W/etc/temp"
	tmpstep() { echo x >"$W/etc/temp/session"; }
	ch_run "temp" tmpstep
	[ ! -s "$CH_LOG" ]
}

@test "файл, переписанный тем же содержимым, не считается изменённым" {
	same() { echo a >"$W/etc/keep.conf"; }
	ch_run "то же" same
	[ ! -s "$CH_LOG" ]
}

@test "кэш сумм: второй снимок не пересчитывает неизменённые файлы" {
	ch_run "первый" true
	[ -s "$CH_SUMS" ]
	grep -q "keep.conf" "$CH_SUMS"
}
