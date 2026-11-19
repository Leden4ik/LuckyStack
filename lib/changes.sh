#!/usr/bin/env bash
# =============================================================================
# changes.sh — журнал изменений файлов: что поменял каждый шаг установщика.
#
# Перед шагом (этап установки, пункт обновления, add-php и т. п.) снимаем список файлов в
# каталогах настроек: путь, время изменения, размер. После шага сравниваем и пишем в
# /var/log/luckystack/changes.log строки «время<TAB>шаг<TAB>знак<TAB>путь»:
# + новый файл, ~ изменён, - удалён. Модули ничего про журнал не знают.
#
# luckyctl changes [N]       последние N шагов с изменёнными файлами (по умолчанию 10)
# luckyctl changes ПУТЬ      история одного файла
# =============================================================================

: "${CH_LOG:=${LS_LOG_DIR:-/var/log/luckystack}/changes.log}"
CH_WATCH="${CH_WATCH:-/etc /usr/local/ispconfig/server/conf-custom /usr/local/ispconfig/server/plugins-available \
/usr/local/ispconfig/server/plugins-enabled /usr/local/ispconfig/server/mods-available /usr/local/ispconfig/server/mods-enabled \
/usr/local/ispconfig/server/lib /usr/local/ispconfig/interface/lib /usr/local/ispconfig/interface/web \
/usr/local/sbin /usr/local/bin /opt/roundcube/config /opt/roundcube/plugins /var/spool/cron/crontabs}"
CH_MAX_BYTES="${CH_MAX_BYTES:-10485760}"
# Кэш контрольных сумм: путь, время, размер, md5. Сумма пересчитывается, только если у файла
# поменялись время или размер, поэтому снимок до и после шага почти ничего не стоит.
: "${CH_SUMS:=${LS_VAR_DIR:-/var/lib/luckystack}/changes.sums}"
CH_SNAP=""
CH_LABEL=""

