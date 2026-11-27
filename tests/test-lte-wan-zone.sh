#!/bin/sh
# Тест: LTE-интерфейсы в зоне wan и DHCP на lte/lte6.
#
# Дефекты, которые закрывает тест:
#   1. network.lte оставался с протоколом "none"/пустым - интерфейс не
#      получал адрес и шлюз от оператора, интернет не раздавался клиентам LAN.
#   2. Зона wan включала lte/lte6 только в конфиге, но правила fw4
#      применяются при старте firewall (START=19), а LTE стартует позже
#      (START=94) - без перезагрузки правил в зоне wan интерфейсов LTE не
#      было, NAT не работал.
#   3. У зоны wan мог быть выключен маскарадинг (masq=0) - ответы из
#      интернета не возвращались к клиентам.
#
# Проверка идёт на моках uci и init-скрипта firewall (init-скрипт
# вызывается через переменную PEJIR_FW_INIT, чтобы его можно было
# подменить в тесте).

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

LTE_INIT="$DEFAULT_TREE/package/pejir-lte-base/root/etc/init.d/47-pejir-lte"
MOCK_UCI="$(dirname "$0")/mock-uci-fw.py"

[ -f "$LTE_INIT" ] || { echo "FAIL: нет файла $LTE_INIT"; exit 1; }
[ -f "$MOCK_UCI" ] || { echo "FAIL: нет мока $MOCK_UCI"; exit 1; }

WORK="${PEJIR_LTE_WAN_TEST:-/tmp/pejir-lte-wan-test}"
rm -rf "$WORK"
mkdir -p "$WORK"
export UCI_FW_STATE="$WORK/uci.state"

# --- 1. Статические проверки --------------------------------------------
grep -q 'proto=dhcp' "$LTE_INIT" && ok "в скрипте есть выставление proto=dhcp" \
	|| fail "нет выставления proto=dhcp - LTE может остаться без адреса"
grep -q 'proto=dhcpv6' "$LTE_INIT" && ok "в скрипте есть выставление proto=dhcpv6 для lte6" \
	|| fail "нет выставления proto=dhcpv6 для lte6"
grep -q 'add_list firewall.@zone\[$i\].network' "$LTE_INIT" && ok "lte/lte6 добавляются в список сети зоны wan" \
	|| fail "интерфейсы LTE не добавляются в зону wan"
grep -q 'masq=1' "$LTE_INIT" && ok "для зоны wan обеспечен маскарадинг" \
	|| fail "у зоны wan не включён маскарадинг - NAT не работает"
grep -q 'fwinit.*reload\|reload.*fw4' "$LTE_INIT" && ok "правила fw4 перечитываются после правки зоны" \
	|| fail "нет перезагрузки правил fw4 - зона wan останется без LTE"

# --- 2. Функциональная проверка на моках ---------------------------------
cat > "$WORK/state.seed" <<'EOF'
network.lte=interface
network.lte.device=usb0
network.lte6=interface
network.lte6.proto=dhcpv6
network.lte6.device=usb0
firewall.@zone[0]=zone
firewall.@zone[0].name=lan
firewall.@zone[0].network=lan
firewall.@zone[1]=zone
firewall.@zone[1].name=wan
firewall.@zone[1].network=wan
firewall.@zone[1].masq=0
EOF
cp "$WORK/state.seed" "$UCI_FW_STATE"

# Мок init-скрипта firewall: пишет маркер, что правила перечитаны
cat > "$WORK/firewall" <<'EOF'
#!/bin/sh
echo "$@" >> "$PEJIR_FW_MARKER"
EOF
chmod +x "$WORK/firewall"
export PEJIR_FW_MARKER="$WORK/firewall.reloaded"
export PEJIR_FW_INIT="$WORK/firewall"

cat > "$WORK/run.sh" <<EOF
#!/bin/sh
. "$LTE_INIT"
log() { :; }
uci() { python3 "$MOCK_UCI" "\$@"; }
ensure_lte_section eth1
ensure_firewall
EOF
chmod +x "$WORK/run.sh"

sh "$WORK/run.sh" >"$WORK/run.log" 2>&1 || { cat "$WORK/run.log"; fail "скрипт с моками упал"; }

# 2a. Протокол без значения приводится к dhcp (иначе у LTE нет адреса
# и шлюза, и интернет не раздаётся клиентам LAN)
proto="$(python3 "$MOCK_UCI" -q get network.lte.proto 2>/dev/null)"
[ "$proto" = "dhcp" ] && ok "network.lte.proto: пусто -> dhcp" \
	|| fail "network.lte.proto = '$proto' (ожидался dhcp)"

dev="$(python3 "$MOCK_UCI" -q get network.lte.device 2>/dev/null)"
[ "$dev" = "eth1" ] && ok "network.lte.device приведён к eth1" \
	|| fail "network.lte.device = '$dev' (ожидался eth1)"

metric="$(python3 "$MOCK_UCI" -q get network.lte.metric 2>/dev/null)"
[ -n "$metric" ] && ok "у network.lte есть metric ($metric)" \
	|| fail "у network.lte нет metric"

# 2b. lte/lte6 в зоне wan
net="$(python3 "$MOCK_UCI" -q get firewall.@zone[1].network 2>/dev/null)"
echo "$net" | tr ' ' '\n' | grep -qx lte && ok "lte в зоне wan" \
	|| fail "lte не в зоне wan (network='$net')"
echo "$net" | tr ' ' '\n' | grep -qx lte6 && ok "lte6 в зоне wan" \
	|| fail "lte6 не в зоне wan (network='$net')"
echo "$net" | tr ' ' '\n' | grep -qx wan && ok "интерфейс wan не потерян" \
	|| fail "интерфейс wan пропал из зоны (network='$net')"

# 2c. маскарадинг
masq="$(python3 "$MOCK_UCI" -q get firewall.@zone[1].masq 2>/dev/null)"
[ "$masq" = "1" ] && ok "в зоне wan включён маскарадинг" \
	|| fail "masq зоны wan = '$masq' (ожидался 1)"

# 2d. правила fw4 перечитаны
[ -s "$PEJIR_FW_MARKER" ] && ok "правила firewall перезагружены после правки зоны" \
	|| fail "правила firewall не перезагружены - зона wan без LTE"

# 2e. Явный выбор владельца не перетирается: proto=none остаётся
cp "$WORK/state.seed" "$UCI_FW_STATE"
python3 "$MOCK_UCI" set network.lte.proto=none >/dev/null 2>&1
sh "$WORK/run.sh" >/dev/null 2>&1
proto="$(python3 "$MOCK_UCI" -q get network.lte.proto 2>/dev/null)"
[ "$proto" = "none" ] && ok "явно выключенный пользователем LTE (proto=none) не включаем молча" \
	|| fail "proto=none перезаписан на '$proto'"

# 2f. идемпотентность: повторный вызов не дублирует интерфейсы
cp "$UCI_FW_STATE" "$WORK/state.after1"
sh "$WORK/run.sh" >/dev/null 2>&1
net2="$(python3 "$MOCK_UCI" -q get firewall.@zone[1].network 2>/dev/null)"
n_lte="$(echo "$net2" | tr ' ' '\n' | grep -cx lte)"
[ "$n_lte" = "1" ] && ok "повторный запуск не дублирует lte в зоне" \
	|| fail "lte встречается $n_lte раз(а) в зоне wan"

echo
if [ "$FAILED" -eq 0 ]; then
	echo "ИТОГ: все проверки пройдены"
	exit 0
fi
echo "ИТОГ: провалено проверок: $FAILED"
exit 1
