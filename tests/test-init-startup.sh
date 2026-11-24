#!/bin/sh
# Тест: наши init-скрипты обязаны реально запускаться при загрузке.
#
# Дефект, который закрывает тест.
#
# В OpenWrt файл /etc/rc.common вызывает у init-скрипта функцию start(),
# а start_service() - ТОЛЬКО если скрипт объявил USE_PROCD=1. Без этого
# флага rc.common выполняет собственный start() { return 0; } и функция
# start_service() нашего скрипта НИКОГДА не вызывается.
#
# Наши скрипты (40-pejir-sms, 41-pejir-modem, 41-pejir-sync, 47-pejir-lte)
# определяли start_service(), но USE_PROCD=1 не объявляли. Итог: при
# загрузке они молча ничего не делали - ни писинга в журнал, ни записи
# smsd.conf, ни определения AT-порта, ни очистки верхнего слоя.
#
# Тест проверяет ПОВЕДЕНИЕ на настоящем rc.common из дерева OpenWrt:
#   * скрипт со своим start()      - функция вызывается;
#   * скрипт с одним start_service() - функция НЕ вызывается (дефект);
#   * скрипт с USE_PROCD=1         - start_service() вызывается.
# И ПРОВЕРЯЕТ наши реальные init-скрипты: у каждого обязан быть
# рабочий способ запуска.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет $DEFAULT_TREE (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

# Настоящий rc.common из дерева OpenWrt - эталон поведения.
RC_COMMON="$TREE/package/base-files/files/etc/rc.common"
[ -f "$RC_COMMON" ] || { echo "FAIL: нет $RC_COMMON"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/etc/init.d" "$WORK/lib/functions"
cp "$RC_COMMON" "$WORK/etc/rc.common"

# rc.common подключает functions.sh и functions/service.sh. Копируем
# настоящие из дерева: заглушка сломала бы list_contains, и rc.common
# откатился бы на action=help вместо реального запуска.
for f in functions.sh functions/service.sh; do
	src="$TREE/package/base-files/files/lib/$f"
	[ -f "$src" ] || { echo "FAIL: нет $src"; exit 1; }
	mkdir -p "$WORK/lib/$(dirname "$f")"
	cp "$src" "$WORK/lib/$f"
done

# Заглушка procd.sh: USE_PROCD=1 требует procd_open_service/procd_close_service.
cat > "$WORK/lib/functions/procd.sh" <<'PEOF'
procd_open_service() { :; }
procd_close_service() { :; }
procd_lock() { :; }
procd_kill() { :; }
PEOF

# --- helper: собирает стенд и запускает скрипт через rc.common -----------
# $1 - тело скрипта. Печатает то, что напечатал вызванный обработчик.
run_case() {
	cat > "$WORK/etc/init.d/case" <<EOF
#!/bin/sh /etc/rc.common
START=50
STOP=0
$1
EOF
	chmod 755 "$WORK/etc/init.d/case"

	IPKG_INSTROOT="$WORK" sh "$WORK/etc/rc.common" "$WORK/etc/init.d/case" start 2>/dev/null
}

# --- 1) Свой start() - обработчик вызывается ----------------------------
OUT="$(run_case 'start() {
	echo "ВЫЗВАН"
}')"
if [ "$OUT" = "ВЫЗВАН" ]; then
	ok "собственный start() вызывается rc.common"
else
	fail "собственный start() НЕ вызван rc.common - стенд неверен, тест бессмысленен"
fi

# --- 2) Только start_service() без USE_PROCD - обработчик НЕ вызывается --
OUT="$(run_case 'start_service() {
	echo "ВЫЗВАН"
}')"
if [ "$OUT" = "ВЫЗВАН" ]; then
	fail "start_service() вызван без USE_PROCD - поведение rc.common изменилось, тест бессмысленен"
else
	ok "start_service() без USE_PROCD не вызывается (дефект подтверждён)"
fi

# --- 3) USE_PROCD=1 - start_service() вызывается -------------------------
OUT="$(run_case 'USE_PROCD=1
start_service() {
	echo "ВЫЗВАН"
}')"
if [ "$OUT" = "ВЫЗВАН" ]; then
	ok "с USE_PROCD=1 start_service() вызывается"
else
	fail "с USE_PROCD=1 start_service() НЕ вызвалась (стенд неверен)"
fi

# --- 4) Наши реальные скрипты: рабочий способ запуска -------------------
# Скрипт, который определяет start_service(), обязан либо объявлять
# USE_PROCD=1, либо определять собственный start(), который её зовёт.
# Иначе он не выполняется при загрузке.
check_init_script() {
	path="$1"
	name="$(basename "$path")"

	[ -f "$path" ] || { fail "нет файла $path"; return 0; }

	# Определяет ли скрипт start_service()?
	if ! grep -q '^[[:space:]]*start_service[[:space:]]*()' "$path"; then
		ok "$name не использует start_service() - проверка не нужна"
		return 0
	fi

	if grep -q '^[[:space:]]*USE_PROCD=1' "$path"; then
		ok "$name объявляет USE_PROCD=1"
		return 0
	fi

	# Свой start() обязан звать start_service.
	if grep -q '^[[:space:]]*start[[:space:]]*()' "$path"; then
		if grep -A6 '^[[:space:]]*start[[:space:]]*()' "$path" | grep -q 'start_service'; then
			ok "$name определяет start(), зовущий start_service()"
			return 0
		fi
		fail "$name определяет start(), но он НЕ зовёт start_service()"
		return 0
	fi

	fail "$name определяет start_service(), но ни USE_PROCD=1, ни start() - скрипт молчит при загрузке"
}

for p in \
	"$TREE/package/pejir-sms/root/etc/init.d/40-pejir-sms" \
	"$TREE/package/pejir-lte-base/root/etc/init.d/41-pejir-modem" \
	"$TREE/package/pejir-lte-base/root/etc/init.d/47-pejir-lte" \
	"$TREE/package/pejir-sync/root/etc/init.d/41-pejir-sync"
do
	check_init_script "$p"
done

# --- 5) В дереве не должно остаться наших скриптов без запуска ---------
LEFT=0
for p in "$TREE"/package/*/root/etc/init.d/*pejir*; do
	[ -f "$p" ] || continue
	grep -q '^[[:space:]]*start_service[[:space:]]*()' "$p" || continue
	grep -q '^[[:space:]]*USE_PROCD=1' "$p" && continue
	if grep -A6 '^[[:space:]]*start[[:space:]]*()' "$p" | grep -q 'start_service'; then
		continue
	fi
	echo "FAIL: $p - start_service() без USE_PROCD=1 и без рабочего start()"
	LEFT=$((LEFT+1))
done
if [ "$LEFT" -eq 0 ]; then
	ok "все наши init-скрипты имеют рабочий способ запуска"
else
	FAILED=$((FAILED+LEFT))
fi

if [ "$FAILED" -gt 0 ]; then
	echo "провалено проверок: $FAILED"
	exit 1
fi
echo "все проверки пройдены"
exit 0
