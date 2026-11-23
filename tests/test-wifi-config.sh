#!/bin/sh
# Проверка pejir_wifi_apply:
#   * радио определяются по PCI device ID (0x7603 = 2.4 ГГц, 0x7612 = 5 ГГц);
#   * option path вычисляется из sysfs (realpath), а не хардкодится;
#   * полосы/каналы ставятся по найденному устройству, а не по имени секции;
#   * пользовательские SSID и ключи сохраняются.
#
# Запуск:  sh tests/test-wifi-config.sh
#
# Переменные окружения:
#   OW_TEST  — корень дерева OpenWrt с применёнными патчами

set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
	[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST с деревом OpenWrt)"; exit 1; }

fail() { echo "FAIL: $1"; exit 1; }

check() { # $1=описание $2=ожидание $3=факт
	[ "$2" = "$3" ] || fail "$1: ожидалось '$2', получено '$3'"
}

# --- общая подготовка -------------------------------------------------------
# $1 — каталог состояния, $2 — «сдвиг» PCIe-топологии:
#   0 — обычная: шина 1 = 0000:01:00.0, шина 2 = 0000:02:00.0
#   1 — другая нумерация корневых портов (как после смены ядра)
setup() {
	_state="$1"
	_rootport="$2"
	# Скрипт работает через "uci -c <каталог>": в песочнице это
	# каталог состояния, на устройстве — /etc/config.
	PEJIR_UCI_CONFDIR="$_state"
	export PEJIR_UCI_CONFDIR
	_mk_sysfs "$_state" "$_rootport"
	_mk_uci "$_state"
	_mk_script "$_state"
}

# Мок sysfs: PCI-устройства с реальными device ID.
_mk_sysfs() {
	_state="$1"
	_rootport="$2"
	rm -rf "$_state/sys"
	mkdir -p "$_state/sys/bus/pci/devices"

	# MT7603E (0x7603) на шине 1, MT7612E (0x7612) на шине 2.
	# sysfs-путь: /sys/devices/platform/1e140000.pcie/pci0000:00/<rootport>/<addr>
	_d2g="$_state/sys/devices/platform/1e140000.pcie/pci0000:00/$_rootport/0000:01:00.0"
	_d5g="$_state/sys/devices/platform/1e140000.pcie/pci0000:00/$_rootport/0000:02:00.0"
	mkdir -p "$_d2g" "$_d5g"
	printf '0x7603\n' > "$_d2g/device"
	printf '0x7612\n' > "$_d5g/device"
	ln -sf "$_d2g" "$_state/sys/bus/pci/devices/0000:01:00.0"
	ln -sf "$_d5g" "$_state/sys/bus/pci/devices/0000:02:00.0"
}

_mk_uci() {
	_state="$1"
	mkdir -p "$_state/bin"
	cat > "$_state/bin/uci" <<EOF
#!/bin/sh
exec python3 "$BASE/mock-uci.py" "\$@"
EOF
	chmod +x "$_state/bin/uci"
	PATH="$_state/bin:$PATH"
	export PATH
}

_mk_script() {
	_state="$1"
	mkdir -p "$_state/share/pejir"
	# Подменяем корень sysfs и на общей библиотеке, и в скрипте,
	# который её вызывает.
	sed "s#/sys/bus/pci/devices#$_state/sys/bus/pci/devices#g" \
	    "$OW/package/luci-app-perenio/root/usr/share/pejir/wifi-config.sh" \
	    > "$_state/share/pejir/wifi-config.sh"

	sed -e "s#/usr/share/pejir/wifi-config.sh#$_state/share/pejir/wifi-config.sh#" \
	    "$OW/package/luci-app-perenio/root/etc/uci-defaults/51-pejir-wifi-dualband" \
	    > "$_state/51-pejir-wifi-dualband"
}

