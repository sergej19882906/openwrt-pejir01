#!/bin/sh
# Тест: авточистка зависших файлов "*-concatenated" в очереди smstools3.
#
# Дефект, который закрывает тест: smstools3 не может разобрать служебный
# файл сборки многочастевых PDU (16-битные ID у GM510) и оставляет его
# навсегда. В журнале каждые 33 секунды появляется "GM510: Message 0,
# not enough storage space." - ошибка вводит в заблуждение (память SIM
# свободна, SMS приходят нормально).

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

INIT="$DEFAULT_TREE/package/pejir-sms/root/etc/init.d/43-pejir-spool-clean"
MAKEFILE="$DEFAULT_TREE/package/pejir-sms/Makefile"

[ -f "$INIT" ] || { echo "FAIL: нет файла $INIT"; exit 1; }
[ -f "$MAKEFILE" ] || { echo "FAIL: нет файла $MAKEFILE"; exit 1; }

grep -q "43-pejir-spool-clean" "$MAKEFILE" \
	&& ok "init-скрипт устанавливается в образ" \
	|| fail "init-скрипт не установлен в образ"

grep -q "START=93" "$INIT" \
	&& ok "скрипт стартует после smsd (START=93)" \
	|| fail "у скрипта неверный START"

grep -q "extra_command \"watch\"" "$INIT" \
	&& ok "есть команда watch для фонового цикла" \
	|| fail "нет команды watch - цикл чистки не запустить"

# --- функциональная проверка ----------------------------------------------
WORK="${PEJIR_SPOOL_TEST:-/tmp/pejir-spool-clean-test}"
rm -rf "$WORK"
mkdir -p "$WORK/pool/incoming" "$WORK/pool/sent" "$WORK/bin"

# Свежий файл сборки - трогать нельзя (сообщение ещё собирается).
printf 'fresh\n' > "$WORK/pool/incoming/GM510-concatenated"
# Зависший файл - старше 10 минут.
printf 'stale\n' > "$WORK/pool/incoming/OLD-concatenated"
printf 'stale\n' > "$WORK/pool/sent/OLD-concatenated"
# Обычное сообщение - не трогаем.
printf 'msg\n' > "$WORK/pool/incoming/GM510.abc123"

# Подставляем мок: stat отдаёт старое время для файлов OLD-*.
cat > "$WORK/bin/stat" <<'EOF'
#!/bin/sh
# stat -c %Y <файл> - для файлов с OLD в имени отдаём время час назад.
f=""
for a in "$@"; do
	case "$a" in
	-*) ;;
	*) f="$a" ;;
	esac
done
case "$f" in
*OLD*) echo $(( $(date +%s) - 7200 )) ;;
*) echo $(date +%s) ;;
esac
EOF
chmod +x "$WORK/bin/stat"

cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/logger"

PATH="$WORK/bin:$PATH" \
PEJIR_SPOOL_POOL="$WORK/pool" \
PEJIR_SPOOL_MAX_AGE=600 \
PEJIR_SPOOL_CLEAN_PID="$WORK/pid" \
PEJIR_SPOOL_SELF="$INIT" \
sh -c ". '$INIT'; cleanup" >"$WORK/out.log" 2>&1

[ -f "$WORK/pool/incoming/OLD-concatenated" ] \
	&& fail "зависший файл не удалён" \
	|| ok "зависший файл сборки удалён"

[ -f "$WORK/pool/sent/OLD-concatenated" ] \
	&& fail "зависший файл в sent не удалён" \
	|| ok "зависший файл в sent удалён"

[ -f "$WORK/pool/incoming/GM510-concatenated" ] \
	&& ok "свежий файл сборки не тронут (сообщение ещё собирается)" \
	|| fail "свежий файл сборки удалён - многочастевые SMS будут теряться"

[ -f "$WORK/pool/incoming/GM510.abc123" ] \
	&& ok "обычное сообщение не тронуто" \
	|| fail "обычное сообщение удалено"

if [ "$FAILED" -eq 0 ]; then
	echo "Все проверки пройдены"
	exit 0
fi
echo "Провалено проверок: $FAILED"
exit 1
