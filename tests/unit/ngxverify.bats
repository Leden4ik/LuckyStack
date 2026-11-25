#!/usr/bin/env bats
# Проверка исходников nginx: подписи (gpgv), суммы архивов и закреплённые коммиты git-модулей.

load helpers

setup() {
	export LC_ALL=C.UTF-8
	load_libs nginx
	ui_spin() { shift; "$@"; }
	T="${BATS_TEST_TMPDIR}"
	NGX_BUILD_LOG="$T/build.log"; NGX_RETRY_SLEEP=0
	NGX_KEYS_DIR="$T/keys"; mkdir -p "$NGX_KEYS_DIR"
	# wget в тестах берёт файл с диска: URL = путь
	wget() {
		local out="" url=""
		while (($#)); do
			case "$1" in -O) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
		done
		[[ -f "$url" ]] && cp "$url" "$out"
	}
}

# ключ для подписи и связка с ним; второй ключ — «чужой»
mkkeys() {
	command -v gpg >/dev/null || skip "нет gpg"
	export GNUPGHOME="$T/gh"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
	gpg -q --batch --passphrase '' --quick-gen-key "good@example.org" ed25519 sign never 2>/dev/null
	gpg -q --batch --passphrase '' --quick-gen-key "other@example.org" ed25519 sign never 2>/dev/null
	gpg -q --export good@example.org >"$NGX_KEYS_DIR/good.gpg"
	gpg -q --export other@example.org >"$NGX_KEYS_DIR/other.gpg"
	echo "исходник" | gzip >"$T/src.tar.gz"
	gpg -q --batch --pinentry-mode loopback --passphrase '' -u good@example.org --armor --detach-sign -o "$T/src.tar.gz.asc" "$T/src.tar.gz"
}

@test "подпись правильным ключом принимается" {
	mkkeys
	_ngx_verify "$T/src.tar.gz" "$T/src.tar.gz" gpg:good "src"
}

@test "изменённый архив с прежней подписью отвергается" {
	mkkeys
	echo x >>"$T/src.tar.gz"
	run _ngx_verify "$T/src.tar.gz" "$T/src.tar.gz" gpg:good "src"
	[ "$status" -ne 0 ]
}

@test "подпись чужим ключом отвергается" {
	mkkeys
	run _ngx_verify "$T/src.tar.gz" "$T/src.tar.gz" gpg:other "src"
	[ "$status" -ne 0 ]
}

@test "нет подписи или нет связки ключей: отказ" {
	mkkeys
	rm -f "$T/src.tar.gz.asc"
	run _ngx_verify "$T/src.tar.gz" "$T/src.tar.gz" gpg:good "src"
	[ "$status" -ne 0 ]
	run _ngx_verify "$T/src.tar.gz" "$T/src.tar.gz" gpg:nokeys "src"
	[ "$status" -ne 0 ]
}

@test "подпись с другим расширением (.sig, как у PCRE2)" {
	mkkeys
	mv "$T/src.tar.gz.asc" "$T/src.tar.gz.sig"
	_ngx_verify "$T/src.tar.gz" "$T/src.tar.gz" gpg:good:.sig "src"
}

@test "NGX_VERIFY_SIG=n пропускает проверку подписи" {
	NGX_VERIFY_SIG=n
	echo x >"$T/a"
	_ngx_verify "$T/a" "$T/a" gpg:none "a"
}

@test "сумма: совпала, не совпала, не известна" {
	echo данные >"$T/a"
	s="$(sha256sum "$T/a" | cut -d' ' -f1)"
	_ngx_verify "$T/a" "" "sha256:$s" "a"
	run _ngx_verify "$T/a" "" "sha256:${s/?/0}" "a"
	[ "$status" -ne 0 ]
	_ngx_verify "$T/a" "" nosum "a"
}

@test "_ngx_tar_check: сумма для известной версии, nosum для изменённой" {
	[ "$(_ngx_tar_check zlib-ng-2.3.3)" = "sha256:${NGX_TAR_SHA256[zlib-ng-2.3.3]}" ]
	[ "$(_ngx_tar_check zlib-ng-9.9.9)" = nosum ]
}

@test "в репозитории лежат настоящие ключи nginx, OpenSSL и PCRE2" {
	command -v gpg >/dev/null || skip "нет gpg"
	export GNUPGHOME="$T/gh2"; mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"
	gpg --show-keys --with-colons "$REPO/assets/keys/nginx.gpg" | grep -q D6786CE303D9A9022998DC6CC8464D549AF75C0A
	gpg --show-keys --with-colons "$REPO/assets/keys/openssl.gpg" | grep -q B146647E45A7B33947AB226B2A2C87D161692D40
	gpg --show-keys --with-colons "$REPO/assets/keys/pcre2.gpg" | grep -q A95536204A3BB489715231282A98E77EB6F24CA8
}

# git-модуль: исходный репозиторий с двумя коммитами, закреплён первый
mkrepo() {
	R="$T/upstream"; mkdir -p "$R"
	git -C "$R" init -q
	git -C "$R" config uploadpack.allowAnySHA1InWant true
	echo 1 >"$R/f"; git -C "$R" add f; git -C "$R" -c user.name=t -c user.email=t@t commit -qm one
	P1="$(git -C "$R" rev-parse HEAD)"
	echo 2 >"$R/f"; git -C "$R" -c user.name=t -c user.email=t@t commit -qam two
	NGX_GIT_PIN[testmod]="$P1"
}

@test "модуль ставится на закреплённый коммит, а не на последний" {
	mkrepo
	_ngx_clone "file://$R" "$T/mod/testmod"
	[ "$(git -C "$T/mod/testmod" rev-parse HEAD)" = "$P1" ]
	[ "$(cat "$T/mod/testmod/f")" = 1 ]
}

@test "модуль без закреплённого коммита не собирается" {
	mkrepo
	run _ngx_clone "file://$R" "$T/mod/unknownmod"
	[ "$status" -ne 0 ]
}

@test "закреплённого коммита нет в upstream: отказ, если модуля ещё нет" {
	mkrepo
	NGX_GIT_PIN[testmod]=0123456789012345678901234567890123456789
	run _ngx_clone "file://$R" "$T/mod/testmod"
	[ "$status" -ne 0 ]
}

@test "upstream недоступен, модуль с прошлой сборки есть: собираем с ним" {
	mkrepo
	_ngx_clone "file://$R" "$T/mod/testmod"
	NGX_GIT_PIN[testmod]=0123456789012345678901234567890123456789
	_ngx_clone "file://$T/nowhere" "$T/mod/testmod"
	[ "$(git -C "$T/mod/testmod" rev-parse HEAD)" = "$P1" ]
}
