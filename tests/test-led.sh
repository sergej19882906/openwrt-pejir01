#!/bin/sh
# Тест управления LED-индикаторами Perenio (STM32).
#
# Индикаторы зажигает STM32 командой `mcu -p l <имя>=<значение>` - ровно так,
# как в заводской прошивке 9.0.4 (/usr/sbin/pim.lua: ubus mcud post
# {query="l ..."}). Имена: i (интернет), l (LTE), zb (ZigBee), 2 (Wi-Fi 2.4),
# 5 (Wi-Fi 5), sh и a (служебные).
#
# Здесь проверяется:
#   1) helper собирает правильные команды для STM32;
#   2) проверка имени/цвета/режима (в STM32 не должно уходить ничего лишнего);
#   3) "off" гасит все семь индикаторов;
#   4) настройки сохраняются и читаются обратно;
#   5) helper и init-скрипт ставятся в образ, есть грант ACL и пункт меню.

set -u

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
LUCI_PKG="${PEJIR_LUCI_PKG:-$DEFAULT_PKG}"

HELPER="$LUCI_PKG/root/usr/libexec/pejir-led"
INITD="$LUCI_PKG/root/etc/init.d/pejir-led"
PAGE="$LUCI_PKG/htdocs/luci-static/resources/view/perenio/led.js"
ACL="$LUCI_PKG/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
MENU="$LUCI_PKG/root/usr/share/luci/menu.d/luci-app-perenio.json"
MAKEFILE="$LUCI_PKG/Makefile"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$HELPER" "$INITD" "$PAGE" "$ACL" "$MENU" "$MAKEFILE"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done
sh -n "$HELPER" || { echo "FAIL: синтаксис helper"; exit 1; }
sh -n "$INITD" || { echo "FAIL: синтаксис init-скрипта"; exit 1; }
ok "файлы на месте, синтаксис в порядке"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
LOG="$TMP/mcu.log"
CONF="$TMP/led.conf"

# --- мок mcu: пишет свои аргументы в лог -----------------------------------
cat > "$TMP/mcu" <<'EOF'
#!/bin/sh
echo "$*" >> "$MCU_LOG"
EOF
chmod 755 "$TMP/mcu"
export MCU_LOG="$LOG"

BRIGHT="$TMP/led-brightness"
export BRIGHT_CONF="$BRIGHT"

run_led() {
	LED_CONF="$CONF" MCU_BIN="$TMP/mcu" BRIGHT_CONF="$BRIGHT" sh "$HELPER" "$@" 2>&1
}

# --- 0) состояние по умолчанию -----------------------------------------------
STAT="$(run_led status)"
if printf '%s' "$STAT" | grep -q '^2 auto g *$' && printf '%s' "$STAT" | grep -q '^zb manual 0 *$'; then
	ok "по умолчанию i/l/2/5 - авто-режим, zb/sh/a выключены"
else
	fail "начальное состояние неверное: $(printf '%s' "$STAT" | tr '\n' '|')"
fi

# --- 1) установка одного индикатора -----------------------------------------
OUT="$(run_led set i g 55)"
if grep -q -- '-p l i=g,55' "$LOG"; then
	ok "команда индикатора: mcu -p l i=g,55"
else
	fail "неверная команда для i: $(cat "$LOG" 2>/dev/null | tr '\n' ' ')"
fi
if printf '%s' "$OUT" | grep -q '^OK i='; then
	ok "helper отвечает OK"
else
	fail "нет подтверждения: $OUT"
fi

# --- 2) проверка входных данных ----------------------------------------------
: > "$LOG"
run_led set xxx g >/dev/null 2>&1
if [ ! -s "$LOG" ] && run_led set xxx g 2>&1 | grep -q ERROR; then
	ok "неизвестный индикатор отклонён, в STM32 ничего не ушло"
else
	fail "неизвестный индикатор не отклонён"
fi

: > "$LOG"
run_led set i zz >/dev/null 2>&1
if [ ! -s "$LOG" ] && run_led set i zz 2>&1 | grep -q ERROR; then
	ok "недопустимый цвет отклонён"
else
	fail "недопустимый цвет не отклонён"
fi

: > "$LOG"
run_led set i g "rm -rf /" >/dev/null 2>&1
if [ ! -s "$LOG" ] && run_led set i g "rm -rf /" 2>&1 | grep -q ERROR; then
	ok "недопустимый режим отклонён (инъекция не проходит)"
else
	fail "недопустимый режим не отклонён"
fi

