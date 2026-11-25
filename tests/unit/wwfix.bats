#!/usr/bin/env bats
# luckyctl fix-world-writable: снимает запись для всех, сохраняет прежние права, откатывается.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs layout security
	D="${BATS_TEST_TMPDIR}/scan"; mkdir -p "$D/sub"
	WW_SCAN_PATHS="$D"; WW_BACKUP_DIR="${BATS_TEST_TMPDIR}/bk"; WW_REPORT="${BATS_TEST_TMPDIR}/report.txt"
	echo a >"$D/a.txt"; echo b >"$D/sub/с пробелом.txt"; echo c >"$D/ok.txt"
	chmod 666 "$D/a.txt" "$D/sub/с пробелом.txt"; chmod 644 "$D/ok.txt"
	echo "$D/a.txt" >"$WW_REPORT"
}

@test "запись для всех снимается, прежние права сохраняются, отчёт очищается" {
	run_ww_fix
	[ "$(stat -c %a "$D/a.txt")" = 664 ]
	[ "$(stat -c %a "$D/sub/с пробелом.txt")" = 664 ]
	[ "$(stat -c %a "$D/ok.txt")" = 644 ]
	bk="$(ls "$WW_BACKUP_DIR"/world-writable-*.txt)"
	grep -qx "666 $D/a.txt" "$bk"
	grep -qx "666 $D/sub/с пробелом.txt" "$bk"
	! grep -q ok.txt "$bk"
	[ ! -s "$WW_REPORT" ]
}

@test "откат возвращает прежние права, в том числе для имени с пробелом" {
	run_ww_fix
	bk="$(ls "$WW_BACKUP_DIR"/world-writable-*.txt)"
	run_ww_fix "$bk"
	[ "$(stat -c %a "$D/a.txt")" = 666 ]
	[ "$(stat -c %a "$D/sub/с пробелом.txt")" = 666 ]
}

@test "таких файлов нет: ничего не меняется, копия не создаётся" {
	chmod 644 "$D/a.txt" "$D/sub/с пробелом.txt"
	run_ww_fix
	[ ! -d "$WW_BACKUP_DIR" ] || [ -z "$(ls -A "$WW_BACKUP_DIR")" ]
}
