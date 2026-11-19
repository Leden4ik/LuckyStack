#!/usr/bin/env bash
# Проверки репозитория перед выпуском (и в GitHub Actions на каждую отправку):
#   права на запуск, версия и CHANGELOG, тег = версия, переводы строк, лицензия.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
bad() { echo "ОШИБКА: $*"; fail=1; }
ok()  { echo "ок: $*"; }

# 1. Права на запуск хранятся в Git (на Windows их легко потерять, так вышел битый 0.1.0)
for f in server-setup.sh luckyctl; do
	mode="$(git ls-files -s -- "$f" | awk '{print $1}')"
	[[ "$mode" == "100755" ]] && ok "$f исполняемый" || bad "$f без права на запуск (режим ${mode:-нет в Git}): git update-index --chmod=+x $f"
done

# 2. Версия в коде и верхняя запись CHANGELOG совпадают
ver="$(grep -m1 -oE '^VERSION="[^"]+"' server-setup.sh | cut -d'"' -f2)"
top="$(grep -m1 -oE '^## [0-9]+\.[0-9]+\.[0-9]+' CHANGELOG.md | cut -c4-)"
[[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && ok "версия ${ver}" || bad "VERSION в server-setup.sh не вида X.Y.Z: ${ver:-пусто}"
[[ "$ver" == "$top" ]] && ok "CHANGELOG начинается с ${top}" || bad "VERSION=${ver}, а верхняя запись CHANGELOG.md: ${top:-нет}"

# 3. Если проверяется тег, он обязан совпадать с версией
if [[ "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
	[[ "${GITHUB_REF_NAME:-}" == "v${ver}" ]] && ok "тег ${GITHUB_REF_NAME}" || bad "тег ${GITHUB_REF_NAME:-?}, а версия в коде ${ver}"
fi

# 4. Никаких CRLF в текстовых файлах (скрипты с CR не запустятся на сервере)
crlf="$(git ls-files -z | perl -0 -ne 'chomp; next unless -f $_ && -T $_; open my $h, "<:raw", $_ or next; local $/; my $c = <$h>; print "$_\n" if $c =~ /\r/' | head -5)"
[[ -z "$crlf" ]] && ok "переводы строк LF" || bad "файлы с CRLF: ${crlf//$'\n'/ }"

# 5. Лицензия на месте
[[ -s LICENSE ]] && grep -q 'MIT License' LICENSE && ok "LICENSE (MIT)" || bad "нет LICENSE или это не MIT"

exit "$fail"
