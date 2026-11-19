#!/usr/bin/env bats
# Подпись выпусков: _su_verify пропускает только архив с верной подписью и суммой.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs selfupdate
	W="$(mktemp -d)"
	ssh-keygen -q -t ed25519 -N "" -C luckystack-release -f "$W/key"
	echo "luckystack-release $(cut -d' ' -f1,2 "$W/key.pub")" >"$W/signers"
	mkdir "$W/d"
	echo "архив" >"$W/d/luckystack-9.9.9.tar.gz"
	(cd "$W/d" && sha256sum luckystack-9.9.9.tar.gz >SHA256SUMS)
	ssh-keygen -Y sign -q -f "$W/key" -n luckystack-release "$W/d/SHA256SUMS"
}

teardown() { rm -rf "$W"; }

@test "верная подпись и сумма проходят" {
	_su_verify "$W/d" "$W/signers" luckystack-9.9.9.tar.gz
}

@test "подменённый архив не проходит" {
	echo "чужое" >"$W/d/luckystack-9.9.9.tar.gz"
	run _su_verify "$W/d" "$W/signers" luckystack-9.9.9.tar.gz
	[ "$status" -ne 0 ]
	_su_verify "$W/d" "$W/signers" luckystack-9.9.9.tar.gz || [[ "$_SU_ERR" == *"контрольная сумма"* ]]
}

@test "подменённый SHA256SUMS не проходит" {
	echo "0000  luckystack-9.9.9.tar.gz" >"$W/d/SHA256SUMS"
	run _su_verify "$W/d" "$W/signers" luckystack-9.9.9.tar.gz
	[ "$status" -ne 0 ]
}

@test "подпись чужим ключом не проходит" {
	ssh-keygen -q -t ed25519 -N "" -C other -f "$W/other"
	rm -f "$W/d/SHA256SUMS.sig"
	ssh-keygen -Y sign -q -f "$W/other" -n luckystack-release "$W/d/SHA256SUMS"
	run _su_verify "$W/d" "$W/signers" luckystack-9.9.9.tar.gz
	[ "$status" -ne 0 ]
}

@test "без файла ключей не проходит" {
	run _su_verify "$W/d" "$W/нет" luckystack-9.9.9.tar.gz
	[ "$status" -ne 0 ]
}

@test "ключ выпусков в репозитории в правильном формате" {
	run cat "$REPO/assets/release-signers"
	[[ "$output" =~ ^luckystack-release\ ssh-ed25519\ [A-Za-z0-9+/=]+$ ]]
}
