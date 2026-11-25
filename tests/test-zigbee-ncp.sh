#!/bin/sh
# Тест прошивки Zigbee-NCP (EFR32) на PEJIR01: pejir-ncp-flash.
#
# Проверяем:
#   * исходник утилиты на месте и собирается (host gcc, без кросс-тулчейна);
#   * модуль, отвечающий по EZSP, распознаётся (status => "NCP-ОТВЕТА-ДА");
#   * модуль, не отвечающий по EZSP, распознаётся как "не NCP" (код != 0);
#   * полный цикл прошивки: EZSP -> launchStandaloneBootloader -> Gecko
#     bootloader -> XMODEM-CRC -> "2" (run). Принятый образ должен совпасть
#     с исходным БАЙТ В БАЙТ, CRC всех блоков должны быть верны;
#   * если загрузчик не переходит в режим XMODEM - утилита обязана
#     сообщить об ошибке, а не «успех».
#
# Эмулятор модуля и загрузчика - tests/fake_ncp.py (общается через PTY).

set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
	[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
SRC="$OW/package/pejir-zigbee-ncp/src/pejir-ncp-flash.c"
PKG="$OW/package/pejir-zigbee-ncp/Makefile"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$SRC" "$PKG"; do
	if [ ! -f "$f" ]; then
		echo "FAIL: нет файла $f"
		exit 1
	fi
done
ok "исходники пакета pejir-zigbee-ncp на месте"

WORK="${PEJIR_TEST_WORK:-/tmp/zigbee-ncp-test}"
rm -rf "$WORK"
mkdir -p "$WORK"

# --- сборка ---------------------------------------------------------------
if ! command -v gcc >/dev/null 2>&1; then
	echo "FAIL: нет gcc - тест не может собрать утилиту"
	exit 1
fi
if ! gcc -O2 -Wall -Wextra -o "$WORK/pejir-ncp-flash" "$SRC" 2>"$WORK/build.log"; then
	fail "исходник не собирается"
	cat "$WORK/build.log" | sed 's/^/     /'
	exit 1
fi
if [ -s "$WORK/build.log" ]; then
	fail "сборка проходит с предупреждениями"
	cat "$WORK/build.log" | sed 's/^/     /'
else
	ok "утилита собирается без предупреждений"
fi

FAKE="$BASE/fake_ncp.py"
if [ ! -f "$FAKE" ]; then
	fail "нет эмулятора $FAKE"
	exit 1
fi

# --- тестовый образ -------------------------------------------------------
python3 - "$WORK/image.gbl" <<'EOF'
import sys, os
p = sys.argv[1]
data = bytearray()
x = 0x1234
for i in range(40000):
    x = (x * 1103515245 + 12345) & 0xFFFFFFFF
    data.append((x >> 16) & 0xFF)
open(p, "wb").write(bytes(data))
EOF
ok "тестовый образ подготовлен"

# --- 1) status: модуль отвечает по EZSP ----------------------------------
python3 "$FAKE" --pty "$WORK/pty1" --out "$WORK/recv1.gbl" >"$WORK/fake1.log" 2>&1 &
FPID=$!
i=0
while [ ! -s "$WORK/pty1" ] && [ $i -lt 50 ]; do
	sleep 0.1
	i=$((i+1))
done
PTY="$(cat "$WORK/pty1" 2>/dev/null)"
if [ -z "$PTY" ]; then
	fail "эмулятор не создал PTY"
	kill $FPID 2>/dev/null
	exit 1
fi

out="$("$WORK/pejir-ncp-flash" status -p "$PTY" 2>&1)"
rc=$?
kill $FPID 2>/dev/null
wait $FPID 2>/dev/null
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "NCP-ОТВЕТА-ДА"; then
	ok "status: модуль, отвечающий по EZSP, распознан"
else
	fail "status: модуль не распознан (rc=$rc)"
	echo "$out" | sed 's/^/     /'
fi

# --- 2) status: модуль не отвечает ----------------------------------------
python3 "$FAKE" --pty "$WORK/pty2" --out "$WORK/recv2.gbl" --silent >"$WORK/fake2.log" 2>&1 &
FPID=$!
i=0
while [ ! -s "$WORK/pty2" ] && [ $i -lt 50 ]; do
	sleep 0.1
	i=$((i+1))
done
PTY="$(cat "$WORK/pty2" 2>/dev/null)"
out="$("$WORK/pejir-ncp-flash" status -p "$PTY" 2>&1)"
rc=$?
kill $FPID 2>/dev/null
wait $FPID 2>/dev/null
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "NCP-ОТВЕТА-НЕТ"; then
	ok "status: модуль, не отвечающий по EZSP, распознан как «не NCP»"
else
	fail "status: не-NCP модуль не распознан (rc=$rc)"
	echo "$out" | sed 's/^/     /'
fi

# --- 3) полный цикл прошивки ---------------------------------------------
python3 "$FAKE" --pty "$WORK/pty3" --out "$WORK/recv3.gbl" >"$WORK/fake3.log" 2>&1 &
FPID=$!
i=0
while [ ! -s "$WORK/pty3" ] && [ $i -lt 50 ]; do
	sleep 0.1
	i=$((i+1))
done
PTY="$(cat "$WORK/pty3" 2>/dev/null)"
out="$("$WORK/pejir-ncp-flash" flash -p "$PTY" -f "$WORK/image.gbl" 2>&1)"
rc=$?
wait $FPID 2>/dev/null

if [ "$rc" -ne 0 ]; then
	fail "цикл прошивки завершился с ошибкой (rc=$rc)"
	echo "$out" | sed 's/^/     /'
	cat "$WORK/fake3.log" | sed 's/^/     /'
else
	ok "цикл прошивки завершился успешно"
fi

if [ -f "$WORK/recv3.gbl" ]; then
	# XMODEM дополняет последний блок байтами 0x1A (SUB), поэтому сравниваем
	# только длину исходного файла, а дополнение проверяем отдельно.
	orig_size="$(wc -c < "$WORK/image.gbl" | tr -d ' ')"
	recv_size="$(wc -c < "$WORK/recv3.gbl" | tr -d ' ')"
	if head -c "$orig_size" "$WORK/recv3.gbl" | cmp -s - "$WORK/image.gbl"; then
		ok "принятый образ совпал с исходным байт в байт ($orig_size Б)"
	else
		fail "принятый образ отличается от исходного"
		ls -l "$WORK/image.gbl" "$WORK/recv3.gbl" | sed 's/^/     /'
	fi
	if [ "$recv_size" -ge "$orig_size" ] && [ $((recv_size % 128)) -eq 0 ]; then
		ok "размер принятого образа кратен 128 (XMODEM-блок): $recv_size Б"
	else
		fail "размер принятого образа $recv_size Б не кратен 128"
	fi
	tail -c +$((orig_size + 1)) "$WORK/recv3.gbl" > "$WORK/pad.bin"
	if [ -s "$WORK/pad.bin" ] && [ "$(tr -d '\032' < "$WORK/pad.bin" | wc -c | tr -d ' ')" -eq 0 ]; then
		ok "дополнение последнего блока заполнено 0x1A"
	else
		fail "дополнение последнего блока заполнено не 0x1A"
	fi
else
	fail "образ не принят (нет файла)"
fi

if [ -f "$WORK/recv3.gbl.summary" ]; then
	summary="$(cat "$WORK/recv3.gbl.summary")"
	if printf '%s' "$summary" | grep -q "bad_crc=0"; then
		ok "все блоки приняты с верным CRC ($summary)"
	else
		fail "часть блоков принята с неверным CRC ($summary)"
	fi
	if printf '%s' "$summary" | grep -q "run=1"; then
		ok "после передачи отправлена команда запуска (2)"
	else
		fail "команда запуска (2) не отправлена ($summary)"
	fi
else
	fail "нет отчёта эмулятора"
fi

# --- 4) загрузчик не готов к XMODEM ---------------------------------------
python3 "$FAKE" --pty "$WORK/pty4" --out "$WORK/recv4.gbl" --no-xmodem >"$WORK/fake4.log" 2>&1 &
FPID=$!
i=0
while [ ! -s "$WORK/pty4" ] && [ $i -lt 50 ]; do
	sleep 0.1
	i=$((i+1))
done
PTY="$(cat "$WORK/pty4" 2>/dev/null)"
out="$("$WORK/pejir-ncp-flash" flash -p "$PTY" -f "$WORK/image.gbl" 2>&1)"
rc=$?
kill $FPID 2>/dev/null
wait $FPID 2>/dev/null
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "XMODEM"; then
	ok "если загрузчик не готов к XMODEM - сообщена ошибка (rc=$rc)"
else
	fail "при неготовом загрузчике утилита не сообщила об ошибке (rc=$rc)"
	echo "$out" | sed 's/^/     /'
fi

rm -rf "$WORK"

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты прошивки Zigbee-NCP пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
