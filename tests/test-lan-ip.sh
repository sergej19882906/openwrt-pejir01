#!/bin/sh
# Тест: адрес LAN возвращается к 192.168.2.1 после сброса конфига сети.
#
# Дефект, который закрывает тест: после прошивки релиза .73 конфиг сети
# вернулся к дефолту OpenWrt (192.168.1.1), телефон оказался в другой
# подсети, LuCI на 192.168.2.1 не открывался, а в зоне wan не было
# интерфейсов LTE - интернет "пропал".
#
# Скрипт 49-pejir-lan-ip должен:
#   * возвращать 192.168.2.1, если адрес снова стал стоковым;
#   * не трогать адрес, который владелец выбрал сам;
#   * не возвращать адрес повторно для той же версии образа (метка).

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

SCRIPT="$DEFAULT_TREE/package/luci-app-perenio/root/etc/init.d/49-pejir-lan-ip"
MOCK_UCI="$(dirname "$0")/mock-uci.py"

[ -f "$SCRIPT" ] || { echo "FAIL: нет файла $SCRIPT"; exit 1; }
[ -f "$MOCK_UCI" ] || { echo "FAIL: нет мока $MOCK_UCI"; exit 1; }

WORK="${PEJIR_LANIP_TEST:-/tmp/pejir-lanip-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/state"

# Моки: uci и logger (чтобы скрипт не писал в системный журнал).
cat > "$WORK/bin/uci" <<EOF
#!/bin/sh
exec python3 "$MOCK_UCI" "\$@"
EOF
cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/uci" "$WORK/bin/logger"

# Версия образа и метка - во временном каталоге.
echo "25.12.6-pejir01.74" > "$WORK/version"
MARKER="$WORK/lan-ip-version"

# --- 1. Статические проверки --------------------------------------------
grep -q '192\.168\.2\.1' "$SCRIPT" && ok "в скрипте есть целевой адрес 192.168.2.1" \
	|| fail "в скрипте нет адреса 192.168.2.1"
grep -q 'START=13' "$SCRIPT" && ok "скрипт стартует до сети (START=13)" \
	|| fail "скрипт не стартует до сети - адрес применится с задержкой"
grep -q 'uci -q get network\.lan\.ipaddr' "$SCRIPT" && ok "адрес читается из network.lan.ipaddr" \
	|| fail "скрипт не читает адрес из network.lan.ipaddr"
grep -q 'PEJIR_LANIP_MARKER' "$SCRIPT" && ok "есть метка версии (скрипт не мешает владельцу)" \
	|| fail "нет метки версии - скрипт будет возвращать адрес при каждой загрузке"

# --- 2. Функциональная проверка -----------------------------------------
run_script() {
	PATH="$WORK/bin:$PATH" \
	UCI_STATE="$WORK/state" \
	PEJIR_LANIP_VERSION_FILE="$WORK/version" \
	PEJIR_LANIP_MARKER="$MARKER" \
	sh -c ". '$SCRIPT'; start" >"$WORK/out.log" 2>&1
}

seed_state() {
	cat > "$WORK/state/network" <<EOF
config interface 'lan'
	option proto 'static'
	option ipaddr '$1'
	option netmask '255.255.255.0'

config interface 'lte'
	option proto 'dhcp'
	option device 'usb0'
EOF
}

lan_ip() {
	sed -n "s/.*option ipaddr '\([^']*\)'.*/\1/p" "$WORK/state/network" | head -1
}

# 2.1. Стоковый адрес -> возвращаем 192.168.2.1
seed_state "192.168.1.1"
rm -f "$MARKER"
run_script
[ "$(lan_ip)" = "192.168.2.1" ] && ok "стоковый 192.168.1.1 заменён на 192.168.2.1" \
	|| fail "адрес не возвращён (стало $(lan_ip))"
[ -f "$MARKER" ] && ok "метка версии записана" || fail "метка версии не записана"

# 2.2. Тот же стоковый адрес, но метка уже этой версии - не трогаем
seed_state "192.168.1.1"
run_script
[ "$(lan_ip)" = "192.168.1.1" ] && ok "для этой версии адрес повторно не возвращается" \
	|| fail "адрес возвращается повторно, хотя владелец мог выбрать его сам"

# 2.3. Адрес владельца - не трогаем
seed_state "10.0.0.1"
rm -f "$MARKER"
run_script
[ "$(lan_ip)" = "10.0.0.1" ] && ok "адрес, выбранный владельцем, не изменён" \
	|| fail "адрес владельца изменён на $(lan_ip)"

# 2.4. Секция lte и другие настройки не теряются
seed_state "192.168.1.1"
rm -f "$MARKER"
run_script
grep -q "config interface 'lte'" "$WORK/state/network" \
	&& ok "секция lte в конфиге сохранена" \
	|| fail "секция lte потеряна"

if [ "$FAILED" -eq 0 ]; then
	echo "Все проверки пройдены"
	exit 0
fi
echo "Провалено проверок: $FAILED"
exit 1
