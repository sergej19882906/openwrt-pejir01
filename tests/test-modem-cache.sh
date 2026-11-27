#!/bin/sh
# Тест: страницы LuCI не "тупят" (модем, СМС, батарея).
#
# Дефекты, которые закрывает тест:
#   1. Страница "Модем" и значок модема в шапке запускали
#      /usr/bin/modeminfo прямо из браузера. Обмен с модемом занимает до
#      90 секунд - страница висела, а AT-порт постоянно конфликтовал с
#      smsd (сбивалась отправка SMS).
#   2. Страница "СМС" каждые 20 секунд перечитывала все файлы во всех
#      четырёх каталогах spool (до 50 файлов в каждом - до 200 запросов
#      fs.read через rpcd за цикл) - страница заметно подтормаживала.
#   3. Страница "Батарея" обновлялась слишком часто (15 с при трёх
#      запросах на цикл).

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

CACHE_INIT="$DEFAULT_TREE/package/modeminfo/root/etc/init.d/pejir-modem-cache"
MODEM_MK="$DEFAULT_TREE/package/modeminfo/Makefile"
MODEM_ACL="$DEFAULT_TREE/package/luci-app-modeminfo/root/usr/share/rpcd/acl.d/luci-app-modeminfo.json"
MODEM_MAIN="$DEFAULT_TREE/package/luci-app-modeminfo/htdocs/luci-static/resources/view/modem/main.js"
MODEM_HW="$DEFAULT_TREE/package/luci-app-modeminfo/htdocs/luci-static/resources/view/modem/hw.js"
MODEM_IND="$DEFAULT_TREE/package/luci-app-modeminfo/htdocs/luci-static/resources/modem-indicator.js"
MODEM_STATUS="$DEFAULT_TREE/package/luci-app-modeminfo/htdocs/luci-static/resources/view/status/include/26_modeminfo.js"
SMS_JS="$DEFAULT_TREE/package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/sms.js"
BATT_JS="$DEFAULT_TREE/package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/battery.js"

for f in "$CACHE_INIT" "$MODEM_MK" "$MODEM_ACL" "$MODEM_MAIN" "$MODEM_HW" \
	"$MODEM_IND" "$MODEM_STATUS" "$SMS_JS" "$BATT_JS"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1. Фоновый сборщик данных модема ------------------------------------
grep -q "pejir-modem-cache" "$MODEM_MK" && ok "init-скрипт сборщика устанавливается пакетом modeminfo" \
	|| fail "init-скрипт сборщика не устанавливается"
grep -q "pejir-modem.json" "$CACHE_INIT" && ok "сборщик пишет файл состояния /tmp/pejir-modem.json" \
	|| fail "сборщик не пишет файл состояния"
grep -q 'extra_command "refresh"' "$CACHE_INIT" && ok "есть команда refresh (обновление в фоне)" \
	|| fail "нет команды refresh - кнопка обновления не сработает"
grep -q 'extra_command "status"' "$CACHE_INIT" && ok "есть команда status" \
	|| fail "нет команды status"

# Опрос модема не должен идти, когда в очереди SMS лежит неотправленное
# сообщение (AT-порт занят smsd).
grep -q "SMS_OUTBOX" "$CACHE_INIT" && ok "сборщик учитывает очередь исходящих SMS" \
	|| fail "сборщик не смотрит очередь SMS - опрос модема сбивает отправку"

# --- 2. Браузер больше не запускает modeminfo -----------------------------
for f in "$MODEM_MAIN" "$MODEM_HW" "$MODEM_IND" "$MODEM_STATUS"; do
	if grep -q "exec_direct('/usr/bin/modeminfo')" "$f"; then
		fail "$(basename "$f") запускает modeminfo из браузера - страница будет висеть"
	else
		ok "$(basename "$f") не запускает modeminfo из браузера"
	fi
	if grep -q "pejir-modem.json" "$f"; then
		ok "$(basename "$f") читает готовый файл состояния"
	else
		fail "$(basename "$f") не читает файл состояния"
	fi
done

# --- 3. ACL ---------------------------------------------------------------
grep -q '"/tmp/pejir-modem.json"' "$MODEM_ACL" && ok "ACL разрешает читать файл состояния" \
	|| fail "ACL не разрешает читать /tmp/pejir-modem.json - страница не покажет данные"
grep -q '"/etc/init.d/pejir-modem-cache"' "$MODEM_ACL" && ok "ACL разрешает запускать сборщик" \
	|| fail "ACL не разрешает запуск сборщика - кнопка обновления не сработает"
