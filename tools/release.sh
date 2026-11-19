#!/usr/bin/env bash
# =============================================================================
# release.sh X.Y.Z — выпуск LuckyStack.
#
# Перед запуском: изменения в ветке dev, в CHANGELOG.md сверху раздел «## Не выпущено» с ними.
# Скрипт:
#   1. переименует раздел в «## X.Y.Z — дата», ставит VERSION="X.Y.Z", права на запуск,
#      гоняет локальные проверки;
#   2. коммитит «Выпуск X.Y.Z», отправляет dev и ждёт зелёных проверок GitHub Actions;
#   3. переносит dev в main (только перемоткой), ставит тег vX.Y.Z, делает релиз
#      с текстом из CHANGELOG.md;
#   4. собирает архив luckystack-X.Y.Z.tar.gz, SHA256SUMS и подпись SHA256SUMS.sig (ssh-keygen -Y,
#      ключ LUCKYSTACK_SIGN_KEY, по умолчанию ~/.ssh/luckystack-release) и прикладывает к релизу;
#   5. скачивает приложенный архив, проверяет подпись, сумму, версию и права на запуск.
# Ключ --dry-run: только проверки, без коммитов и отправки.
# =============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1

ver="${1:-}"; dry=0; [[ "${2:-}" == "--dry-run" || "${1:-}" == "--dry-run" ]] && dry=1
[[ "${1:-}" == "--dry-run" ]] && ver="${2:-}"
die()  { echo "СТОП: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }

[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "укажите версию: tools/release.sh 0.1.4 [--dry-run]"
command -v gh >/dev/null || die "нужен gh (GitHub CLI)"
key="${LUCKYSTACK_SIGN_KEY:-$HOME/.ssh/luckystack-release}"
[[ -f "$key" ]] || die "нет ключа подписи ${key} (или задайте LUCKYSTACK_SIGN_KEY)"
[[ -s assets/release-signers ]] || die "нет assets/release-signers"
# ключ подходит к открытому ключу из репозитория: подпись пробного файла проверяется им
probe="$(mktemp)"; echo probe >"$probe"
ssh-keygen -Y sign -q -f "$key" -n luckystack-release "$probe" 2>/dev/null \
	&& ssh-keygen -Y verify -f assets/release-signers -I luckystack-release -n luckystack-release -s "$probe.sig" <"$probe" >/dev/null 2>&1 \
	|| { rm -f "$probe" "$probe.sig"; die "ключ ${key} не соответствует assets/release-signers"; }
rm -f "$probe" "$probe.sig"
repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || die "gh не видит репозиторий"

step "Состояние ветки"
[[ "$(git branch --show-current)" == "dev" ]] || die "выпуск делается из ветки dev"
git fetch -q origin || die "git fetch не прошёл"
git rev-parse -q --verify "refs/tags/v${ver}" >/dev/null && die "тег v${ver} уже есть"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] || die "есть незакоммиченные изменения, закоммитьте их сначала"
git merge-base --is-ancestor origin/main HEAD || die "в main есть то, чего нет в dev: сначала влейте main в dev"

step "CHANGELOG"
grep -q '^## Не выпущено$' CHANGELOG.md || die "в CHANGELOG.md нет раздела «## Не выпущено» с изменениями"
notes="$(awk '/^## Не выпущено$/ {f=1; next} /^## /{f=0} f' CHANGELOG.md | sed '/./,$!d')"
[[ -n "${notes//[[:space:]]/}" ]] || die "раздел «## Не выпущено» в CHANGELOG.md пустой"
echo "$notes"
sed -i "s/^## Не выпущено\$/## ${ver} — $(date +%F)/" CHANGELOG.md
git add CHANGELOG.md

step "Версия и права на запуск"
sed -i -E "s/^VERSION=\"[^\"]+\"$/VERSION=\"${ver}\"/" server-setup.sh
grep -q "^VERSION=\"${ver}\"$" server-setup.sh || die "не удалось выставить VERSION"
git update-index --chmod=+x server-setup.sh luckyctl get.sh tools/release.sh tools/e2e.sh 2>/dev/null
git add server-setup.sh

step "Локальные проверки"
for f in server-setup.sh luckyctl get.sh lib/*.sh tests/repo-checks.sh tests/e2e/*.sh tools/*.sh; do bash -n "$f" || die "синтаксис: $f"; done
if command -v shellcheck >/dev/null; then shellcheck -x -S warning server-setup.sh luckyctl get.sh lib/*.sh tests/e2e/*.sh tools/*.sh || die "ShellCheck"
else echo "ShellCheck локально нет, проверит GitHub Actions"; fi
if command -v bats >/dev/null; then LC_ALL=C.UTF-8 bats tests/unit || die "тесты"
else echo "bats локально нет, проверит GitHub Actions"; fi
bash tests/repo-checks.sh || die "проверки репозитория"

if ((dry)); then
	git reset -q -- server-setup.sh CHANGELOG.md 2>/dev/null; git checkout -q -- server-setup.sh CHANGELOG.md 2>/dev/null
	echo; echo "Проверки пройдены (--dry-run, ничего не отправлено)."; exit 0
fi

step "Коммит и отправка dev"
git diff --cached --quiet || git commit -q -m "Выпуск ${ver}" || die "коммит не прошёл"
git push -q origin dev || die "push dev не прошёл"
sha="$(git rev-parse HEAD)"

step "Ждём проверки GitHub Actions для ${sha:0:7}"
run=""
for _ in $(seq 1 30); do
	run="$(gh run list --branch dev --commit "$sha" --json databaseId --jq '.[0].databaseId' 2>/dev/null)"
	[[ -n "$run" ]] && break; sleep 10
done
[[ -n "$run" ]] || die "проверки не запустились, посмотрите вкладку Actions"
gh run watch "$run" --exit-status >/dev/null || die "проверки не прошли: gh run view ${run} --log-failed"
echo "проверки прошли"

step "main ← dev, тег v${ver}, релиз"
git checkout -q main && git merge -q --ff-only dev && git push -q origin main || { git checkout -q dev; die "не удалось перемотать main"; }
git checkout -q dev
git tag -a "v${ver}" -m "LuckyStack ${ver}" "$sha" && git push -q origin "v${ver}" || die "тег не создан"
step "Архив выпуска и подпись"
dist="$(mktemp -d)"; name="luckystack-${ver}.tar.gz"
git -c core.autocrlf=false -c tar.umask=0022 archive --format=tar.gz --prefix="luckystack-${ver}/" -o "$dist/$name" "v${ver}" || die "архив не собран"
(cd "$dist" && sha256sum "$name" >SHA256SUMS) || die "SHA256SUMS не посчитан"
ssh-keygen -Y sign -q -f "$key" -n luckystack-release "$dist/SHA256SUMS" || die "подпись не создана"
ssh-keygen -Y verify -f assets/release-signers -I luckystack-release -n luckystack-release -s "$dist/SHA256SUMS.sig" <"$dist/SHA256SUMS" >/dev/null \
	|| die "свежая подпись не проверяется"
cat "$dist/SHA256SUMS"
printf '%s\n' "$notes" | gh release create "v${ver}" --repo "$repo" --title "LuckyStack ${ver}" --notes-file - \
	"$dist/$name" "$dist/SHA256SUMS" "$dist/SHA256SUMS.sig" >/dev/null || die "релиз не создан"
rm -rf "$dist"

step "Проверка приложенного архива, как его проверит сервер"
tmp="$(mktemp -d)"
for f in "$name" SHA256SUMS SHA256SUMS.sig; do
	curl -fsSL "https://github.com/${repo}/releases/download/v${ver}/${f}" -o "$tmp/$f" || die "${f} не скачался"
done
ssh-keygen -Y verify -f assets/release-signers -I luckystack-release -n luckystack-release -s "$tmp/SHA256SUMS.sig" <"$tmp/SHA256SUMS" >/dev/null \
	|| die "подпись скачанного SHA256SUMS не сходится"
(cd "$tmp" && sha256sum -c --quiet SHA256SUMS) || die "контрольная сумма скачанного архива не совпадает"
listing="$(tar tvzf "$tmp/$name")"
for f in server-setup.sh luckyctl get.sh; do
	grep -qE "^-rwx.* luckystack-${ver}/${f}\$" <<<"$listing" || die "в архиве у ${f} нет права на запуск"
done
tar xzf "$tmp/$name" -C "$tmp" "luckystack-${ver}/server-setup.sh"
grep -q "^VERSION=\"${ver}\"$" "$tmp/luckystack-${ver}/server-setup.sh" || die "в архиве не та версия"
rm -rf "$tmp"
latest="$(gh api "repos/${repo}/releases/latest" --jq .tag_name)"
[[ "$latest" == "v${ver}" ]] || die "последний релиз на GitHub: ${latest}, а не v${ver}"

echo; echo "Готово: https://github.com/${repo}/releases/tag/v${ver}"
