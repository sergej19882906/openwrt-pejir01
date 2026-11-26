#!/bin/sh
# Тест управления модемом: SIM PIN, номер SIM, перезагрузка, режим канала
# (патч 0092).
#
# ФАКТ (стоковая прошивка Perenio 9.0.4):
#   * статус SIM PIN - AT+CPIN?            (common.sh, get_pin_status)
#   * состояние блокировки - AT+CLCK="SC",2 (common.sh, get_lock_status)
#   * ввод/смена PIN - AT+CPIN=...,...      (common.sh, change_pin_code)
#   * снятие блокировки - AT+CLCK="SC",0,"<pin>" (common.sh, disable_pin_lock)
#   * номер SIM - AT+CNUM                  (common.sh, get_subscriber_id)
#   * перезагрузка модема - AT+ZRST         (gosuncn.sh, reset_modem)
#
# Режим канала (auto/3G/4G) в стоке для нашего модема (Meig GM510)
# НЕ РЕАЛИЗОВАН: usr/lib/modem_ubus/meig-at.sh содержит
# "set_mode_band() { # TODO: implement; return; }". То есть в стоке
# переключатель режима - мёртвая кнопка. У нас он делается по-настоящему:
# маска LTE обнуляется для режима "только 3G", маска UMTS - для "только 4G"
# (AT+ZBAND=<UMTS>,0,0,<LTE>).
#
# ЧТО ДОЛЖЕН ДЕЛАТЬ helper /usr/libexec/pejir-modem-ctl:
#   * отправлять правильные AT-команды;
#   * НЕ печатать PIN в вывод (он виден только в команде модему);
#   * применять режим канала к маскам диапазонов.

set -u

BASE="$(cd "$(dirname "$0")/.." && pwd)"
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST)"; exit 1; }

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

HELPER="$OW/package/pejir-lte-base/root/usr/libexec/pejir-modem-ctl"
BANDS_SH="$OW/package/pejir-lte-base/root/usr/share/pejir/bands.sh"

# --- 1) helper существует -------------------------------------------------
if [ -f "$HELPER" ]; then
	ok "helper управления модемом есть: pejir-modem-ctl"
else
	fail "нет $HELPER - PIN, номер SIM и перезагрузку модема делать нечем"
	echo "FAIL: провалено проверок: $((FAILED + 1))"
	exit 1
fi

if [ -x "$HELPER" ]; then
	ok "helper исполняемый"
else
	fail "helper не исполняемый"
fi

# --- стенд: подменяем AT-обмен -------------------------------------------
WORK="${PEJIR_TEST_WORK:-/tmp/pejir-modem-ctl-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/atinout" <<'ATEOF'
#!/bin/sh
# Мок atinout: первым аргументом приходит файл с командой.
# MOCK_AT_FAILS=N - первые N обменов модем не отвечает (пустой вывод):
# так проверяется, что helper повторяет команду, а не сдаётся сразу.
cat "$1" 2>/dev/null | tr -d '\r' >> "$MOCK_AT_LOG"
cnt=0
[ -f "$MOCK_AT_COUNT" ] && cnt="$(cat "$MOCK_AT_COUNT" 2>/dev/null)"
cnt=$((cnt + 1))
echo "$cnt" > "$MOCK_AT_COUNT"
if [ "${MOCK_AT_FAILS:-0}" -gt 0 ] && [ "$cnt" -le "$MOCK_AT_FAILS" ]; then
	exit 0
fi
printf '\r\nOK\r\n'
ATEOF

cat > "$WORK/bin/stty" <<'STEOF'
#!/bin/sh
exit 0
STEOF

cat > "$WORK/bin/timeout" <<'TEOF'
#!/bin/sh
# Мок timeout: выполняем команду, отбрасывая аргументы времени.
shift
exec "$@"
TEOF

cat > "$WORK/bin/uci" <<'UCIEOF'
#!/bin/sh
key=""
while [ $# -gt 0 ]; do
	case "$1" in
		-q) shift ;;
		get) shift; key="$1"; shift ;;
		*) shift ;;
	esac
done
case "$key" in
	network.lte.modes) v="$MOCK_MODE" ;;
	network.lte.perenio_band) v="$MOCK_BANDS" ;;
	*) v="" ;;
esac
[ -n "$v" ] || exit 1
printf '%s\n' "$v"
UCIEOF

chmod +x "$WORK/bin/atinout" "$WORK/bin/stty" "$WORK/bin/timeout" "$WORK/bin/uci"

AT_LOG="$WORK/at.log"
: > "$AT_LOG"

run_helper() {
	PATH="$WORK/bin:$PATH" \
	MOCK_AT_LOG="$AT_LOG" \
	MOCK_AT_COUNT="$WORK/at.count" \
	MOCK_MODE="${MOCK_MODE:-}" \
	MOCK_BANDS="${MOCK_BANDS:-}" \
	PEJIR_AT_PORT="$WORK/ttyFAKE" \
	PEJIR_BANDS_SH="$BANDS_SH" \
		sh "$HELPER" "$@" 2>&1
}

# --- 2) статус SIM PIN ----------------------------------------------------
OUT="$(run_helper pin-status)"
if grep -q "AT+CPIN?" "$AT_LOG"; then
	ok "pin-status спрашивает AT+CPIN?"
else
	fail "pin-status не спрашивает AT+CPIN? (в логе: $(cat "$AT_LOG" | tr '\n' ' '))"
fi

