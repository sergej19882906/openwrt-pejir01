#!/bin/sh
# Тест: uartmuxd не должен съедать CPU роутера.
#
# Дефект, который закрывает этот тест. На устройстве (релиз .75) top
# показывал:
#
#     CPU: 24% usr  40% sys  0% nic  34% idle
#     2035 root R 27% /usr/sbin/uartmuxd -d /dev/ttyS1 -b 115200
#
# Из-за этого LuCI отвечала медленно: страницы "SMS" и "Батарея"
# открывались по несколько секунд, хотя чтение файлов на устройстве
# мгновенное (0,01 с).
#
# Причины в коде uartmuxd:
#
#   1) в slave-канал pty байты писали ПО ОДНОМУ (один write() на байт) -
#      это тысячи системных вызовов и 40 % sys в профайлере;
#   2) при EAGAIN повтор был бесконечным (usleep(1000) и снова write) -
#      если slave не читают, деман крутился в горячем цикле и вдобавок
#      терял данные;
#   3) poll отрабатывал мгновенно при плотном потоке, и деман крутился
#      без единой паузы.
#
# Что проверяет тест:
#
#   - запись в канал идёт буфером, а не по байту;
#   - повтор при EAGAIN ограничен по времени, потерянные байты считаются;
#   - в горячем цикле есть пауза (ограничение частоты опроса);
#   - демон работает с минимальным приоритетом (не мешает LuCI);
#   - исходник компилируется (если в системе есть gcc).
#
# Тест обязан ПАДААТЬ на старом коде и проходить на новом.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева OpenWrt $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева OpenWrt $DEFAULT_TREE (задайте OW_TEST)"; exit 1; }
fi

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

SRC="$DEFAULT_TREE/package/uartmuxd/src/uartmuxd.c"
INIT="$DEFAULT_TREE/package/uartmuxd/files/uartmuxd.init"

if [ ! -f "$SRC" ]; then
	echo "FAIL: нет $SRC"
	exit 1
fi

# --- 1. Запись в канал - буфером, а не по байту ---------------------------
if grep -q "uint8_t out\[" "$SRC" && grep -q "chan_flush" "$SRC"; then
	ok "в канал пишем буфером (chan_flush), а не по одному байту"
else
	fail "в канал по-прежнему пишут по байту - это тысячи write() и 40 % sys"
fi

# --- 2. Повтор при EAGAIN ограничен ---------------------------------------
if grep -q "write_all_timeout" "$SRC" && grep -q "g_dropped" "$SRC"; then
	ok "повтор при EAGAIN ограничен по времени, потерянные байты считаются"
else
	fail "нет ограничения повтора при EAGAIN - деман крутится в горячем цикле"
fi

if grep -q "usleep(1000);" "$SRC" && grep -q "usleep(1000);[[:space:]]*$" "$SRC"; then
	if sed -n '/static int write_all(/,/^}/p' "$SRC" | grep -q "usleep(1000)"; then
		fail "в write_all остался бесконечный повтор с usleep(1000)"
	else
		ok "бесконечного повтора с usleep(1000) в write_all больше нет"
	fi
else
	ok "бесконечного повтора с usleep(1000) в write_all больше нет"
fi

# --- 3. Пауза в горячем цикле ---------------------------------------------
if grep -q "hot >= 16" "$SRC" && grep -q "usleep(2000)" "$SRC"; then
	ok "в горячем цикле есть пауза - частота опроса ограничена"
else
	fail "нет ограничения частоты опроса - демен крутится без пауз"
fi

# --- 4. Минимальный приоритет ---------------------------------------------
if grep -q "setpriority" "$SRC"; then
	ok "демон работает с минимальным приоритетом (не мешает LuCI)"
else
	fail "демон не снижает приоритет - он конкурирует с LuCI за CPU"
fi

# --- 5. Исходник компилируется --------------------------------------------
if command -v gcc >/dev/null 2>&1; then
	if gcc -O2 -Wall -o /tmp/pejir-uartmuxd-test "$SRC" 2>/tmp/pejir-uartmuxd-cc.log; then
		ok "исходник компилируется без ошибок"
		rm -f /tmp/pejir-uartmuxd-test
	else
		fail "исходник не компилируется"
		cat /tmp/pejir-uartmuxd-cc.log
	fi
	rm -f /tmp/pejir-uartmuxd-cc.log
else
	echo "OK: gcc отсутствует - проверка компиляции пропущена"
fi

# --- 6. init-скрипт на месте ----------------------------------------------
if [ -f "$INIT" ]; then
	ok "init-скрипт uartmuxd на месте"
else
	fail "нет $INIT"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi
echo "Все проверки пройдены"
exit 0
