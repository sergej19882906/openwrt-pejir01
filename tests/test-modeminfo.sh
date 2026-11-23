#!/bin/sh
# Тест пакета modeminfo (страница LuCI "Модем").
#
# Ловит две реальные причины, по которым страница показывала пустоту:
#
#   1) в образе нет секции `config modeminfo` - /usr/bin/modeminfo берёт
#      список секций из uci и при пустом списке выдаёт {"modem": []},
#      то есть на странице нет НИ ОДНОГО поля. Секцию создаёт
#      uci-defaults 60-perenio-modeminfo (порт ttyUSB2 - подтверждённый
#      AT-порт GM510 на этой плате).
#
#   2) atinout не переводит порт в raw-режим, а модем без raw-режима
#      на AT не отвечает (проверено на живом устройстве: без stty -
#      тишина, с `stty -F <port> 115200 raw -echo` - ответ). Поэтому
#      перед чтением модема нужен stty.
#
# Плюс мелочь: профиль GOSUN читал decimail из несуществующей секции
# @generic - команда падала с ошибкой "integer expression expected".

set -u

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	DEFAULT_PKG="$OW_TEST/package/modeminfo"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/modeminfo"
fi
PKG="${PEJIR_PKG:-$DEFAULT_PKG}"
DEFAULTS="$PKG/root/etc/uci-defaults/60-perenio-modeminfo"
SCRIPTS="$PKG/root/usr/share/modeminfo/scripts"
LIST="$PKG/root/usr/share/modeminfo/modem.list"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$DEFAULTS" "$SCRIPTS/modeminfo" "$SCRIPTS/GOSUN" "$LIST"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) uci-defaults создаёт секцию config modeminfo ----------------------
sh -n "$DEFAULTS" 2>/dev/null && ok "uci-defaults: синтаксис корректен" \
	|| fail "uci-defaults: ошибка синтаксиса"

if grep -q "modeminfo.@modeminfo\[0\]" "$DEFAULTS"; then
	ok "uci-defaults: создаёт секцию modeminfo.@modeminfo[0]"
else
	fail "uci-defaults: нет секции modeminfo.@modeminfo[0]"
fi

if grep -q "device='/dev/ttyUSB2'" "$DEFAULTS"; then
	ok "uci-defaults: порт по умолчанию /dev/ttyUSB2"
else
	fail "uci-defaults: нет порта по умолчанию /dev/ttyUSB2"
fi

# Мок uci: проверяем, что скрипт действительно создаёт секцию и НЕ трогает
# уже настроенную.
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/uci" <<'MOCK'
#!/bin/sh
# Мок uci: get -q modeminfo.@modeminfo[0].device печатает значение из
# переменной окружения MOCK_DEVICE (пусто - не настроено), остальные
# вызовы пишутся в лог.
case " $* " in
	*" get "*)
		[ -n "${MOCK_DEVICE:-}" ] && echo "$MOCK_DEVICE"
		exit 0
		;;
esac
echo "$*" >> "$MOCK_LOG"
exit 0
MOCK
chmod +x "$TMP/uci"

MOCK_LOG="$TMP/log1" MOCK_DEVICE="" PATH="$TMP:$PATH" sh "$DEFAULTS" >/dev/null 2>&1
if grep -q "set modeminfo.@modeminfo\[0\]=modeminfo" "$TMP/log1" 2>/dev/null; then
	ok "uci-defaults: при пустом конфиге секция создаётся"
else
	fail "uci-defaults: при пустом конфиге секция НЕ создана"
fi

if grep -q "set modeminfo.@modeminfo\[0\].device=/dev/ttyUSB2" "$TMP/log1" 2>/dev/null; then
	ok "uci-defaults: прописан порт /dev/ttyUSB2"
else
	fail "uci-defaults: порт не прописан"
fi

MOCK_LOG="$TMP/log2" MOCK_DEVICE="/dev/ttyUSB1" PATH="$TMP:$PATH" sh "$DEFAULTS" >/dev/null 2>&1
if [ -s "$TMP/log2" ]; then
	fail "uci-defaults: перезаписал уже настроенный порт (лог: $(cat "$TMP/log2"))"
else
	ok "uci-defaults: уже настроенный порт не трогает"
fi

