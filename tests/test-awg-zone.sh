#!/bin/sh
# Тест: AWG-интерфейс в отдельной зоне файрвола с masquerading.
#
# Дефект, который закрывает тест: интерфейс amneziawg попадал в зону
# lan. Трафик клиентов LAN (телефон, ноутбук) уходил в туннель с
# адресом 192.168.2.x, а сервер AmneziaWG такую подсеть не знает и по
# ней не делает NAT - пакеты терялись, и страницы не открывались.
# Собственный трафик роутера работал: у него адрес интерфейса
# туннеля, и NAT делает ядро.
#
# Проверено на устройстве: после перевода интерфейса в отдельную зону
# с masq=1 трафик клиента LAN выходит через VPN (внешний адрес
# совпадает с адресом выхода туннеля, а не LTE).

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

ZONE_HELPER="$DEFAULT_TREE/package/pejir-awg/root/usr/libexec/pejir-awg-zone"
AWG_INIT="$DEFAULT_TREE/package/pejir-awg/root/etc/init.d/pejir-awg"
MK="$DEFAULT_TREE/package/pejir-awg/Makefile"

for f in "$ZONE_HELPER" "$AWG_INIT" "$MK"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1. helper устанавливается и вызывается при старте --------------------
grep -q "pejir-awg-zone" "$MK" && ok "helper зоны устанавливается пакетом pejir-awg" \
	|| fail "helper зоны не устанавливается"
grep -q "pejir-awg-zone" "$AWG_INIT" && ok "helper зоны вызывается при старте" \
	|| fail "helper зоны не вызывается - зона не настроится сама"

# --- 2. в зоне есть masquerading и обрезка MSS ----------------------------
grep -q 'masq="1"' "$ZONE_HELPER" && ok "зона wan с masquerading (трафик клиентов NAT-ится в туннель)" \
	|| fail "в зоне wan нет masquerading - трафик клиентов не NAT-ится"
grep -q 'mtu_fix="1"' "$ZONE_HELPER" && ok "зона wan с mtu_fix (обрезка MSS под MTU туннеля)" \
	|| fail "в зоне wan нет mtu_fix"

# Туннель должен быть именно в зоне wan: fw4 для lan переходит только в
# accept_to_wan и accept_to_lan, туннель в отдельной зоне уходил в DROP.
grep -q 'ZONE="wan"' "$ZONE_HELPER" && ok "интерфейс переносится в зону wan (переход lan -> wan разрешён)" \
	|| fail "интерфейс переносится не в зону wan - трафик клиентов уйдёт в DROP"

# --- 3. интерфейс убирается из зоны lan -----------------------------------
grep -q "del_list" "$ZONE_HELPER" && ok "интерфейс убирается из зоны lan" \
	|| fail "интерфейс остаётся в зоне lan - клиентский трафик пойдёт без NAT"

# --- 4. функциональная проверка на моках ----------------------------------
WORK="${PEJIR_AWG_ZONE_TEST:-/tmp/pejir-awg-zone-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/uci" <<'EOF'
#!/bin/sh
# Минимальный мок uci: сетка firewall с зоной lan, где есть Home.
STATE="$WORK/uci.state"
touch "$STATE"

[ "$1" = "-q" ] && shift

ZONE_FLAG="${ZONE_FLAG-1}"

case "$1" in
	show)
		case "$2" in
			network)
				echo "network.Home=interface"
				echo "network.Home.proto=amneziawg"
				;;
			firewall)
				echo "firewall.@zone[0]=zone"
				echo "firewall.@zone[0].network='lan' 'Home'"
				echo "firewall.@zone[1]=zone"
				echo "firewall.@zone[1].name='wan'"
				echo "firewall.@zone[1].network='wan' 'lte'"
				;;
		esac
		exit 0
		;;
	get)
		key="$2"
		case "$key" in
			firewall.@zone\[0\].network) echo "lan Home" ;;
			firewall.@zone\[1\].network) echo "wan lte" ;;
			network.Home.proto) echo "amneziawg" ;;
			network.Home.perenio_awg_wan_zone) echo "$ZONE_FLAG" ;;
			*) exit 1 ;;
		esac
		exit 0
		;;
	set|add_list|del_list|delete)
		echo "$1 $2" >> "$WORK/uci.actions"
		exit 0
		;;
	commit)
		exit 0
		;;
esac
exit 1
EOF

cat > "$WORK/bin/logger" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/log.log"
exit 0
EOF

cat > "$WORK/bin/firewall" <<EOF
#!/bin/sh
echo "firewall-reload" >> "$WORK/actions.log"
exit 0
EOF

mkdir -p "$WORK/etc/init.d"
cat > "$WORK/etc/init.d/firewall" <<EOF
#!/bin/sh
echo "firewall-reload" >> "$WORK/actions.log"
exit 0
EOF
chmod +x "$WORK/etc/init.d/firewall"

chmod +x "$WORK/bin"/*

# helper жёстко прописывает /etc/init.d/firewall - подменяем через симлин
# в /tmp не получится, поэтому проверяем только решения по uci.
out="$(PATH="$WORK/bin:$PATH" WORK="$WORK" sh "$ZONE_HELPER" 2>&1)"

if grep -q "del_list firewall.@zone\[0\].network" "$WORK/uci.actions" 2>/dev/null; then
	ok "интерфейс убирается из зоны lan"
else
	fail "интерфейс не убирается из зоны lan"
fi

if grep -q "firewall.@zone\[1\].network" "$WORK/uci.actions" 2>/dev/null; then
	ok "интерфейс добавляется в зону wan"
else
	fail "интерфейс не добавляется в зону wan"
fi

# --- 5. без явного флага helper не трогает файрвол ------------------------
# Перенос интерфейса в зону wan затрагивает файрвол целиком: если что-то
# пойдёт не так, роутер останется без доступа по LAN. Поэтому действие
# включается только флагом network.<интерфейс>.perenio_awg_wan_zone=1.
rm -f "$WORK/uci.actions" "$WORK/actions.log"
out="$(PATH="$WORK/bin:$PATH" WORK="$WORK" ZONE_FLAG="" sh "$ZONE_HELPER" 2>&1)"
if [ -s "$WORK/uci.actions" ]; then
	fail "без флага helper всё равно меняет файрвол"
else
	ok "без флага helper не трогает файрвол"
fi

if [ "$FAILED" -eq 0 ]; then
	echo "PASS: AWG-интерфейс в зоне wan с masquerading"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
