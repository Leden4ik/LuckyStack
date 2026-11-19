#!/usr/bin/env bats
# Есть ли в /etc/hosts строка с полным и коротким именем (иначе hostname -f не работает)

load helpers

setup() {
	load_libs ui preflight
	H="${BATS_TEST_TMPDIR}/hosts"
}

@test "правильная строка находится" {
	printf '127.0.0.1 localhost\n203.0.113.10 srv.example.net srv\n' >"$H"
	_hosts_has_pair srv.example.net srv "$H"
}

@test "шаблон хостера с чужим коротким именем не подходит" {
	printf '127.0.1.1 srv.example.net\n203.0.113.10 srv.example.net rv\n' >"$H"
	run _hosts_has_pair srv.example.net srv "$H"
	[ "$status" -ne 0 ]
}

@test "закомментированная строка не считается" {
	printf '# 203.0.113.10 srv.example.net srv\n' >"$H"
	run _hosts_has_pair srv.example.net srv "$H"
	[ "$status" -ne 0 ]
}

@test "порядок имён в строке не важен" {
	printf '203.0.113.10 srv srv.example.net\n' >"$H"
	_hosts_has_pair srv.example.net srv "$H"
}
