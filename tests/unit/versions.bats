#!/usr/bin/env bats
# Сравнение версий и чтение версии из server-setup.sh (luckyctl version и self-update)

load helpers

setup() { load_libs ui selfupdate; }

@test "0.1.10 новее 0.1.9" {
	_su_newer 0.1.9 0.1.10
}

@test "та же версия не считается новее" {
	run _su_newer 0.1.3 0.1.3
	[ "$status" -ne 0 ]
}

@test "старая версия не считается новее" {
	run _su_newer 0.2.0 0.1.9
	[ "$status" -ne 0 ]
}

@test "версия читается из server-setup.sh" {
	printf '#!/bin/bash\nVERSION="1.2.3"\n' >"${BATS_TEST_TMPDIR}/s.sh"
	[ "$(_su_version_of "${BATS_TEST_TMPDIR}/s.sh")" = "1.2.3" ]
}

@test "в server-setup.sh версия вида X.Y.Z" {
	v="$(_su_version_of "${REPO}/server-setup.sh")"
	[[ "$v" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
}