# Список файлов: путь<TAB>время<TAB>размер. Служебное и временное не берём.
_ch_list() {
	local d dirs=()
	for d in $CH_WATCH; do [[ -e "$d" ]] && dirs+=("$d"); done
	((${#dirs[@]})) || return 0
	find "${dirs[@]}" -xdev \( -path '*/temp' -o -path '*/cache' -o -path '*/.git' \) -prune -o \
		-type f ! -name '*.swp' ! -path /etc/ld.so.cache ! -path /etc/mtab ! -path /etc/adjtime \
		! -path /etc/.pwd.lock ! -path '/etc/luckystack/*.lock' -printf '%p\t%T@\t%s\n' 2>/dev/null | LC_ALL=C sort
}

# _ch_snapshot файл — снимок «путь<TAB>время<TAB>размер<TAB>md5», заодно обновляет кэш
_ch_snapshot() {
	local out="$1" list need sums
	list="$(mktemp "${TMPDIR:-/tmp}/luckystack-ch.XXXXXX")" || return 1
	need="$list.need"; sums="$list.sums"
	_ch_list >"$list"
	[[ -f "$CH_SUMS" ]] || { mkdir -p "$(dirname "$CH_SUMS")" 2>/dev/null; : >"$CH_SUMS"; }
	: >"$need"
	LC_ALL=C join -t $'\t' -a1 -e '' -o 0,1.2,1.3,2.2,2.3,2.4 "$list" "$CH_SUMS" 2>/dev/null \
		| awk -F'\t' -v need="$need" '
			$6 != "" && $2 == $4 && $3 == $5 { print $1 "\t" $2 "\t" $3 "\t" $6; next }
			{ print $1 "\t" $2 "\t" $3 > need }' >"$sums"
	if [[ -s "$need" ]]; then
		# md5sum печатает «сумма␠␠путь»; путь с особыми символами он начинает с «\», такие пропускаем
		cut -f1 "$need" | tr '\n' '\0' | xargs -0 -r md5sum 2>/dev/null \
			| awk 'substr($0, 1, 1) == "\\" { next } { print substr($0, 35) "\t" $1 }' | LC_ALL=C sort >"$need.md5"
		LC_ALL=C join -t $'\t' -o 0,1.2,1.3,2.2 "$need" "$need.md5" >>"$sums"
	fi
	LC_ALL=C sort -o "$out" "$sums"
	cp -f "$out" "$CH_SUMS.tmp" 2>/dev/null && chmod 600 "$CH_SUMS.tmp" && mv -f "$CH_SUMS.tmp" "$CH_SUMS"
	rm -f "$list" "$need" "$need.md5" "$sums"
}

# ch_begin "подпись шага" — снимок до шага. Вложенный вызов игнорируется (пишет внешний шаг).
ch_begin() {
	[[ ($EUID -eq 0 || "${CH_ANY_USER:-0}" == 1) && "${DRY_RUN:-0}" != "1" && -z "$CH_SNAP" ]] || return 0
	CH_SNAP="$(mktemp "${TMPDIR:-/tmp}/luckystack-ch.XXXXXX" 2>/dev/null)" || { CH_SNAP=""; return 0; }
	CH_LABEL="$1"
	_ch_snapshot "$CH_SNAP" || { rm -f "$CH_SNAP"; CH_SNAP=""; }
}

# ch_end — сравнить со снимком и дописать журнал
ch_end() {
	[[ -n "$CH_SNAP" && -f "$CH_SNAP" ]] || { CH_SNAP=""; return 0; }
	local after now
	after="$(mktemp "${TMPDIR:-/tmp}/luckystack-ch.XXXXXX" 2>/dev/null)" || { rm -f "$CH_SNAP"; CH_SNAP=""; return 0; }
	_ch_snapshot "$after"
	now="$(date '+%F %T')"
	mkdir -p "$(dirname "$CH_LOG")" 2>/dev/null
	# по пути: только в «до» → удалён, только в «после» → новый, другая сумма → изменён.
	# Файл, переписанный тем же содержимым, изменением не считается.
	LC_ALL=C join -t $'\t' -a1 -a2 -e '' -o 0,1.4,2.4 "$CH_SNAP" "$after" 2>/dev/null \
		| awk -F'\t' -v t="$now" -v s="$CH_LABEL" '
			$2 == "" { print t "\t" s "\t+\t" $1; next }
			$3 == "" { print t "\t" s "\t-\t" $1; next }
			$2 != $3 { print t "\t" s "\t~\t" $1 }' >>"$CH_LOG"
	chmod 600 "$CH_LOG" 2>/dev/null
	rm -f "$CH_SNAP" "$after"
	CH_SNAP=""
	# журнал не растёт бесконечно: оставляем последние 50 тысяч строк
	if [[ "$(stat -c %s "$CH_LOG" 2>/dev/null || echo 0)" -gt "$CH_MAX_BYTES" ]]; then
		tail -n 50000 "$CH_LOG" >"$CH_LOG.tmp" && mv -f "$CH_LOG.tmp" "$CH_LOG"
	fi
	return 0
}

# ch_run "подпись" команда… — выполнить команду с записью изменений, код возврата сохраняется
ch_run() {
	local label="$1" rc=0; shift
	ch_begin "$label"
	"$@" || rc=$?
	ch_end
	return "$rc"
}

# luckyctl changes [N | ПУТЬ]
run_changes() {
	local arg="${1:-10}"
	[[ -s "$CH_LOG" ]] || { ui_info "Журнал изменений пуст: ${CH_LOG}"; return 0; }
	if [[ "$arg" == /* ]]; then
		ui_header "История файла ${arg}"
		awk -F'\t' -v p="$arg" '$4 == p { print "  " $1 "  " $3 "  " $2 }' "$CH_LOG" | tail -n 50
		return 0
	fi
	[[ "$arg" =~ ^[0-9]+$ ]] || { ui_error "luckyctl changes [число шагов | /путь/к/файлу]"; return 2; }
	ui_header "Изменения файлов: последние шаги"
	# шаг = время + подпись; печатаем последние N шагов, у каждого не больше 25 файлов
	awk -F'\t' -v n="$arg" '
		{ k = $1 "\t" $2; if (!(k in seen)) { seen[k] = ++cnt; key[cnt] = k } c = seen[k]; total[c]++
		  if (total[c] <= 25) lines[c] = lines[c] "    " $3 " " $4 "\n" }
		END {
			for (i = (cnt > n ? cnt - n + 1 : 1); i <= cnt; i++) {
				split(key[i], a, "\t")
				printf "%s  %s  (файлов: %d)\n%s", a[1], a[2], total[i], lines[i]
				if (total[i] > 25) printf "    … и ещё %d\n", total[i] - 25
			}
		}' "$CH_LOG"
	echo
	ui_info "+ новый, ~ изменён, - удалён. История одного файла: luckyctl changes /путь/к/файлу. Журнал: ${CH_LOG}"
	return 0
}
