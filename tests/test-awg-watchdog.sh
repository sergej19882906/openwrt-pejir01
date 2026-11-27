#!/bin/sh
# Тест: сторож AWG-туннеля возвращает интернет на LTE, если туннель
# завис.
#
# Дефект, который закрывает тест: когда весь трафик роутера идёт через
# AmneziaWG (у пира route_allowed_ips=1), маршрут по умолчанию
# указывает в туннель. Если туннель завис - интернет пропадает совсем,
# и пользователь выключает туннель руками (проверено на устройстве:
# после этого VPN пропадал совсем).
#
# Сторож должен: перезапускать молчащий туннель, а если он не оживает -
# снимать маршрут по умолчанию через туннель, чтобы трафик ушёл на LTE.
# И не вмешиваться, если трафик через туннель не идёт.

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

WATCH="$DEFAULT_TREE/package/pejir-awg/root/usr/libexec/pejir-awg-watch"
WATCH_INIT="$DEFAULT_TREE/package/pejir-awg/root/etc/init.d/50-pejir-awg-watch"
MK="$DEFAULT_TREE/package/pejir-awg/Makefile"

for f in "$WATCH" "$WATCH_INIT" "$MK"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1. сторож установлен в образ ----------------------------------------
grep -q "pejir-awg-watch" "$MK" && ok "сторож устанавливается пакетом pejir-awg" \
	|| fail "сторож не устанавливается пакетом pejir-awg"

# --- 2. ключевые действия в коде -----------------------------------------
grep -q "ip route del default dev" "$WATCH" && ok "сторой снимает маршрут по умолчанию через туннель" \
	|| fail "сторой не снимает маршрут по умолчанию - интернет не вернётся"
grep -q "ifup" "$WATCH" && ok "сторой перезапускает молчащий туннель" \
	|| fail "сторой не перезапускает молчащий туннель"
grep -q "ip route show default dev" "$WATCH" && ok "сторой работает только когда трафик идёт через туннель" \
	|| fail "сторой не проверяет наличие маршрута через туннель"

# --- 3. функциональная проверка ------------------------------------------
WORK="${PEJIR_AWG_WATCH_TEST:-/tmp/pejir-awg-watch-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/ubus" <<'EOF'
#!/bin/sh
case "$*" in
	*"network.interface.Home status"*)
		echo '{ "up": true, "l3_device": "awg0" }'
		;;
	*)
		echo '{}'
		;;
esac
EOF

cat > "$WORK/bin/awg" <<'EOF'
#!/bin/sh
# Хендшейка нет - туннель молчит.
if [ "$1" = "show" ] && [ "$2" = "Home" ] && [ "$3" = "latest-handshakes" ]; then
	echo ""
fi
EOF

cat > "$WORK/bin/ip" <<EOF
#!/bin/sh
# Режим маршрута задаётся файлом: tunnel - трафик идёт через туннель,
# lte - маршрута через туннель нет.
mode="\$(cat "$WORK/route-mode" 2>/dev/null)"
if [ "\$1" = "route" ] && [ "\$2" = "show" ]; then
	case "\$*" in
		*"dev awg0"*)
			[ "\$mode" = "tunnel" ] && echo "default dev awg0 proto static scope link"
			;;
		*)
			echo "default via 192.168.0.1 dev eth1 metric 30"
			;;
	esac
	exit 0
fi
if [ "\$1" = "route" ] && [ "\$2" = "del" ]; then
	echo "route-deleted" >> "$WORK/actions.log"
	exit 0
fi
exit 0
EOF

cat > "$WORK/bin/uci" <<'EOF'
#!/bin/sh
case "$*" in
	*"show network"*)
		echo "network.Home=interface"
		echo "network.Home.proto=amneziawg"
		exit 0
		;;
	*"network.Home.proto"*)
		echo "amneziawg"
		exit 0
		;;
	*"network.Home.perenio_awg_watch_restart"*)
		echo "${WATCH_RESTART:-1}"
		exit 0
		;;
esac
exit 1
EOF

cat > "$WORK/bin/ifup" <<EOF
#!/bin/sh
echo "ifup \$*" >> "$WORK/actions.log"
exit 0
EOF

cat > "$WORK/bin/logger" <<EOF
#!/bin/sh
echo "\$*" >> "$WORK/log.log"
exit 0
EOF

cat > "$WORK/bin/date" <<'EOF'
#!/bin/sh
echo 1000000
EOF

chmod +x "$WORK/bin"/*

# первая проверка: туннель молчит - сторой перезапускает интерфейс
echo "tunnel" > "$WORK/route-mode"
PATH="$WORK/bin:$PATH" PEJIR_AWG_WATCH_FAILS=2 PEJIR_AWG_WATCH_COUNT_DIR="$WORK/count" WATCH_RESTART=1 sh "$WATCH" --once >/dev/null 2>&1
if grep -q "ifup Home" "$WORK/actions.log" 2>/dev/null; then
	ok "сторой перезапускает интерфейс, когда туннель молчит"
else
	fail "сторой не перезапустил интерфейс при молчащем туннеле"
fi
if grep -q "route-deleted" "$WORK/actions.log" 2>/dev/null; then
	fail "сторой снял маршрут слишком рано (до лимита попыток)"
else
	ok "маршрут снимается не раньше лимита попыток"
fi

# вторая проверка: туннель всё ещё молчит - маршрут снимается
PATH="$WORK/bin:$PATH" PEJIR_AWG_WATCH_FAILS=2 PEJIR_AWG_WATCH_COUNT_DIR="$WORK/count" WATCH_RESTART=1 sh "$WATCH" --once >/dev/null 2>&1
if grep -q "route-deleted" "$WORK/actions.log" 2>/dev/null; then
	ok "сторой снимает маршрут через туннель - трафик возвращается на LTE"
else
	fail "сторой не снял маршрут после серии неудачных проверок"
fi

# третья проверка: без флага разрушительного перезапуска сторой его не делает
rm -f "$WORK/actions.log"
echo "tunnel" > "$WORK/route-mode"
PATH="$WORK/bin:$PATH" PEJIR_AWG_WATCH_FAILS=2 PEJIR_AWG_WATCH_COUNT_DIR="$WORK/count" \
	WATCH_RESTART="" sh "$WATCH" --once >/dev/null 2>&1
if grep -q "ifdown" "$WORK/actions.log" 2>/dev/null; then
	fail "сторой делает разрушительный перезапуск без явного флага"
else
	ok "сторой не перезапускает туннель без флага (перезапуск только по флагу)"
fi

# четвёртая проверка: маршрута через туннель нет - сторой не вмешивается
rm -f "$WORK/actions.log"
echo "lte" > "$WORK/route-mode"
PATH="$WORK/bin:$PATH" PEJIR_AWG_WATCH_COUNT_DIR="$WORK/count" WATCH_RESTART=1 sh "$WATCH" --once >/dev/null 2>&1
if [ -s "$WORK/actions.log" ]; then
	fail "сторой вмешался, хотя трафик через туннель не идёт"
else
	ok "сторой не вмешивается, если трафик через туннель не идёт"
fi

if [ "$FAILED" -eq 0 ]; then
	echo "PASS: сторож AWG возвращает интернет на LTE при зависшем туннеле"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