# --- Сценарий 1: обычный конфиг, имена секций совпадают с ролями ----------
STATE="$(mktemp -d)"
export UCI_STATE="$STATE"
mkdir -p "$STATE"
cat > "$STATE/wireless" <<'EOF'
config wifi-device 'radio0'
	option type 'mac80211'
	option path '1e140000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0'
	option band '2g'
	option channel '1'
	option htmode 'HT20'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyHome'
	option encryption 'psk2'
	option key 'secretpass'
	option disabled '0'

config wifi-device 'radio1'
	option type 'mac80211'
	option path '1e140000.pcie/pci0000:00/0000:00:01.0/0000:02:00.0'
	option band '2g'
	option channel '6'
	option htmode 'HT20'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyHome'
	option encryption 'psk2'
	option key 'secretpass'
	option disabled '0'
EOF

setup "$STATE" "0000:00:00.0"
sh "$STATE/51-pejir-wifi-dualband"

check "radio0 band"   "2g"  "$(uci -q get wireless.radio0.band)"
check "radio0 channel" "1"  "$(uci -q get wireless.radio0.channel)"
check "radio0 htmode" "HT20" "$(uci -q get wireless.radio0.htmode)"
check "radio1 band"   "5g"  "$(uci -q get wireless.radio1.band)"
check "radio1 channel" "36" "$(uci -q get wireless.radio1.channel)"
check "radio1 htmode" "VHT80" "$(uci -q get wireless.radio1.htmode)"
check "radio0 ssid сохранён" "MyHome" "$(uci -q get wireless.default_radio0.ssid)"
check "radio1 ssid разведён" "MyHome-5G" "$(uci -q get wireless.default_radio1.ssid)"
check "radio0 key сохранён" "secretpass" "$(uci -q get wireless.default_radio0.key)"
check "radio1 key сохранён" "secretpass" "$(uci -q get wireless.default_radio1.key)"

# Повторный запуск не должен ничего ломать (идемпотентность).
sh "$STATE/51-pejir-wifi-dualband"
check "идемпотентность: radio1 band" "5g" "$(uci -q get wireless.radio1.band)"
check "идемпотентность: radio1 ssid" "MyHome-5G" "$(uci -q get wireless.default_radio1.ssid)"

echo "OK: wifi-config.sh"

# --- Сценарий 2: секции названы наоборот (radio1 = MT7603E) ---------------
# На живом устройстве имена секций wireless достались от стока, поэтому
# опора только на имя секции была бы ошибкой: полосы выставляются по
# найденному по PCI device ID устройству.
STATE2="$(mktemp -d)"
export UCI_STATE="$STATE2"
mkdir -p "$STATE2"
cat > "$STATE2/wireless" <<'EOF'
config wifi-device 'radio1'
	option type 'mac80211'
	option path '1e140000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0'
	option band '2g'
	option channel '1'
	option htmode 'HT20'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'Home24'
	option encryption 'psk2'
	option key 'pass24'
	option disabled '0'

config wifi-device 'radio0'
	option type 'mac80211'
	option path '1e140000.pcie/pci0000:00/0000:00:01.0/0000:02:00.0'
	option band '2g'
	option channel '6'
	option htmode 'HT20'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'Home24'
	option encryption 'psk2'
	option key 'pass24'
	option disabled '0'
EOF

setup "$STATE2" "0000:00:00.0"
sh "$STATE2/51-pejir-wifi-dualband"

# MT7603E (0000:01:00.0) должен остаться 2.4 ГГц независимо от имени секции.
check "перепутанные имена: 2.4 ГГц-радио band" "2g" \
	"$(uci -q get wireless.radio1.band)"
check "перепутанные имена: 2.4 ГГц-радио channel" "1" \
	"$(uci -q get wireless.radio1.channel)"
# MT7612E (0000:02:00.0) должен получить 5 ГГц.
check "перепутанные имена: 5 ГГц-радио band" "5g" \
	"$(uci -q get wireless.radio0.band)"