if grep -q '"/usr/bin/modeminfo"' "$MODEM_ACL"; then
	fail "ACL всё ещё разрешает запуск modeminfo из браузера"
else
	ok "ACL больше не разрешает запуск modeminfo из браузера"
fi

# --- 4. Страница СМС: кеш вместо чтения всех файлов -----------------------
grep -q "SPOOL_CACHE" "$SMS_JS" && ok "страница СМС кеширует разобранные сообщения" \
	|| fail "страница СМС перечитывает все файлы заново - она тупит"
grep -q "files.slice(0, 30)" "$SMS_JS" && ok "страница СМС читает не больше 30 файлов за каталог" \
	|| fail "страница СМС читает слишком много файлов за раз"

# --- 5. Страница батареи: реже --------------------------------------------
grep -q "}, this), 30);" "$BATT_JS" && ok "страница батареи обновляется раз в 30 с" \
	|| fail "страница батареи обновляется слишком часто"

# --- 6. Значок модема: реже и без AT-порта -------------------------------
grep -q "poll.add(updateIndicator, 30)" "$MODEM_IND" && ok "значок модема обновляется раз в 30 с" \
	|| fail "значок модема опрашивается слишком часто"

# --- 7. Функциональная проверка сборщика на моках -------------------------
WORK="${PEJIR_MODEM_CACHE_TEST:-/tmp/pejir-modem-cache-test}"
rm -rf "$WORK"
mkdir -p "$WORK"

cat > "$WORK/modeminfo" <<'EOF'
#!/bin/sh
echo '{"modem":[{"csq_per":50,"cops":"MegaFon","mode":"LTE"}]}'
EOF
chmod +x "$WORK/modeminfo"

cat > "$WORK/run.sh" <<EOF
#!/bin/sh
extra_command() { :; }
. "$CACHE_INIT"
case "\$1" in
collect) collect ;;
refresh) refresh ;;
esac
EOF
chmod +x "$WORK/run.sh"

# Сборщик запускает сам себя (команда collect) - для теста это
# обёртка с тем же телом.
cat > "$WORK/self.sh" <<EOF
#!/bin/sh
extra_command() { :; }
. "$CACHE_INIT"
collect
EOF
chmod +x "$WORK/self.sh"

export PEJIR_MODEMINFO_BIN="$WORK/modeminfo"
export PEJIR_MODEM_STATE="$WORK/pejir-modem.json"
export PEJIR_MODEM_LOCK="$WORK/lock"
export PEJIR_SIGNAL_LOCK="$WORK/signal.lock"
export PEJIR_SMS_OUTBOX="$WORK/outbox"
export PEJIR_MODEM_SELF="$WORK/self.sh"
mkdir -p "$PEJIR_SMS_OUTBOX"

sh "$WORK/run.sh" collect >/dev/null 2>&1
if [ -s "$PEJIR_MODEM_STATE" ]; then
	ok "сборщик записывает данные модема в файл"
	grep -q "MegaFon" "$PEJIR_MODEM_STATE" && ok "данные модема сохраняются без искажений" \
		|| fail "данные модема искажены"
else
	fail "сборщик не записал файл состояния"
fi

# Пока в очереди SMS есть сообщение - опрос модема пропускается
rm -f "$PEJIR_MODEM_STATE"
touch "$PEJIR_SMS_OUTBOX/Pending"
sh "$WORK/run.sh" collect >/dev/null 2>&1
[ -f "$PEJIR_MODEM_STATE" ] && fail "опрос модема сделан при непустой очереди SMS" \
	|| ok "опрос модема пропущен, пока в очереди есть SMS"
rm -f "$PEJIR_SMS_OUTBOX/Pending"

# refresh возвращает управление сразу (обмен идёт в фоне)
start="$(date +%s)"
sh "$WORK/run.sh" refresh >/dev/null 2>&1
end="$(date +%s)"
[ $((end - start)) -le 2 ] && ok "refresh возвращает управление сразу" \
	|| fail "refresh блокирует вызов на $((end - start)) с"
sleep 1
[ -s "$PEJIR_MODEM_STATE" ] && ok "после refresh данные появились" \
	|| fail "после refresh данные не появились"

echo
if [ "$FAILED" -eq 0 ]; then
	echo "ИТОГ: все проверки пройдены"
	exit 0
fi
echo "ИТОГ: провалено проверок: $FAILED"
exit 1