# --- 3) погасить все ----------------------------------------------------------
: > "$LOG"
run_led off >/dev/null
CNT="$(grep -c '=0,s10' "$LOG" 2>/dev/null || echo 0)"
if [ "$CNT" -eq 7 ]; then
	ok "off гасит все 7 индикаторов"
else
	fail "off погасил $CNT индикаторов вместо 7"
fi

# --- 4) настройки сохраняются -------------------------------------------------
run_led set 5 b >/dev/null
if [ -f "$CONF" ] && grep -q '^5 manual b *$' "$CONF"; then
	ok "настройка сохранена в $CONF"
else
	fail "настройка не сохранена: $(cat "$CONF" 2>/dev/null | tr '\n' ' ')"
fi

run_led set i g 55 >/dev/null
STAT="$(run_led status)"
if printf '%s' "$STAT" | grep -q '^i manual g 55 *$'; then
	ok "ручная настройка сохраняется вместе с режимом мигания"
else
	fail "ручная настройка не сохранена: $(printf '%s' "$STAT" | tr '\n' '|')"
fi

# --- 5) авто-режим ------------------------------------------------------------
: > "$LOG"
run_led auto l on >/dev/null
if grep -q '^l auto ' "$CONF"; then
	ok "авто-режим для l включён"
else
	fail "авто-режим для l не включён"
fi
if grep -q -- '-p l l=' "$LOG"; then
	ok "при включении авто-режима индикатор сразу перекрашен"
else
	fail "индикатор не перекрашен при включении авто-режима"
fi

# --- 5a) остановка сервиса не стирает настройки --------------------------------
# Дефект: init-скрипт pejir-led в stop_service() вызывал "pejir-led off",
# а команда "off" переписывает /etc/pejir/led.conf, ставя всем индикаторам
# "manual 0". Остановка сервиса происходит при каждой перезагрузке - после
# неё авто-режим был потерян, и индикация "слетала".
#
# Правильное поведение: гасить светодиоды, но настройки сохранять.
printf 'l auto g\n' > "$CONF"
: > "$LOG"
run_led blank >/dev/null
if grep -q '^l auto g *$' "$CONF"; then
	ok "команда blank не стирает настройки индикаторов"
else
	fail "команда blank стёрла настройки: $(cat "$CONF" 2>/dev/null | tr '\n' '|')"
fi

# При этом светодиоды должны быть погашены.
BLANKED="$(grep -c '=0,s10' "$LOG" 2>/dev/null || echo 0)"
if [ "$BLANKED" -eq 7 ]; then
	ok "blank гасит все 7 индикаторов"
else
	fail "blank погасил $BLANKED индикаторов вместо 7"
fi

# Итог: init-скрипт при остановке зовёт blank, а не off.
if grep -q 'pejir-led blank' "$INITD"; then
	ok "init-скрипт при остановке вызывает blank (настройки сохраняются)"
else
	fail "init-скрипт не вызывает blank при остановке"
fi

# --- 5b) восстановление состояния при старте --------------------------------
# Дефект: авто-цикл красил ТОЛЬКО индикаторы в режиме auto. Ручные
# (manual) индикаторы в него не попадали, а stop_service() перед
# перезагрузкой гасил светодиоды - после перезагрузки индикация
# "слетала". Теперь при старте применяется сохранённое состояние
# ВСЕХ индикаторов.
printf 'zb manual b\n' > "$CONF"
printf 'i manual r 55\n' >> "$CONF"
printf 'sh manual 0\n' >> "$CONF"
printf '2 auto g\n' >> "$CONF"
: > "$LOG"
run_led restore >/dev/null
if grep -q -- '-p l zb=b' "$LOG"; then
	ok "restore вернул ручной цвет индикатора zb"
else
	fail "restore не вернул ручной цвет zb: $(cat "$LOG" | tr '\n' ' ')"
fi
if grep -q -- '-p l i=r,55' "$LOG"; then
	ok "restore вернул ручной цвет и режим мигания"
else
	fail "restore не вернул ручной цвет и режим мигания: $(cat "$LOG" | tr '\n' ' ')"
fi
if grep -q -- '-p l sh=0' "$LOG"; then
	ok "restore оставил погашенным индикатор, который пользователь погасил"
else
	fail "restore не вернул состояние погашенного индикатора sh"
fi
# Авто-индикатор должен получить цвет по состоянию системы.
if grep -q -- '-p l 2=' "$LOG"; then
	ok "restore перекрасил авто-индикатор по состоянию системы"
else
	fail "restore не тронул авто-индикатор: $(cat "$LOG" | tr '\n' ' ')"
