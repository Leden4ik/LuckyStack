# Общее для модульных тестов: подключает модули LuckyStack без установщика целиком.
# Вывод (ui_*) и журнал заглушены, всё пишется во временный каталог теста.

REPO="$(cd "$(dirname "${BATS_TEST_FILENAME}")/../.." && pwd)"

load_libs() {
	export SETUP_LOG="${BATS_TEST_TMPDIR}/setup.log"
	export DRY_RUN=0
	: >"$SETUP_LOG"
	local m
	for m in "$@"; do
		# shellcheck disable=SC1090
		source "${REPO}/lib/${m}.sh"
	done
	# заглушки: тесты проверяют результат, а не сообщения
	ui_info() { :; }; ui_warn() { :; }; ui_success() { :; }; ui_error() { :; }
	ui_step() { :; }; log() { :; }
}
