#!/bin/sh
# Тест pejir-lte-base / pejir-sms: перед AT-обменом выставляется скорость порта.
#
# Проблема, которую ловит тест:
#   atinout порт НЕ настраивает. В его коде только fopen(dev, "r+b") -
#   ни tcsetattr, ни baud, ни raw-режима. Порты USB-серийных (ttyUSB* у
#   GM510) поднимаются с дефолтом tty - 9600, а модем ждёт 115200.
#   В итоге модем на "AT" молчит, AT-порт не находится:
#     - 40-pejir-sms не переписывает /etc/smsd.conf, smsd остаётся без
#       устройства, страница SMS показывает "порт не задан";
#     - 47-pejir-lte не шлёт AT+CGDCONT / AT+ZECMCALL, LTE не поднимается;
#     - 41-pejir-modem записывает в /etc/config/modeminfo порт /dev/ttyUSB0
#       (фолбэк), страница "Модем" показывает пустые данные.
#   У вендора это работало, потому что его gcom-профили перед обменом
#   делают "set com 115200n81".
#
# Поэтому в скриптах перед вызовом atinout должна выставляться скорость
# (stty -F <порт> 115200 raw -echo), а сохранённый порт модема должен
# проверяться живым AT-запросом, а не приниматься на веру.

set -u

# Корень дерева OpenWrt с применёнными патчами: в CI это $OW_TEST
# (переменная выставляется workflow), локально - рабочее дерево.
# Без этого тест искал бы файлы по жёстко зашитому пути и падал в CI.
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
LTE="${LTE:-$OW/package/pejir-lte-base/root/etc/init.d/47-pejir-lte}"
SMS="${SMS:-$OW/package/pejir-sms/root/etc/init.d/40-pejir-sms}"
MDMAT="${MDMAT:-$OW/package/pejir-lte-base/root/usr/bin/mdm-at}"
MODEM="${MODEM:-$OW/package/pejir-lte-base/root/etc/init.d/41-pejir-modem}"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$LTE" "$SMS" "$MDMAT" "$MODEM"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) в каждом скрипте есть помощник скорости --------------------------
for f in "$MDMAT" "$LTE" "$SMS"; do
	if grep -q 'stty -F "\$1"' "$f" && grep -q '115200' "$f"; then
		ok "$(basename "$f"): скорость порта выставляется через stty"
	else
		fail "$(basename "$f"): нет вызова stty для скорости порта"
	fi
done

# --- 2) перед каждым atinout в коде есть set_port_speed -------------------
# Смотрим только исполняемые строки (комментарии не считаются).
for f in "$MDMAT" "$LTE" "$SMS"; do
	code="$(grep -vE '^[[:space:]]*#' "$f" | grep -nE 'atinout ' | cut -d: -f1 | tr '\n' ' ')"
	missed=""
	for ln in $code; do
		# ищем set_port_speed в трёх предыдущих строках
		prev="$(grep -vE '^[[:space:]]*#' "$f" | sed -n "$((ln-3)),$((ln))p")"
		echo "$prev" | grep -q 'set_port_speed' || missed="$missed $ln"
	done
	if [ -z "$missed" ]; then
		ok "$(basename "$f"): перед каждым atinout выставляется скорость"
	else
		fail "$(basename "$f"): без set_port_speed перед atinout (строки:$missed)"
	fi
done

# --- 3) 41-pejir-modem проверяет сохранённый порт живым запросом ---------
if grep -q 'port_alive' "$MODEM" && grep -q 'port_alive "\$saved"' "$MODEM"; then
	ok "41-pejir-modem: сохранённый порт проверяется AT-запросом"
else
	fail "41-pejir-modem: сохранённый порт принимается без проверки"
fi

# --- 4) функциональная проверка: модем отвечает только на 115200 ---------
# Моделируем модем: atinout отвечает "OK" лишь если для этого порта
# через stty выставлена скорость 115200.
WORK="$(mktemp -d /tmp/pejir-at-speed.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/bin" "$WORK/dev"
cat > "$WORK/bin/stty" <<'STTY_EOF'
#!/bin/sh
# Мок stty: запоминаем скорость для порта.
port=""
speed=""
while [ $# -gt 0 ]; do
	case "$1" in
		-F) port="$2"; shift 2 ;;
		[0-9]*) speed="$1"; shift ;;
		*) shift ;;
	esac
done
[ -n "$port" ] && [ -n "$speed" ] && echo "$port $speed" >> "$STTY_STATE"
exit 0
STTY_EOF
cat > "$WORK/bin/atinout" <<'ATINOUT_EOF'
#!/bin/sh
# Мок atinout: отвечает "OK" только если скорость порта = 115200.
dev="$2"
speed="$(awk -v d="$dev" '$1==d{print $2}' "$STTY_STATE" 2>/dev/null | tail -1)"
[ "$speed" = "115200" ] && printf '\r\nOK\r\n'
exit 0
ATINOUT_EOF
chmod +x "$WORK/bin/stty" "$WORK/bin/atinout"

: > "$WORK/ttyUSB2"
: > "$WORK/ttyUSB1"
: > "$WORK/ttyUSB0"

sed "s#/dev/ttyUSB#$WORK/ttyUSB#g; s#/dev/ttyACM#$WORK/ttyACM#g; s#\[ -c \"\\\$p\" \]#[ -e \"\$p\" ]#g; s#\[ -c \"\\\$1\" \]#[ -e \"\$1\" ]#g" \
	"$MDMAT" > "$WORK/mdm-at"
chmod +x "$WORK/mdm-at"

export STTY_STATE="$WORK/state"
: > "$STTY_STATE"

out="$(PATH="$WORK/bin:$PATH" "$WORK/mdm-at" --port 2>/dev/null)"
if [ "$out" = "$WORK/ttyUSB2" ]; then
	ok "mdm-at находит AT-порт (ttyUSB2): модем отвечает на 115200"
else
	fail "mdm-at вернул '$out' (ожидался $WORK/ttyUSB2) - скорость порта не выставляется"
fi

# Порт должен быть найден именно с выставленной скоростью
if grep -q "115200" "$STTY_STATE"; then
	ok "скорость 115200 действительно выставлена перед обменом"
else
	fail "stty ни разу не вызван с 115200"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты скорости AT-порта пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
