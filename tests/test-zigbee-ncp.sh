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

# --- 5) перезапуск модуля через STM32 --------------------------------------
# Штатный способ разбудить/перезапустить зависший модуль EFR32:
#   mcu -g "setpwr zigbee=off"; sleep 2; mcu -g "setpwr zigbee=on"
# Без него прошивка невозможна, если модуль не отвечает по EZSP.
WRAP="$OW/package/pejir-zigbee-ncp/files/pejir-zigbee-ncp"
if [ ! -f "$WRAP" ]; then
	fail "нет обёртки $WRAP"
else
	if grep -q 'setpwr zigbee=off' "$WRAP" && grep -q 'setpwr zigbee=on' "$WRAP"; then
		ok "обёртка умеет перезапускать модуль через STM32 (setpwr zigbee=off/on)"
	else
		fail "обёртка не перезапускает модуль через STM32"
	fi
	i_cycle="$(grep -n 'power_cycle' "$WRAP" | head -1 | cut -d: -f1)"
	i_flash="$(grep -n 'pejir-ncp-flash flash' "$WRAP" | head -1 | cut -d: -f1)"
	if [ -n "$i_cycle" ] && [ -n "$i_flash" ] && [ "$i_cycle" -lt "$i_flash" ]; then
		ok "перезапуск модуля выполняется ДО прошивки"
	else
		fail "перезапуск модуля не выполняется перед прошивкой"
	fi
fi

# --- 6) MQTT-брокер для HOMEd ---------------------------------------------
# HOMEd - MQTT-клиент (localhost:1883); без брокера веб-панель пустая.
ZSETUP="$OW/package/pejir-autosetup/files/zigbee-setup.sh"
if [ ! -f "$ZSETUP" ]; then
	fail "нет $ZSETUP"
else
	if grep -q "mosquitto-nossl" "$ZSETUP"; then
		ok "установщик HOMEd ставит mosquitto (MQTT-брокер)"
	else
		fail "установщик HOMEd не ставит mosquitto - веб-панель будет пустой"
	fi
	if grep -q "adapter=ezsp" "$ZSETUP" && grep -q "port=\$PORT" "$ZSETUP"; then
		ok "конфиг HOMEd: адаптер ezsp и порт из переменной"
	else
		fail "конфиг HOMEd: нет adapter=ezsp / port=$PORT"
	fi
	# Значения по умолчанию совпадают с рабочим конфигом PEJIR01:
	# PAN ID привязывает уже спаренные устройства, смена = отвязка.
	for kv in "ZIGBEE_PANID:-0xb7f7" "ZIGBEE_CHANNEL:-11" "reset=soft" "baudrate=115200"; do
		if grep -q "$kv" "$ZSETUP"; then
			ok "в конфиге HOMEd есть $kv"
		else
			fail "в конфиге HOMEd нет $kv"
		fi
	done
fi

# --- занятый порт: HOMEd держит модуль --------------------------------------
# Пока HOMEd запущен, порт /dev/umxtty1 держит он, и EZSP-рукопожатие
# невозможно. Раньше helper в этом случае отвечал "NCP-ОТВЕТА-НЕТ", и
# страница предлагала перепрошить исправно работающий модуль.
HELPER="$OW/package/pejir-zigbee-ncp/files/pejir-zigbee-ncp"
if [ -f "$HELPER" ]; then
	mkdir -p "$WORK/stub"
	: > "$WORK/port"
	cat > "$WORK/stub/pgrep" <<'STUB'
#!/bin/sh
exit 0
STUB
	cat > "$WORK/stub/logread" <<'STUB'
#!/bin/sh
exit 0
STUB
	cat > "$WORK/stub/pejir-ncp-flash" <<'STUB'
#!/bin/sh
echo "вызван" >> "$WORK/flash.calls"
echo "NCP-ОТВЕТА-ДА v8"
STUB
	chmod 755 "$WORK/stub"/*

	PATH="$WORK/stub:$PATH" ZIGBEE_PORT="$WORK/port" \
		sh "$HELPER" status > "$WORK/busy.out" 2>&1

	if grep -q "status=busy" "$WORK/busy.out"; then
		ok "helper: занятый HOMEd порт - статус busy, а не 'не отвечает'"
	else
		fail "helper: при занятом порте нет status=busy"
		sed 's/^/     /' "$WORK/busy.out"
	fi

	if grep -q "NCP-ОТВЕТА-НЕ-ПРОВЕРЕНО" "$WORK/busy.out"; then
		ok "helper: при занятом порте ответ 'не проверено', а не 'не отвечает'"
	else
		fail "helper: нет маркера NCP-ОТВЕТА-НЕ-ПРОВЕРЕНО"
	fi

	if [ ! -f "$WORK/flash.calls" ]; then
		ok "helper: EZSP-рукопожатие не делается, пока порт занят HOMEd"
	else
		fail "helper: EZSP-проверка выполнена при занятом порте"
	fi

	if grep -q "ensure" "$HELPER" && grep -q "homed_running" "$HELPER"; then
		ok "helper: ensure/flash учитывают, что модуль занят HOMEd"
	else
		fail "helper: нет учёта занятого модуля в ensure/flash"
	fi
else
	fail "нет helper'а $HELPER"
fi

rm -rf "$WORK"

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты прошивки Zigbee-NCP пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
