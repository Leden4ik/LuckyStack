#!/usr/bin/env bash
# Установка LuckyStack одной командой:
#
#   curl -fsSL https://raw.githubusercontent.com/Leden4ik/LuckyStack/main/get.sh | sudo bash
#
# Скачивает последний выпуск, проверяет его подпись и контрольную сумму и запускает установщик.
# Если подпись не сходится, ничего не ставится. Конкретная версия: LUCKYSTACK_VERSION=0.1.6.
# Ключи установщика передаются как обычно: ... | sudo bash -s -- --dry-run
set -euo pipefail

REPO="${LUCKYSTACK_REPO:-Leden4ik/LuckyStack}"
API="${LUCKYSTACK_API:-https://api.github.com}"
DL="${LUCKYSTACK_DL:-https://github.com}"
DEST="${LUCKYSTACK_DIR:-/root}"
# Открытый ключ, которым подписаны выпуски (тот же, что в assets/release-signers)
SIGNERS='luckystack-release ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINyMKcUSKFgVOAlsBBneYYlOiVIcq8KINj1bPpV3KSCC'

die() { echo "LuckyStack: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "нужен root: curl -fsSL ... | sudo bash"
for c in curl tar sha256sum ssh-keygen; do
	command -v "$c" >/dev/null 2>&1 || die "нет команды ${c}. Поставьте: apt-get install -y curl tar coreutils openssh-client"
done

ver="${LUCKYSTACK_VERSION:-}"
if [[ -z "$ver" ]]; then
	# ответ сначала целиком в переменную: curl | grep -m1 под pipefail падает, когда grep
	# выходит раньше, чем curl дописал ответ (SIGPIPE)
	json="$(curl -fsSL --max-time 30 "${API}/repos/${REPO}/releases/latest")" || die "не удалось узнать последний выпуск на GitHub"
	ver="$(grep -oE '"tag_name"[[:space:]]*:[[:space:]]*"v[0-9.]+"' <<<"$json" | head -n1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)"
fi
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "непонятная версия: ${ver}"
name="luckystack-${ver}.tar.gz"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "LuckyStack ${ver}: загрузка"
for f in "$name" SHA256SUMS SHA256SUMS.sig; do
	curl -fsSL --max-time 300 -o "$tmp/$f" "${DL}/${REPO}/releases/download/v${ver}/${f}" \
		|| die "не скачался ${f}. У выпусков до 0.1.6 подписи нет, их ставьте по README"
done

echo "$SIGNERS" >"$tmp/signers"
ssh-keygen -Y verify -f "$tmp/signers" -I luckystack-release -n luckystack-release \
	-s "$tmp/SHA256SUMS.sig" <"$tmp/SHA256SUMS" >/dev/null 2>&1 || die "подпись выпуска не сходится, ставить не буду"
want="$(awk -v n="$name" '$2 == n || $2 == "*" n { print $1; exit }' "$tmp/SHA256SUMS")"
got="$(sha256sum "$tmp/$name" | awk '{print $1}')"
[[ -n "$want" && "$want" == "$got" ]] || die "контрольная сумма архива не совпадает, ставить не буду"
echo "LuckyStack ${ver}: подпись и контрольная сумма в порядке"

dir="${DEST}/luckystack-${ver}"
if [[ -e "$dir" ]]; then
	mv "$dir" "${dir}.old-$(date +%Y%m%d-%H%M%S)"
fi
tar xzf "$tmp/$name" -C "$DEST" --no-same-owner --no-same-permissions
[[ -x "$dir/server-setup.sh" ]] || die "в архиве нет ${dir}/server-setup.sh"
echo "LuckyStack ${ver}: распакован в ${dir}"

cd "$dir"
# Мастер задаёт вопросы, а stdin занят скриптом из curl, поэтому берём ввод из терминала
if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then
	exec bash ./server-setup.sh "$@" </dev/tty
fi
echo "Терминала нет, установщик не запущен. Запустите сами: cd ${dir} && bash server-setup.sh"
