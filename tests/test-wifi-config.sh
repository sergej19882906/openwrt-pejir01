#!/bin/sh
# Проверка pejir_wifi_apply: полосы/каналы ставятся по полю path,
# пользовательские SSID и ключи сохраняются.
#
# Запуск:  sh tests/test-wifi-config.sh

set -e

BASE="$(cd "$(dirname "$0")" && pwd)"
# Корень дерева OpenWrt с применёнными патчами.
# По умолчанию — рабочее дерево, где патчи уже применены.
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
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
	option path '1e140000.pcie/pci0000:00/0000:00:00.1/0000:02:00.0'
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

mkdir -p "$STATE/bin"
cat > "$STATE/bin/uci" <<EOF
#!/bin/sh
exec python3 "$BASE/mock-uci.py" "\$@"
EOF
chmod +x "$STATE/bin/uci"
PATH="$STATE/bin:$PATH"
export PATH

mkdir -p "$STATE/share/pejir"
cp "$OW/package/luci-app-perenio/root/usr/share/pejir/wifi-config.sh" \
   "$STATE/share/pejir/wifi-config.sh"

# Подменяем путь к общему скрипту на тестовый.
sed "s#/usr/share/pejir/wifi-config.sh#$STATE/share/pejir/wifi-config.sh#" \
    "$OW/package/luci-app-perenio/root/etc/uci-defaults/51-pejir-wifi-dualband" \
    > "$STATE/51-pejir-wifi-dualband"

sh "$STATE/51-pejir-wifi-dualband"

fail() { echo "FAIL: $1"; exit 1; }

check() { # $1=описание $2=ожидание $3=факт
	[ "$2" = "$3" ] || fail "$1: ожидалось '$2', получено '$3'"
}

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

# --- Сценарий 2: секции названы наоборот (radio1 = MT7603E) --------------
# На живом устройстве имена секций wireless достались от стока, поэтому
# опора только на имя секции была бы ошибкой: полосы выставляются по path.
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
	option path '1e140000.pcie/pci0000:00/0000:00:00.1/0000:02:00.0'
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

mkdir -p "$STATE2/bin"
cat > "$STATE2/bin/uci" <<EOF
#!/bin/sh
exec python3 "$BASE/mock-uci.py" "\$@"
EOF
chmod +x "$STATE2/bin/uci"
PATH="$STATE2/bin:$PATH"
export PATH

mkdir -p "$STATE2/share/pejir"
cp "$OW/package/luci-app-perenio/root/usr/share/pejir/wifi-config.sh" \
   "$STATE2/share/pejir/wifi-config.sh"
sed "s#/usr/share/pejir/wifi-config.sh#$STATE2/share/pejir/wifi-config.sh#" \
    "$OW/package/luci-app-perenio/root/etc/uci-defaults/51-pejir-wifi-dualband" \
    > "$STATE2/51-pejir-wifi-dualband"

sh "$STATE2/51-pejir-wifi-dualband"

# MT7603E (path .../0000:01:00.0) должен остаться 2.4 ГГц независимо от
# того, как названа секция.
check "перепутанные имена: 2.4 ГГц-радио band" "2g" \
	"$(uci -q get wireless.radio1.band)"
check "перепутанные имена: 2.4 ГГц-радио channel" "1" \
	"$(uci -q get wireless.radio1.channel)"
# MT7612E (path .../0000:02:00.0) должен получить 5 ГГц.
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
rm -rf "$STATE2" "$STATE"
