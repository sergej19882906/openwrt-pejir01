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
# ВАЖНО (правка 0150): файл команды модему обязан заканчиваться LF.
# Настоящий atinout (функция tr_lf_cr) отклоняет строку без завершающего
# LF, печатает "invalid string" и НИЧЕГО модему не отправляет. Перевод
# строки в CR ("tr '\n' '\r'") оставлял файл БЕЗ LF - и все AT-команды
# пропадали: модем не получал ни AT+CGDCONT, ни AT+ZECMCALL, LTE не
# поднимал PDP-контекст и не давал интернет. Перевод строки в CR
# делает сам atinout, поэтому файл должен быть в формате "\r\n",
# а LF-вариант в пробнике (3-stage probe) бессмысленен: atinout всё
# равно отправит модему CR.

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
# С патча 0089 команды собирает хелпер usr/libexec/pejir-lte-apn: он
# печатает их по одной в строке (без CR), а init-скрипт переводит
# перевод строки в CR перед отправкой. GM510 не видит команду,
# завершённую только LF, поэтому проверяем ИменНО это преобразование,
# а запасные printf-варианты - что в них CR остался.
HELPER="$PKG/root/usr/libexec/pejir-lte-apn"

if grep -qF "tr '\\n' '\\r'" "$INIT"; then
	fail "init-скрипт переводит строку в CR через tr - файл останется без LF, atinout ничего не отправит"
else
	ok "init-скрипт не переводит строку в CR через tr (файл команды остаётся с LF)"
fi

if grep -qF 'printf "%s\r\n"' "$INIT"; then
	ok "init-скрипт готовит файл команды в формате CRLF (atinout сам отправит CR)"
else
	fail "нет преобразования команды в CRLF - файл будет без завершающего LF"
fi

if grep -q 'pejir-lte-apn' "$INIT"; then
	ok "init-скрипт отправляет команды хелпера pejir-lte-apn"
else
	fail "init-скрипт не вызывает pejir-lte-apn"
fi

if grep -qF 'AT+ZECMCALL=1,%s\r' "$INIT"; then
	ok "AT+ZECMCALL (с APN, запасной путь) отправляется с CR-терминатором"
else
	fail "AT+ZECMCALL=1,<APN> в ecm_call отправляется с LF - GM510 команду не видит"
fi

if grep -qF "AT+ZECMCALL=1\\r\\n'" "$INIT"; then
	ok "AT+ZECMCALL (без APN, запасной путь) отправляется с CR-терминатором"
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

# --- 3) пробник порта пишет команду с LF -------------------------------------
# Пробник состоит из "AT" и "AT+CSQ"; обе команды должны быть записаны
# с завершающим LF, иначе atinout их не отправит.
if grep -qF "at_ask \"\$p\" 'AT\\r\\n'" "$INIT"; then
	ok "пробник порта пишет команду с LF (atinout отправит модему)"
else
	fail "пробник порта пишет команду без LF - модем не ответит"
fi

if grep -qF "at_ask \"\$p\" 'AT+CSQ\\r\\n'" "$INIT"; then
	ok "второй этап пробника (AT+CSQ) тоже с LF"
else
	fail "второй этап пробника пишет команду без LF"
fi

# LF-варианта в пробнике быть не должно: atinout переводит его в CR
# сам, поэтому отдельный "LF-этап" не различает ничего.
if grep -qF "at_ask \"\$p\" 'AT+CSQ\\n'" "$INIT"; then
	fail "в пробнике остался LF-вариант - atinout всё равно отправит CR"
else
	ok "в пробнике нет бессмысленного LF-варианта"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "== ИТОГ: $FAILED проверок провалено"
	exit 1
fi
echo "== ИТОГ: все проверки пройдены"
