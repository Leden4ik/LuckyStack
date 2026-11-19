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
#   4. скачивает архив релиза и проверяет в нём версию и права на запуск.
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
git update-index --chmod=+x server-setup.sh luckyctl tools/release.sh 2>/dev/null
git add server-setup.sh

step "Локальные проверки"
for f in server-setup.sh luckyctl lib/*.sh tests/repo-checks.sh tests/e2e/*.sh tools/*.sh; do bash -n "$f" || die "синтаксис: $f"; done
if command -v shellcheck >/dev/null; then shellcheck -x -S warning server-setup.sh luckyctl lib/*.sh tests/e2e/*.sh tools/*.sh || die "ShellCheck"
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
printf '%s\n' "$notes" | gh release create "v${ver}" --repo "$repo" --title "LuckyStack ${ver}" --notes-file - >/dev/null || die "релиз не создан"

step "Проверка архива релиза"
tmp="$(mktemp -d)"
curl -fsSL "https://github.com/${repo}/archive/refs/tags/v${ver}.tar.gz" -o "$tmp/r.tgz" || die "архив не скачался"
listing="$(tar tvzf "$tmp/r.tgz")"
for f in server-setup.sh luckyctl; do
	grep -qE "^-rwx.* [^/]+/${f}\$" <<<"$listing" || die "в архиве у ${f} нет права на запуск"
done
tar xzf "$tmp/r.tgz" -C "$tmp" --wildcards '*/server-setup.sh'
grep -q "^VERSION=\"${ver}\"$" "$tmp"/*/server-setup.sh || die "в архиве не та версия"
rm -rf "$tmp"
latest="$(gh api "repos/${repo}/releases/latest" --jq .tag_name)"
[[ "$latest" == "v${ver}" ]] || die "последний релиз на GitHub: ${latest}, а не v${ver}"

echo; echo "Готово: https://github.com/${repo}/releases/tag/v${ver}"
