#!/usr/bin/env bash
# =============================================================================
# nginx-pins.sh — сверить закреплённые исходники сборки nginx (lib/nginx.sh) с upstream.
#
# Показывает:
#   - git-модули: закреплённый коммит и последний коммит ветки по умолчанию;
#   - архивы с закреплённой версией: последнюю версию проекта и сходится ли сумма из NGX_TAR_SHA256.
# Ключ --sum ИМЯ-ВЕРСИЯ печатает sha256 новой версии (архив скачивается дважды, суммы сверяются),
# например: tools/nginx-pins.sh --sum zlib-ng-2.3.4
# Новые значения переносятся в NGX_GIT_PIN / NGX_TAR_SHA256 и версии в начале lib/nginx.sh руками.
# =============================================================================
set -u
cd "$(dirname "$0")/.." || exit 1

# lib/nginx.sh задаёт версии и таблицы при загрузке, остальное ему для этого не нужно
# shellcheck disable=SC1091
source lib/nginx.sh

# url ИМЯ ВЕРСИЯ — откуда качается архив (как в _nginx_fetch_sources)
url() {
	case "$1" in
		ngx_cache_purge) echo "https://github.com/nginx-modules/ngx_cache_purge/archive/refs/tags/$2.tar.gz" ;;
		ngx_devel_kit) echo "https://github.com/simplresty/ngx_devel_kit/archive/v$2.tar.gz" ;;
		zlib-ng) echo "https://github.com/zlib-ng/zlib-ng/archive/refs/tags/$2.tar.gz" ;;
		ngx_http_geoip2_module) echo "https://github.com/leev/ngx_http_geoip2_module/archive/$2.tar.gz" ;;
		libmaxminddb) echo "https://github.com/maxmind/libmaxminddb/releases/download/$2/libmaxminddb-$2.tar.gz" ;;
	esac
}
repo() {
	case "$1" in
		ngx_cache_purge) echo nginx-modules/ngx_cache_purge ;;
		ngx_devel_kit) echo simplresty/ngx_devel_kit ;;
		zlib-ng) echo zlib-ng/zlib-ng ;;
		ngx_http_geoip2_module) echo leev/ngx_http_geoip2_module ;;
		libmaxminddb) echo maxmind/libmaxminddb ;;
	esac
}
sum2() {   # скачать дважды: GitHub отдаёт архивы тегов одинаковыми, разные суммы — повод не верить
	local a b
	a="$(curl -fsSL "$1" | sha256sum | cut -c1-64)"; b="$(curl -fsSL "$1" | sha256sum | cut -c1-64)"
	[[ "$a" == "$b" && "$a" != e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855 ]] && echo "$a"
}

if [[ "${1:-}" == "--sum" ]]; then
	nv="${2:-}"; n="${nv%-*}"; v="${nv##*-}"
	u="$(url "$n" "$v")"
	[[ -n "$u" ]] || { echo "не знаю, откуда качать ${n}" >&2; exit 1; }
	s="$(sum2 "$u")" || { echo "не скачалось или суммы разошлись: $u" >&2; exit 1; }
	echo "[${nv}]=${s}"
	exit 0
fi

echo "Git-модули (закреплён / последний в upstream):"
declare -A GURL=([ngx_brotli]=google/ngx_brotli [headers-more-nginx-module]=openresty/headers-more-nginx-module
	[zstd-nginx-module]=tokers/zstd-nginx-module [set-misc-nginx-module]=openresty/set-misc-nginx-module
	[nginx-module-vts]=vozlt/nginx-module-vts)
for m in "${!NGX_GIT_PIN[@]}"; do
	head="$(git ls-remote "https://github.com/${GURL[$m]}" HEAD 2>/dev/null | cut -f1)"
	mark="так же"; [[ "$head" == "${NGX_GIT_PIN[$m]}" ]] || mark="ЕСТЬ НОВЕЕ: ${head}"
	printf '  %-28s %s  %s\n' "$m" "${NGX_GIT_PIN[$m]:0:12}" "$mark"
done

echo "Архивы (версия, сумма, последний выпуск):"
for k in "${!NGX_TAR_SHA256[@]}"; do
	n="${k%-*}"; v="${k##*-}"
	s="$(sum2 "$(url "$n" "$v")")"
	[[ "$s" == "${NGX_TAR_SHA256[$k]}" ]] && st="сумма сходится" || st="СУММА НЕ СХОДИТСЯ (${s:-не скачалось})"
	last="$(curl -fsSL "https://api.github.com/repos/$(repo "$n")/releases/latest" 2>/dev/null \
		| grep -m1 -oE '"tag_name": *"[^"]+"' | cut -d'"' -f4 | sed 's/^v//')"
	# у части проектов теги новее «выпусков» (ngx_devel_kit): берём старшую из обоих
	last="$( { echo "$last"; curl -fsSL "https://api.github.com/repos/$(repo "$n")/tags?per_page=100" 2>/dev/null \
		| grep -oE '"name": *"[^"]+"' | cut -d'"' -f4 | sed 's/^v//'; } | grep -E '^[0-9]+(\.[0-9]+)+$' | sort -V | tail -1)"
	printf '  %-36s %s, последний выпуск %s\n' "$k" "$st" "${last:-?}"
done

echo "Версии, которые используются сейчас: zlib-ng ${ZLIBNG_VER}, cache_purge ${CACHEPURGE_VER}, devel_kit ${NGINX_DEV_KIT}, geoip2 ${GEOIP2_VER}, libmaxminddb ${LIBMAXMINDDB_VER}"
for k in "zlib-ng-${ZLIBNG_VER}" "ngx_cache_purge-${CACHEPURGE_VER}" "ngx_devel_kit-${NGINX_DEV_KIT}" \
         "ngx_http_geoip2_module-${GEOIP2_VER}" "libmaxminddb-${LIBMAXMINDDB_VER}"; do
	[[ -n "${NGX_TAR_SHA256[$k]:-}" ]] || echo "  нет суммы для ${k}: tools/nginx-pins.sh --sum ${k}"
done
