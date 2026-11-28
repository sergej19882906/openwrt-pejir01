#!/bin/sh
# Тест: восстановление конфигурации сети с USB-флешки (extroot).
#
# Дефект, который закрывает тест: после прошивки релиза .73 конфиг сети
# (/etc/config/network) вернулся к дефолту OpenWrt - LAN 192.168.1.1,
# секций lte/lte6 и туннеля Home нет. Причина: после прошивки extroot не
# поднялся (потерялся fstab), система загрузилась с NAND, а настройки
# владельца целы на флешке - в <раздел>/upper/etc/config.
#
# Скрипт 12-pejir-config-guard должен:
#   * восстановить /etc/config/network (и fstab), если текущий конфиг -
#     стоковый дефолт, а в сохранённом есть секция lte;
#   * не трогать ничего, если конфиг и так нормальный;
#   * не восстанавливать сохранённый файл без секции lte (это не
#     пользовательский конфиг).

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

SCRIPT="$DEFAULT_TREE/package/pejir-ota/root/etc/init.d/12-pejir-config-guard"
MOCK_UCI="$(dirname "$0")/mock-uci.py"

[ -f "$SCRIPT" ] || { echo "FAIL: нет файла $SCRIPT"; exit 1; }
[ -f "$MOCK_UCI" ] || { echo "FAIL: нет мока $MOCK_UCI"; exit 1; }

WORK="${PEJIR_GUARD_TEST:-/tmp/pejir-config-guard-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin" "$WORK/dev" "$WORK/state" "$WORK/etc/config"

# --- Моки ----------------------------------------------------------------
cat > "$WORK/bin/uci" <<EOF
#!/bin/sh
exec python3 "$MOCK_UCI" "\$@"
EOF
cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
# block info: наш "раздел" - ext4
cat > "$WORK/bin/block" <<'EOF'
#!/bin/sh
case "$1" in
	info)
		shift
		if [ -f "$1" ]; then
			echo "/dev/sda1:"
			echo '	TYPE="ext4"'
		else
			exit 1
		fi
		;;
esac
EOF
# mount: "монтируем" раздел - копируем содержимое каталога <dev>.tree
cat > "$WORK/bin/mount" <<'EOF'
#!/bin/sh
args=""
for a in "$@"; do
	case "$a" in
		-*) ;;
		*) args="$args $a" ;;
	esac
done
# последние два не-опции: раздел и точка монтирования
mnt="$(echo "$args" | awk '{print $NF}')"
dev="$(echo "$args" | awk '{print $(NF-1)}')"
tree="$(dirname "$dev")/$(basename "$dev").tree"
[ -d "$tree" ] || exit 1
mkdir -p "$mnt" || exit 1
cp -a "$tree/." "$mnt/" || exit 1
exit 0
EOF
cat > "$WORK/bin/umount" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/"*

# "Флешка" с сохранённым upper.
mkdir -p "$WORK/dev/sda1.tree/upper/etc/config"
cat > "$WORK/dev/sda1.tree/upper/etc/config/network" <<'EOF'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.168.2.1'
	option netmask '255.255.255.0'

config interface 'lte'
	option proto 'dhcp'
	option device 'usb0'

config interface 'Home'
	option proto 'amneziawg'
	option private_key 'key'
EOF
cat > "$WORK/dev/sda1.tree/upper/etc/config/fstab" <<'EOF'
config global
	option auto_swap '1'

config mount
	option uuid '1234-5678'
	option target '/overlay'
	option fstype 'ext4'
	option enabled '1'
EOF
: > "$WORK/dev/sda1"

# --- 1. Статические проверки --------------------------------------------
grep -q 'START=12' "$SCRIPT" && ok "скрипт стартует до сети (START=12)" \
	|| fail "скрипт не стартует до сети - восстановленный конфиг применится с задержкой"
grep -q 'upper/etc/config/network' "$SCRIPT" && ok "скрипт ищет сохранённый upper на флешке" \
	|| fail "скрипт не ищет сохранённый upper"
grep -q 'config interface' "$SCRIPT" && ok "проверяется наличие секции lte в сохранённом файле" \
	|| fail "нет проверки секции lte - можно затереть настройки владельца"

# --- 2. Функциональная проверка -----------------------------------------
seed_state() {
	cat > "$WORK/state/network" <<EOF
config interface 'lan'
	option proto 'static'
	option ipaddr '$1'
	option netmask '255.255.255.0'
EOF
}

run_script() {
	PATH="$WORK/bin:$PATH" \
	UCI_STATE="$WORK/state" \
	PEJIR_GUARD_DEVDIR="$WORK/dev" \
	PEJIR_GUARD_MNT="$WORK/mnt" \
	PEJIR_GUARD_NETCONF="$WORK/etc/config/network" \
	PEJIR_GUARD_FSTAB="$WORK/etc/config/fstab" \
	PEJIR_GUARD_WAIT=0 \
	sh -c ". '$SCRIPT'; start" >"$WORK/out.log" 2>&1
}

# 2.1. Конфиг стоковый - восстанавливаем пользовательский
seed_state "192.168.1.1"
rm -f "$WORK/etc/config/network" "$WORK/etc/config/fstab"
run_script
grep -q "config interface 'lte'" "$WORK/etc/config/network" 2>/dev/null \
	&& ok "конфиг сети восстановлен с флешки (секция lte вернулась)" \
	|| fail "конфиг сети не восстановлен"
grep -q "config interface 'Home'" "$WORK/etc/config/network" 2>/dev/null \
	&& ok "туннель Home (AmneziaWG) восстановлен" \
	|| fail "туннель Home не восстановлен"
[ -f "$WORK/etc/config/fstab" ] && ok "fstab восстановлен - extroot заработает после перезагрузки" \
	|| fail "fstab не восстановлен"

# 2.2. Конфиг нормальный - ничего не трогаем
seed_state "192.168.2.1"
rm -f "$WORK/etc/config/network" "$WORK/etc/config/fstab"
run_script
[ ! -f "$WORK/etc/config/network" ] && ok "нормальный конфиг не перезаписан" \
	|| fail "конфиг перезаписан, хотя он не стоковый"

# 2.3. В сохранённом файле нет секции lte - это не конфиг владельца
cat > "$WORK/dev/sda1.tree/upper/etc/config/network" <<'EOF'
config interface 'lan'
	option proto 'static'
	option ipaddr '192.168.2.1'
EOF
seed_state "192.168.1.1"
rm -f "$WORK/etc/config/network" "$WORK/etc/config/fstab"
run_script
[ ! -f "$WORK/etc/config/network" ] && ok "сохранённый файл без секции lte не подставляется" \
	|| fail "подставлен сохранённый файл без секции lte"

if [ "$FAILED" -eq 0 ]; then
	echo "Все проверки пройдены"
	exit 0
fi
echo "Провалено проверок: $FAILED"
exit 1
