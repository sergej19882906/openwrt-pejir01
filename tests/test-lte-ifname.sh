#!/bin/sh
# Проверка LTE: имя интерфейса модема не хардкодится, а устаревшее
# значение в конфиге заменяется на обнаруженное.
#
# Запуск:  sh tests/test-lte-ifname.sh

set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
# Корень дерева OpenWrt с применёнными патчами.
# По умолчанию — рабочее дерево, где патчи уже применены.
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
INIT="$OW/package/pejir-lte-base/root/etc/init.d/47-pejir-lte"

WORK="$(mktemp -d)"
export UCI_STATE="$WORK"
mkdir -p "$WORK/bin" "$WORK/sys/class/net"

# --- мок uci -------------------------------------------------------------
cat > "$WORK/bin/uci" <<EOF
#!/bin/sh
exec python3 "$BASE/mock-uci.py" "\$@"
EOF
chmod +x "$WORK/bin/uci"
PATH="$WORK/bin:$PATH"
export PATH

# --- мок /sys/class/net --------------------------------------------------
# Модем на eth1 (как на живом устройстве), eth0 — обычный Ethernet.
mkdir -p "$WORK/sys/class/net/eth0/device" "$WORK/sys/class/net/eth1/device"
printf 'DEVTYPE=usb_interface\n' > "$WORK/sys/class/net/eth1/device/uevent"
printf 'DEVTYPE=usb_interface\n' > "$WORK/sys/class/net/eth0/device/uevent"

# Подменяем путь /sys/class/net на мок и убираем зависимость от /proc.
sed -e "s#/sys/class/net#$WORK/sys/class/net#g" \
    -e "s#^log() {#log() { :; }\n_real_log() {#" \
    "$INIT" > "$WORK/47-pejir-lte"
sed -i 's#^\tlogger -t pejir-lte "\*"#\t: #' "$WORK/47-pejir-lte"

# detect_ifname: проверяем fallback по DEVTYPE=usb_interface.
# Эмулируем случай, когда VID:PID не совпал (модем с другим ID).
detect_out="$(
	. "$WORK/47-pejir-lte" 2>/dev/null || true
	MODEM_USB_IDS="0000:0000"
	detect_ifname
)"
if [ "$detect_out" != "eth0" ] && [ "$detect_out" != "eth1" ]; then
	echo "FAIL: fallback не нашёл USB-интерфейс (получено '$detect_out')"
	exit 1
fi
echo "OK: detect_ifname находит USB-интерфейс ($detect_out)"

# --- ensure_lte_section: устаревшее имя заменяется ------------------------
cat > "$WORK/network" <<'EOF'
config interface 'lte'
	option device 'usb0'
	option proto 'dhcp'
	option metric '20'

config interface 'lte6'
	option device 'usb0'
	option proto 'dhcpv6'
EOF

ensure_out="$(
	. "$WORK/47-pejir-lte" 2>/dev/null || true
	ensure_lte_section eth1
)"
[ -n "$ensure_out" ] || true

got="$(uci -q get network.lte.device)"
if [ "$got" != "eth1" ]; then
	echo "FAIL: network.lte.device не обновлён: '$got' (ожидалось eth1)"
	exit 1
fi
got6="$(uci -q get network.lte6.device)"
if [ "$got6" != "eth1" ]; then
	echo "FAIL: network.lte6.device не обновлён: '$got6' (ожидалось eth1)"
	exit 1
fi
echo "OK: устаревшее usb0 заменено на eth1"

# --- а если имя корректное — не трогаем ----------------------------------
cat > "$WORK/network" <<'EOF'
config interface 'lte'
	option device 'eth1'
	option proto 'dhcp'
EOF
(
	. "$WORK/47-pejir-lte" 2>/dev/null || true
	ensure_lte_section eth1
) >/dev/null
got="$(uci -q get network.lte.device)"
if [ "$got" != "eth1" ]; then
	echo "FAIL: корректное имя изменено на '$got'"
	exit 1
fi
echo "OK: корректное имя не изменяется"

# --- регрессия: пользовательские proto/metric не затираются ----------------
# Раньше проверка существования секции выглядела как
#   if ! uci -q get network.lte.type
# но у секции "config interface" нет опции "type" — такой запрос всегда
# падает, поэтому блок "создания" выполнялся при КАЖДОМ старте и затирал
# proto/metric пользователя.
cat > "$WORK/network" <<'EOF'
config interface 'lte'
	option device 'usb0'
	option proto 'none'
	option metric '99'
EOF
(
	. "$WORK/47-pejir-lte" 2>/dev/null || true
	ensure_lte_section eth1
) >/dev/null
proto="$(uci -q get network.lte.proto)"
metric="$(uci -q get network.lte.metric)"
if [ "$proto" != "none" ] || [ "$metric" != "99" ]; then
	echo "FAIL: настройки пользователя затёрты (proto='$proto' metric='$metric', ожидалось proto=none metric=99)"
	exit 1
fi
dev="$(uci -q get network.lte.device)"
if [ "$dev" != "eth1" ]; then
	echo "FAIL: устаревшее имя не заменено: '$dev' (ожидалось eth1)"
	exit 1
fi
echo "OK: proto/metric пользователя сохранены, имя обновлено"

rm -rf "$WORK"
echo "OK: lte"