check "перепутанные имена: 5 ГГц-радио channel" "36" \
	"$(uci -q get wireless.radio0.channel)"
check "перепутанные имена: 5 ГГц-радио htmode" "VHT80" \
	"$(uci -q get wireless.radio0.htmode)"
check "перепутанные имена: ssid 5 ГГц разведён" "Home24-5G" \
	"$(uci -q get wireless.default_radio0.ssid)"
check "перепутанные имена: ssid 2.4 ГГц сохранён" "Home24" \
	"$(uci -q get wireless.default_radio1.ssid)"

echo "OK: wifi-config.sh (перепутанные имена секций)"

# --- Сценарий 3: другая топология PCIe (смена ядра) -----------------------
# Топология PCIe меняется между ядрами: upstream-скрипт миграции для mt7621
# (05-wifi-migrate) переписывает пути при обновлении. Поэтому option path
# должен ВЫЧИСЛЯТЬСЯ из sysfs, а не быть захардкоженным.
STATE3="$(mktemp -d)"
export UCI_STATE="$STATE3"
mkdir -p "$STATE3"
cat > "$STATE3/wireless" <<'EOF'
config wifi-device 'radio0'
	option type 'mac80211'
	option path '1e140000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0'
	option band '2g'
	option channel '1'
	option htmode 'HT20'

config wifi-iface 'default_radio0'
	option device 'radio0'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyHome'
	option encryption 'psk2'
	option key 'secretpass'
	option disabled '0'

config wifi-device 'radio1'
	option type 'mac80211'
	option path '1e140000.pcie/pci0000:00/0000:00:01.0/0000:02:00.0'
	option band '2g'
	option channel '6'
	option htmode 'HT20'

config wifi-iface 'default_radio1'
	option device 'radio1'
	option network 'lan'
	option mode 'ap'
	option ssid 'MyHome'
	option encryption 'psk2'
	option key 'secretpass'
	option disabled '0'
EOF

setup "$STATE3" "0000:00:01.0"
sh "$STATE3/51-pejir-wifi-dualband"

check "смена топологии: radio1 band" "5g" "$(uci -q get wireless.radio1.band)"
check "смена топологии: radio1 channel" "36" "$(uci -q get wireless.radio1.channel)"
# path переписан на реальный из sysfs
check "смена топологии: radio1 path" \
	"1e140000.pcie/pci0000:00/0000:00:01.0/0000:02:00.0" \
	"$(uci -q get wireless.radio1.path)"
check "смена топологии: radio0 path" \
	"1e140000.pcie/pci0000:00/0000:00:01.0/0000:01:00.0" \
	"$(uci -q get wireless.radio0.path)"

echo "OK: wifi-config.sh (смена топологии PCIe)"

# --- Сценарий 4: пустого конфига нет (первая загрузка) --------------------
STATE4="$(mktemp -d)"
export UCI_STATE="$STATE4"
mkdir -p "$STATE4"
setup "$STATE4" "0000:00:00.0"
sh "$STATE4/51-pejir-wifi-dualband"

check "первая загрузка: radio0 band" "2g" "$(uci -q get wireless.radio0.band)"
check "первая загрузка: radio1 band" "5g" "$(uci -q get wireless.radio1.band)"
check "первая загрузка: radio1 htmode" "VHT80" "$(uci -q get wireless.radio1.htmode)"
check "первая загрузка: radio0 path" \
	"1e140000.pcie/pci0000:00/0000:00:00.0/0000:01:00.0" \
	"$(uci -q get wireless.radio0.path)"
check "первая загрузка: radio1 path" \
	"1e140000.pcie/pci0000:00/0000:00:00.0/0000:02:00.0" \
	"$(uci -q get wireless.radio1.path)"

echo "OK: wifi-config.sh (первая загрузка, конфига нет)"

rm -rf "$STATE" "$STATE2" "$STATE3" "$STATE4"
