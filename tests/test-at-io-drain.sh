#!/bin/sh
# Тест: AT-обмен не залипает и не отдаёт ответ предыдущей команды.
#
# Дефект, который закрывает тест: atinout читает из порта всё, что там
# уже лежит, и сразу выходит. Хвост от предыдущей команды (в порт ходят
# модем, сторож AT-порта, smsd и демон сигнала) приводил к тому, что
# ответ приходил на СЛЕДУЮЩУЮ команду: первая попытка выглядела пустой,
# helper делал ещё две с паузой по 2 с - и страница LuCI висела 7 секунд
# (измерено на устройстве: pejir-modem-ctl pin-status = 7.15 с).
#
# Теперь перед каждой командой буфер порта очищается (pejir-at-drain),
# и ответ приходит сразу: AT+CSQ на устройстве - 0.04 с.
#
# Функциональная часть проверяет именно это: мок atinout отдаёт остаток
# буфера, если он не пуст (то есть ответ предыдущей команды). С
# очисткой буфера ответ свежий.

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

DRAIN="$DEFAULT_TREE/package/pejir-lte-base/root/usr/libexec/pejir-at-drain"
MODEM_CTL="$DEFAULT_TREE/package/pejir-lte-base/root/usr/libexec/pejir-modem-ctl"
MDM_AT="$DEFAULT_TREE/package/pejir-lte-base/root/usr/bin/mdm-at"
BAND="$DEFAULT_TREE/package/pejir-lte-base/root/usr/libexec/pejir-band"
LTE_INIT="$DEFAULT_TREE/package/pejir-lte-base/root/etc/init.d/47-pejir-lte"

for f in "$DRAIN" "$MODEM_CTL" "$MDM_AT" "$BAND" "$LTE_INIT"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1. helper очистки буфера существует и работает ------------------------
grep -q "cat" "$DRAIN" && ok "pejir-at-drain читает порт" \
	|| fail "pejir-at-drain не читает порт"
grep -q "timeout" "$DRAIN" && ok "pejir-at-drain ограничен по времени" \
	|| fail "pejir-at-drain не ограничен по времени - может висеть вечно"

# helper обязан быть установлен в образ
if grep -q "pejir-at-drain" "$DEFAULT_TREE/package/pejir-lte-base/Makefile"; then
	ok "pejir-at-drain устанавливается пакетом pejir-lte-base"
else
	fail "pejir-at-drain не установлен пакетом pejir-lte-base"
fi

# --- 2. все AT-места чистят буфер перед обменом ---------------------------
for f in "$MODEM_CTL" "$MDM_AT" "$BAND" "$LTE_INIT"; do
	if grep -q "AT_DRAIN" "$f"; then
		ok "$(basename "$f"): буфер порта очищается перед обменом"
	else
		fail "$(basename "$f"): буфер порта не очищается - ответ будет от предыдущей команды"
	fi
done

# --- 3. функциональная проверка: ответ свежий, а не от предыдущей команды -
WORK="${PEJIR_AT_DRAIN_WORK:-/tmp/pejir-at-drain-test}"
rm -rf "$WORK"
mkdir -p "$WORK/bin"

cat > "$WORK/bin/atinout" <<'EOF'
#!/usr/bin/env python3
"""Мок atinout: отдаёт остаток буфера порта, если он не пуст.

Так ведёт себя настоящий atinout: он читает из порта всё, что там
лежит, и сразу выходит. Непустой буфер = ответ на ПРЕДЫДУЩУЮ команду.
"""
import os
import sys

path, dev = sys.argv[1], sys.argv[2]
try:
    with open(dev, "rb") as f:
        pending = f.read()
except OSError:
    pending = b""

if pending.strip():
    sys.stdout.write(pending.decode("utf-8", "replace"))
    sys.exit(0)

sys.stdout.write("\r\nFRESH\r\n")
EOF
chmod +x "$WORK/bin/atinout"

cat > "$WORK/bin/stty" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$WORK/bin/stty"

# Мок cat: на последовательном порту чтение съедает байты, на обычном
# файле - нет. Поэтому "порт" здесь опустошаем при чтении.
cat > "$WORK/bin/cat" <<'EOF'
#!/bin/sh
for f in "$@"; do
	case "$f" in
		-) : ;;
		*) : > "$f" 2>/dev/null ;;
	esac
done
exit 0
EOF
chmod +x "$WORK/bin/cat"

# порт-мок: в буфере лежит "хвост" предыдущей команды
printf 'STALE\r\n' > "$WORK/ttyFAKE"

out="$(PATH="$WORK/bin:$PATH" PEJIR_AT_PORT="$WORK/ttyFAKE" sh "$MODEM_CTL" pin-status 2>&1)"
case "$out" in
	*STALE*)
		fail "modem-ctl: получен ответ предыдущей команды (STALE) - буфер не очищен" ;;
	*)
		ok "modem-ctl: ответ свежий (хвост буфера отброшен)"
		;;
esac

case "$out" in
	*"не ответил"*)
		fail "modem-ctl: модем не ответил - команда не отправлена"
		;;
	*)
		ok "modem-ctl: команда ушла модему"
		;;
esac

# буфер после обмена должен быть пустым
if [ -s "$WORK/ttyFAKE" ]; then
	fail "буфер порта не пуст после обмена"
else
	ok "буфер порта пуст после обмена"
fi

if [ "$FAILED" -eq 0 ]; then
	echo "PASS: AT-обмен без залипания и без ответов предыдущей команды"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