# --- 2) stty перед atinout ----------------------------------------------
n_atinout=$(grep -c "atinout" "$SCRIPTS/modeminfo")
n_stty=$(grep -c "stty -F \"\$DEVPORT\" 115200 raw -echo" "$SCRIPTS/modeminfo")
if [ "$n_stty" -ge 1 ] && [ "$n_stty" -ge "$n_atinout" ]; then
	ok "scripts/modeminfo: stty вызывается перед каждым atinout ($n_stty/$n_atinout)"
else
	fail "scripts/modeminfo: stty есть в $n_stty местах, atinout - в $n_atinout"
fi

# --- 3) профиль GM510 в списке модемов -----------------------------------
if grep -q "^305a1415;GOSUN" "$LIST"; then
	ok "modem.list: GM510 (305a:1415) отнесён к профилю GOSUN"
else
	fail "modem.list: нет записи 305a1415;GOSUN"
fi

for cmd in "AT+EEMGINFO?" "AT+ZCHIPTEMP?" "+ZGETICCID"; do
	if grep -qF "$cmd" "$SCRIPTS/GOSUN.at"; then
		ok "GOSUN.at: есть команда $cmd"
	else
		fail "GOSUN.at: нет команды $cmd"
	fi
done

# --- 4) профиль GOSUN включён в сборку -----------------------------------
MKFILE="$PKG/Makefile"
if [ -f "$MKFILE" ]; then
	if grep -q "^\$(eval \$(call SerialPlugin,gosun," "$MKFILE"; then
		ok "Makefile modeminfo: профиль GOSUN включён (не закомментирован)"
	else
		fail "Makefile modeminfo: профиль GOSUN не включён - в образе не будет GOSUN.at"
	fi

	if grep -q "60-perenio-modeminfo" "$MKFILE"; then
		ok "Makefile modeminfo: uci-defaults ставится в образ"
	else
		fail "Makefile modeminfo: uci-defaults не ставится в образ"
	fi
fi

# build.sh обязан включать пакет с профилем GOSUN
BUILD_SH="${OW_TEST:-$DEFAULT_PKG}/../../../build.sh"
for cand in /workspace/openwrt-pejir01/build.sh; do
	[ -f "$cand" ] && BUILD_SH="$cand"
done
if [ -f "$BUILD_SH" ]; then
	if grep -q "CONFIG_PACKAGE_modeminfo-serial-gosun=y" "$BUILD_SH"; then
		ok "build.sh: modeminfo-serial-gosun включён в сборку"
	else
		fail "build.sh: нет CONFIG_PACKAGE_modeminfo-serial-gosun=y"
	fi
fi

# --- 5) профиль GOSUN читал decimail из несуществующей секции ------------
if grep -q "@generic" "$SCRIPTS/GOSUN"; then
	fail "GOSUN: читает decimail из несуществующей секции @generic"
else
	ok "GOSUN: decimail читается из @general"
fi


# --- 6) сквозной прогон /usr/bin/modeminfo на моках ----------------------
# Главный баг: LuCI создаёт ИМЕНОВАННЫЙ раздел ("config modeminfo
# 'modeminfo'"), а скрипт искал только анонимные (@modeminfo[0]) - список
# секций оказывался пустым, и на странице не было ни одного поля.
# Проверяем оба вида раздела: и именованный, и анонимный.
run_modeminfo() {
	# $1 - имя раздела в выводе "uci show" ("modeminfo" или "@modeminfo[0]")
	# $2 - ожидаемое значение device
	T=$(mktemp -d)
	mkdir -p "$T/usr/share/modeminfo/scripts" "$T/usr/share/libubox" "$T/usr/bin" "$T/bin"

	cp "$PKG/root/usr/share/modeminfo/modeminfo" "$T/usr/share/modeminfo/"
	cp "$PKG/root/usr/share/modeminfo/modem.list" "$T/usr/share/modeminfo/"
	cp "$PKG/root/usr/share/modeminfo/scripts/"* "$T/usr/share/modeminfo/scripts/" 2>/dev/null
	cp "$PKG/root/usr/bin/modeminfo" "$T/usr/bin/modeminfo"

	# Абсолютные пути в скриптах -> во временный префикс. Shebang ->
	# bash: скрипты пакета используют bashism ("function name() {"),
	# на устройстве это работает за счёт busybox ash с bash-совместимостью,
	# а /bin/sh в песочнице - dash, который такой синтаксис не понимает.
	for f in "$T/usr/bin/modeminfo" "$T/usr/share/modeminfo/modeminfo" \
	         "$T/usr/share/modeminfo/scripts/modeminfo"; do
		[ -f "$f" ] || continue
		sed -i "s#/usr/share/modeminfo#$T/usr/share/modeminfo#g; s#/usr/share/libubox/jshn.sh#$T/usr/share/libubox/jshn.sh#g" "$f"
		sed -i "1s#.*#!/bin/bash#" "$f"
	done

	cat > "$T/usr/share/libubox/jshn.sh" <<'JSHN'
json_load() { JSON_IN="$1"; }
json_dump() { printf '%s\n' "$JSON_IN"; }
JSHN

	cat > "$T/bin/uci" <<'UCI'
#!/bin/sh
[ "$1" = "-q" ] && shift
cmd="$1"; shift
case "$cmd" in
	show)
		cat "$MOCK_UCI_SHOW"
		exit 0
		;;
	get)
		opt="${1##*.}"
		case "$opt" in
			device) echo "$MOCK_DEVICE" ;;
			decimail) echo "1" ;;
			*) echo "" ;;
		esac
		exit 0
		;;