fi
# Индикатор, для которого записи в led.conf нет, трогать нельзя.
if grep -q -- '-p l 5=' "$LOG"; then
	fail "restore тронул индикатор, которого нет в led.conf: $(cat "$LOG" | tr '\n' ' ')"
else
	ok "restore не трогает индикаторы без записи в led.conf"
fi
# Настройки при этом не меняются.
if grep -q '^zb manual b *$' "$CONF" && grep -q '^sh manual 0 *$' "$CONF"; then
	ok "restore не меняет сохранённые настройки"
else
	fail "restore изменил настройки: $(cat "$CONF" | tr '\n' '|')"
fi
# Функция restore_saved обязана вызываться при старте авто-цикла.
if grep -q "restore_saved" "$HELPER"; then
	ok "авто-цикл вызывает restore_saved при старте"
else
	fail "авто-цикл не вызывает restore_saved"
fi

# --- 6) упаковка в образ, ACL и меню -----------------------------------------
if grep -qE 'pejir-led[[:space:]]+off' "$INITD"; then
	fail "init-скрипт вызывает 'pejir-led off' - команда стирает настройки (conf_set manual 0)"
else
	ok "init-скрипт не вызывает 'pejir-led off' (настройки не стираются)"
fi

if grep -q 'pejir-led' "$MAKEFILE"; then
	ok "helper и init-скрипт ставятся в образ"
else
	fail "в Makefile нет установки pejir-led"
fi
if grep -q '"/usr/libexec/pejir-led"' "$ACL"; then
	ok "в ACL есть грант exec на /usr/libexec/pejir-led"
else
	fail "в ACL нет гранта на /usr/libexec/pejir-led"
fi
if grep -q 'perenio/led' "$MENU"; then
	ok "в меню есть пункт страницы LED"
else
	fail "в меню нет пункта страницы LED"
fi
if grep -q 'mcu -p l' "$PAGE"; then
	ok "страница описывает протокол mcu -p l"
else
	fail "страница не упоминает протокол mcu -p l"
fi

# --- яркость (общий уровень STM32, 0..7) -----------------------------------
# Светодиодами управляет STM32, у него есть общий уровень яркости 0..7:
# команда "mcu setbright N". В заводской прошивке уровень выставляется один
# раз при загрузке из /etc/init.d/stm32_setup; у нас он хранится в
# /etc/pejir/led-brightness и применяется при старте авто-режима.
: > "$LOG"
OUT="$(run_led brightness 5)"
if printf '%s' "$OUT" | grep -q "OK brightness=5"; then
	ok "команда brightness возвращает подтверждение"
else
	fail "команда brightness не подтвердилась: $OUT"
fi
if grep -q "^setbright 5$" "$LOG"; then
	ok "в STM32 ушла команда setbright 5"
else
	fail "в STM32 не ушла команда setbright 5: $(cat "$LOG" | tr '\n' ' ')"
fi
if [ "$(cat "$BRIGHT" 2>/dev/null)" = "5" ]; then
	ok "яркость сохранена в файле ($BRIGHT)"
else
	fail "яркость не сохранена: $(cat "$BRIGHT" 2>/dev/null)"
fi
OUT="$(run_led status)"
if printf '%s' "$OUT" | grep -q "^BRIGHTNESS 5$"; then
	ok "status показывает текущую яркость"
else
	fail "status не показывает яркость: $OUT"
fi

for bad in 8 abc -1 99; do
	: > "$LOG"
	OUT="$(run_led brightness "$bad" 2>&1)"
	if printf '%s' "$OUT" | grep -q "ERROR" && [ ! -s "$LOG" ]; then
		ok "недопустимая яркость '$bad' отклонена, в STM32 ничего не ушло"
	else
		fail "недопустимая яркость '$bad' не отклонена: $OUT"
	fi
done

# Яркость по умолчанию (как в стоке) и применение при старте авто-режима.
rm -f "$BRIGHT"
OUT="$(run_led status)"
if printf '%s' "$OUT" | grep -q "^BRIGHTNESS 1$"; then
	ok "яркость по умолчанию 1 (как в заводской прошивке)"
else
	fail "яркость по умолчанию не 1: $OUT"
fi

# На странице должен быть ползунок и команда применения.
if grep -q "'type': 'range'" "$PAGE"; then
	ok "на странице LED есть ползунок яркости"
else
	fail "на странице LED нет ползунка яркости"
fi
if grep -q "'brightness'" "$PAGE"; then
	ok "страница LED вызывает helper с командой brightness"
else
	fail "страница LED не вызывает helper с командой brightness"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты LED пройдены"