# --- 3) ввод PIN ----------------------------------------------------------
: > "$AT_LOG"
OUT="$(run_helper pin-set 1234)"
if grep -q 'AT+CPIN="1234"' "$AT_LOG"; then
	ok "pin-set отправляет AT+CPIN=\"1234\""
else
	fail "pin-set отправляет неверную команду (в логе: $(cat "$AT_LOG" | tr '\n' ' '))"
fi
case "$OUT" in
	*1234*) fail "PIN напечатан в выводе - он не должен попадать в журнал" ;;
	*) ok "PIN не печатается в вывод" ;;
esac

# --- 4) вкл/выкл блокировку PIN ------------------------------------------
: > "$AT_LOG"
run_helper pin-enable 1234 >/dev/null
if grep -q 'AT+CLCK="SC",2,"1234"' "$AT_LOG"; then
	ok "pin-enable отправляет AT+CLCK=\"SC\",2,\"1234\""
else
	fail "pin-enable отправляет неверную команду (в логе: $(cat "$AT_LOG" | tr '\n' ' '))"
fi

: > "$AT_LOG"
run_helper pin-disable 1234 >/dev/null
if grep -q 'AT+CLCK="SC",0,"1234"' "$AT_LOG"; then
	ok "pin-disable отправляет AT+CLCK=\"SC\",0,\"1234\""
else
	fail "pin-disable отправляет неверную команду (в логе: $(cat "$AT_LOG" | tr '\n' ' '))"
fi

# --- 5) номер SIM ---------------------------------------------------------
: > "$AT_LOG"
run_helper cnum >/dev/null
if grep -q "AT+CNUM" "$AT_LOG"; then
	ok "cnum спрашивает AT+CNUM"
else
	fail "cnum не спрашивает AT+CNUM"
fi

# --- 6) перезагрузка модема ----------------------------------------------
: > "$AT_LOG"
run_helper reset >/dev/null
if grep -q "AT+ZRST" "$AT_LOG"; then
	ok "reset отправляет AT+ZRST"
else
	fail "reset не отправляет AT+ZRST"
fi

# --- 7) режим канала ------------------------------------------------------
MOCK_MODE="umts" OUT="$(run_helper mode)"
case "$OUT" in
	*umts*) ok "mode печатает текущий режим канала: $OUT" ;;
	*) fail "mode не напечатал режим канала: $OUT" ;;
esac

: > "$AT_LOG"
MOCK_MODE="umts" MOCK_BANDS="umts01 umts08 lte01 lte03" run_helper mode-apply >/dev/null
if grep -qE "AT\+ZBAND=[0-9a-f]+,0,0,0" "$AT_LOG"; then
	ok "режим \"только 3G\" обнуляет маску LTE: $(grep AT+ZBAND "$AT_LOG")"
else
	fail "режим \"только 3G\" не обнулил маску LTE (в логе: $(cat "$AT_LOG" | tr '\n' ' '))"
fi

: > "$AT_LOG"
MOCK_MODE="lte" MOCK_BANDS="umts01 umts08 lte01 lte03" run_helper mode-apply >/dev/null
if grep -qE "AT\+ZBAND=0,0,0,[0-9a-f]+" "$AT_LOG"; then
	ok "режим \"только 4G\" обнуляет маску UMTS: $(grep AT+ZBAND "$AT_LOG")"
else
	fail "режим \"только 4G\" не обнулил маску UMTS (в логе: $(cat "$AT_LOG" | tr '\n' ' '))"
fi

: > "$AT_LOG"
MOCK_MODE="all" MOCK_BANDS="umts01 umts08 lte01 lte03" run_helper mode-apply >/dev/null
if grep -qE "AT\+ZBAND=[0-9a-f]+,0,0,[0-9a-f]+" "$AT_LOG"; then
	ok "режим auto оставляет обе маски: $(grep AT+ZBAND "$AT_LOG")"
else
	fail "режим auto исказил маски (в логе: $(cat "$AT_LOG" | tr '\n' ' '))"
fi

# --- модем ответил не сразу ----------------------------------------------
# На устройстве номер SIM (AT+CNUM) модем отдаёт медленно - он читает
# его с карты, и первый ответ может не прийти вовсе. Helper обязан
# повторять команду, иначе кнопка "Показать номер" выдаёт "модем не
# ответил" при живом модеме.
: > "$AT_LOG"
rm -f "$WORK/at.count"
OUT="$(MOCK_AT_FAILS=1 run_helper cnum)"
if printf '%s' "$OUT" | grep -q "не ответил"; then
	fail "cnum: модем ответил только со второй попытки, а helper сдался"
else
	ok "cnum: ответ получен после повторной попытки"
fi
# Команда пишется в лог без перевода строки, поэтому считаем вхождения.
attempts="$(grep -o 'AT+CNUM' "$AT_LOG" 2>/dev/null | wc -l)"
if [ "${attempts:-0}" -ge 2 ]; then
	ok "cnum: команда отправлена повторно (попыток: $attempts)"
else
	fail "cnum: команда отправлена один раз, повтора не было"
fi

if grep -q "AT_RETRIES" "$HELPER"; then
	ok "helper повторяет команду, если модем не ответил"
else
	fail "в helper нет повторов AT-команды"
fi

rm -rf "$WORK"

if [ "$FAILED" -eq 0 ]; then
	echo "PASS: управление модемом (PIN, номер SIM, сброс, режим канала) работает верно"
	exit 0
fi

echo "FAIL: провалено проверок: $FAILED"
exit 1