esac
exit 0
UCI

	cat > "$T/bin/atinout" <<'ATINOUT'
#!/bin/sh
cat <<'EOF'
OK
+COPS: 0,1,"MTS RUS",7
+CREG: 2,1,"1234","56789A"
+CSQ: 16,99
EOF
ATINOUT
	chmod +x "$T/bin/uci" "$T/bin/atinout"

	cat > "$T/show.txt" <<EOF
modeminfo.general=general
modeminfo.general.index='1'
modeminfo.general.decimail='1'
modeminfo.general.delay='30'
modeminfo.$1=modeminfo
modeminfo.$1.device='$2'
EOF

	OUT=$(MOCK_UCI_SHOW="$T/show.txt" MOCK_DEVICE="$2" PATH="$T/bin:$PATH" \
		bash "$T/usr/bin/modeminfo" 2>/dev/null)
	rm -rf "$T"
	printf '%s' "$OUT"
}

# именованный раздел (как создаёт LuCI)
out_named=$(run_modeminfo modeminfo /dev/ttyUSB2)
if printf '%s' "$out_named" | grep -q '"modem"'; then
	if printf '%s' "$out_named" | grep -q '"rssi"'; then
		ok "modeminfo (именованный раздел): данные модера получены"
	else
		fail "modeminfo (именованный раздел): нет данных модема: $out_named"
	fi
else
	fail "modeminfo (именованный раздел): пустой вывод: $out_named"
fi

# анонимный раздел
out_anon=$(run_modeminfo '@modeminfo[0]' /dev/ttyUSB2)
if printf '%s' "$out_anon" | grep -q '"rssi"'; then
	ok "modeminfo (анонимный раздел): данные модема получены"
else
	fail "modeminfo (анонимный раздел): нет данных модема: $out_anon"
fi

# --- dispatcher: ветка qmi_mode, отсутствие kill -9, timeout на atinout -------
# Ловит: 1) [ $qmi_mode ] - truthy-сравнение, при пустом значении из uci ветка
# уходила не туда; 2) cleanup()/kill -9 (pgrep atinout) убивали чужие процессы:
# другие экземпляры modeminfo и ВСЕ бюджетные atinout, в том числе из LuCI
# приложения atcommands; 3) atinout висит бесконечно на молчащем порту.
DISPATCH="$PKG/root/usr/share/modeminfo/modeminfo"

if grep -Eq '\[ "\$qmi_mode" = "1" \]' "$DISPATCH"; then
	ok "dispatcher: ветка qmi_mode сравнивается как строка (= \"1\")"
else
	fail "dispatcher: нет [ \"\$qmi_mode\" = \"1\" ] - truthy-сравнение [ \$qmi_mode ] ложно при пустом значении"
fi

if grep -q 'pgrep' "$DISPATCH"; then
	fail "dispatcher: остался kill -9 (pgrep atinout) - убивает чужие процессы"
else
	ok "dispatcher: kill -9 (pgrep atinout) удалён"
fi

if grep -q 'cleanup()' "$DISPATCH"; then
	fail "dispatcher: осталась cleanup() с убийством процессов"
else
	ok "dispatcher: cleanup() с kill -9 удалена"
fi

if grep -q 'timeout 90 atinout' "$SCRIPTS/modeminfo"; then
	ok "scripts/modeminfo: вызовы atinout обёрнуты в timeout 90"
else
	fail "scripts/modeminfo: atinout без timeout - зависает на молчащем порту"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты modeminfo пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
