#!/bin/sh
# Тест AT-терминаторов и таймаутов в 47-pejir-lte (pejir-lte-base).
#
# Ловит причину, из-за которой ECM-сессия (AT+ZECMCALL) не поднималась:
#   1) GM510 принимает команды, завершённые CR ('\r'); 'printf ...\n'
#      отправлял LF, и модем команду не считывал (требование CR-only задокументировано
#      в комментариях самого файла, но sync_apn/ecm_call писали printf с '\n').
#   2) Набор сессии ZECMCALL может длиться заметно дольше обычных AT-опросов:
#      общий AT_TIMEOUT=5 обрезал вызов на полушаге - теперь таймаут ECM
#      живёт в отдельной переменной ECM_TIMEOUT.
#
# В процедуре пробника (3-stage probe) намеренно остаётся LF-вариант - это
# фолбэк другого этапа, его трогать нельзя.

set -u

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	DEFAULT_PKG="$OW_TEST/package/pejir-lte-base"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/pejir-lte-base"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
PKG="${PEJIR_PKG:-$DEFAULT_PKG}"
INIT="$PKG/root/etc/init.d/47-pejir-lte"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$INIT" ] || { echo "FAIL: нет файла $INIT"; exit 1; }
sh -n "$INIT" 2>/dev/null && ok "синтаксис 47-pejir-lte корректен" \
	|| fail "синтаксическая ошибка в 47-pejir-lte"

# --- 1) ECM_TIMEOUT существует и используется в ecm_call ----------------------
if grep -qF 'ECM_TIMEOUT="${ECM_TIMEOUT:-30}"' "$INIT"; then
	ok "ECM_TIMEOUT объявлен со значением по умолчанию 30"
else
	fail "нет ECM_TIMEOUT (набор ZECMCALL режется AT_TIMEOUT=5)"
fi

if grep -qF 'timeout "$ECM_TIMEOUT"' "$INIT"; then
	ok "ecm_call использует timeout с ECM_TIMEOUT"
else
	fail "ecm_call не использует ECM_TIMEOUT"
fi

# --- 2) CR-терминаторы в sync_apn / ecm_call ---------------------------------
# Ровно эти три printf обязаны завершаться \r (CGDCONT и оба ZECMCALL).
# at_ask-строки с '\n' из пробника не считаются - проверяем только printf.
if grep -qF 'AT+CGDCONT=1,"IP","%s"\r' "$INIT"; then
	ok "AT+CGDCONT отправляется с CR-терминатором"
else
	fail "AT+CGDCONT в sync_apn отправляется с LF - GM510 команду не видит"
fi

if grep -qF 'AT+ZECMCALL=1,%s\r' "$INIT"; then
	ok "AT+ZECMCALL (с APN) отправляется с CR-терминатором"
else
	fail "AT+ZECMCALL=1,<APN> в ecm_call отправляется с LF - GM510 команду не видит"
fi

if grep -q "AT+ZECMCALL=1.r'" "$INIT"; then
	ok "AT+ZECMCALL (без APN) отправляется с CR-терминатором"
else
	fail "AT+ZECMCALL=1 в ecm_call отправляется с LF - GM510 команду не видит"
fi

# Убедимся, что рядом не осталось printf-версий этих команд с LF
if grep -qF 'AT+CGDCONT=1,"IP","%s"\n' "$INIT" \
	|| grep -qF 'AT+ZECMCALL=1,%s\n' "$INIT"; then
	fail "остался printf с LF в CGDCONT/ZECMCALL"
else
	ok "LF-вариантов CGDCONT/ZECMCALL в printf не осталось"
fi

# --- 3) фолбэк пробника не тронут ---------------------------------------------
if grep -q "at_ask .* 'AT+CSQ.n'" "$INIT"; then
	ok "LF-пробник в 3-stage probe сохранён (намеренный фолбэк)"
else
	fail "пробник порта потерял LF-вариант - 3-stage probe сломан"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "== ИТОГ: $FAILED проверок провалено"
	exit 1
fi
echo "== ИТОГ: все проверки пройдены"
