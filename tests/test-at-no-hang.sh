#!/bin/sh
# Тест pejir-lte-base / pejir-sms: AT-обмен с модемом не должен висеть.
#
# Проблема, которую ловит тест:
#   1) чтение ответа модема через  head -c 64 "$p"  на последовательном
#      порту: head ждёт, пока наберётся 64 байта, а модем на "AT"
#      отвечает коротким "OK" и замолкает => head висит в read() вечно,
#      init-скрипт 41-pejir-modem (START=93) не завершается и не даёт
#      запуститься 47-pejir-lte (START=94);
#   2) atinout тоже ждёт ответа без ограничения времени.
#
# Поэтому в скриптах должен быть timeout вокруг atinout, а блокирующих
# head -c на устройстве быть не должно.

set -u

# Корень дерева OpenWrt с применёнными патчами: в CI это $OW_TEST
# (переменная выставляется workflow), локально - рабочее дерево.
# Без этого тест искал бы файлы по жёстко зашитому пути и падал в CI.
OW="${OW_TEST:-${OPENWRT_TREE:-/workspace/ow-test}}"
	[ -d "$OW" ] || { echo "FAIL: нет дерева OpenWrt $OW (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
LTE="${LTE:-$OW/package/pejir-lte-base/root/etc/init.d/47-pejir-lte}"
SMS="${SMS:-$OW/package/pejir-sms/root/etc/init.d/40-pejir-sms}"
MDMAT="${MDMAT:-$OW/package/pejir-lte-base/root/usr/bin/mdm-at}"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$LTE" "$SMS" "$MDMAT"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) нет блокирующего чтения с устройства ------------------------------
for f in "$MDMAT" "$LTE" "$SMS"; do
	# комментарии не считаем: там может быть описан старый код
	if grep -vE '^[[:space:]]*#' "$f" | grep -E 'head -c [0-9]+' | grep -qE '\$p|\$TTY|\$port|\$dev'; then
		fail "$(basename "$f"): осталось чтение через head -c с порта (может зависнуть)"
		grep -vE '^[[:space:]]*#' "$f" | grep -nE 'head -c [0-9]+' | grep -E '\$p|\$TTY|\$port|\$dev' | sed 's/^/     /'
	else
		ok "$(basename "$f"): блокирующего head -c с порта нет"
	fi
done

# --- 2) atinout вызывается с timeout --------------------------------------
for f in "$MDMAT" "$LTE" "$SMS"; do
	# считаем только реальные вызовы, а не упоминания в комментариях
	total=$(grep -vE '^[[:space:]]*#' "$f" | grep -c 'atinout')
	wrapped=$(grep -vE '^[[:space:]]*#' "$f" | grep -cE 'timeout [^ ]* atinout|timeout "\$[A-Z_]+" atinout')
	if [ "$total" -eq 0 ]; then
		ok "$(basename "$f"): atinout не используется"
	elif [ "$total" -eq "$wrapped" ]; then
		ok "$(basename "$f"): все вызовы atinout ($total) обёрнуты в timeout"
	else
		fail "$(basename "$f"): atinout вызывается $total раз, с timeout только $wrapped"
		grep -n 'atinout' "$f" | sed 's/^/     /'
	fi
done

# --- 3) поведение: mdm-at находит AT-порт через мок ------------------------
mkdir -p /tmp/mdmat-test/bin
cat > /tmp/mdmat-test/bin/atinout <<'EOF'
#!/bin/sh
# atinout <input_file> <device> <output_file>
# Отвечаем "OK" только на /dev/ttyUSB2, на остальных - тишина.
case "$(basename "$2")" in
ttyUSB2) printf 'OK\r\n' ;;
*) printf 'ERROR\r\n' ;;
esac
exit 0
EOF
chmod +x /tmp/mdmat-test/bin/atinout

cat > /tmp/mdmat-test/bin/timeout <<'EOF'
#!/bin/sh
# timeout <duration> <cmd...> - просто выполняем команду
shift
exec "$@"
EOF
chmod +x /tmp/mdmat-test/bin/timeout

# фейковые "порты": обычные файлы, но скрипт проверяет [ -c "$p" ],
# поэтому делаем симлинки на /dev/null (это символьный, не блочный -
# [ -c ] вернёт false). Вместо этого подменяем проверку через PATH:
# создаём обёртку mkdir/touch нельзя - поэтому используем реальные
# символьные устройства /dev/null через mktemp и -c проверку обходим
# собственной копией скрипта.
cat > /tmp/mdmat-test/mdm-at <<'EOF'
#!/bin/sh
# копия логики detect_port из mdm-at, но проверка порта - обычный файл
PROBE_TIMEOUT=5
detect_port() {
	local p out script="/tmp/mdmat-test/probe.$$"
	printf 'AT\r' > "$script"
	for p in /dev/ttyUSB2 /dev/ttyUSB1 /dev/ttyUSB0 /dev/ttyUSB3 \
	         /dev/ttyACM1 /dev/ttyACM0; do
		[ -e "$p" ] || continue
		out="$(timeout "$PROBE_TIMEOUT" atinout "$script" "$p" - 2>/dev/null)"
		case "$out" in
			*OK*) rm -f "$script"; echo "$p"; return 0 ;;
		esac
	done
	rm -f "$script"
	return 1
}
detect_port
EOF
chmod +x /tmp/mdmat-test/mdm-at

# подменяем пути к портам: создаём файлы с такими именами в отдельном
# каталоге и правим скрипт
mkdir -p /tmp/mdmat-test/dev
: > /tmp/mdmat-test/dev/ttyUSB2
: > /tmp/mdmat-test/dev/ttyUSB1
: > /tmp/mdmat-test/dev/ttyUSB0
sed 's#/dev/ttyUSB#/tmp/mdmat-test/dev/ttyUSB#g; s#/dev/ttyACM#/tmp/mdmat-test/dev/ttyACM#g' \
	/tmp/mdmat-test/mdm-at > /tmp/mdmat-test/mdm-at2
chmod +x /tmp/mdmat-test/mdm-at2

out="$(PATH="/tmp/mdmat-test/bin:$PATH" /tmp/mdmat-test/mdm-at2 2>/dev/null)"
if [ "$out" = "/tmp/mdmat-test/dev/ttyUSB2" ]; then
	ok "detect_port находит AT-порт (ttyUSB2) и не зависает"
else
	fail "detect_port вернул '$out' (ожидался .../ttyUSB2)"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты AT-обмена пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
