#!/bin/sh
# Тест USSD-запроса (AT+CUSD) на странице SMS.
#
# Проверяются три вещи:
#   1) наличие helper'а /usr/libexec/pejir-ussd, команды AT+CUSD и
#      варианта --restart-lte;
#   2) права в ACL - без гранта exec LuCI ответит "Permission denied"
#      (ровно как было с диагностикой);
#   3) ПОВЕДЕНИЕ helper'а на псевдо-терминале: эмулируем модем,
#      который отвечает на AT и на AT+CUSD, и ждём, что в stdout
#      придёт текст ответа оператора.
#
# Тест герметичен: внешний модем не нужен, работа идёт через pty.

set -u

if [ -n "${OW_TEST:-}" ] && [ -d "$OW_TEST/package/luci-app-perenio" ]; then
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
fi
PKG="${PEJIR_PKG:-$DEFAULT_PKG}"
HELPER="$PKG/root/usr/libexec/pejir-ussd"
ACL="$PKG/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
JS="$PKG/htdocs/luci-static/resources/view/perenio/sms.js"
PO="$PKG/po/ru/luci-app-perenio.po"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$HELPER" "$ACL" "$JS" "$PO"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) helper -------------------------------------------------------------
if grep -q "AT+CUSD" "$HELPER"; then
	ok "helper: есть команда AT+CUSD"
else
	fail "helper: нет команды AT+CUSD"
fi

if grep -q -- "--restart-lte" "$HELPER"; then
	ok "helper: есть вариант --restart-lte (перезапуск LTE)"
else
	fail "helper: нет варианта --restart-lte"
fi

if grep -q "/etc/pejir/at-port" "$HELPER"; then
	ok "helper: использует подтверждённый порт из /etc/pejir/at-port"
else
	fail "helper: не использует /etc/pejir/at-port"
fi

if grep -q "smsd" "$HELPER"; then
	ok "helper: останавливает smsd на время обмена"
else
	fail "helper: не освобождает порт от smsd"
fi

sh -n "$HELPER" 2>/dev/null && ok "helper: синтаксис shell корректен" \
	|| fail "helper: ошибка синтаксиса shell"

# --- 2) ACL ----------------------------------------------------------------
if grep -qF '"/usr/libexec/pejir-ussd"' "$ACL"; then
	ok "ACL: есть грант exec на /usr/libexec/pejir-ussd"
else
	fail "ACL: нет гранта exec - LuCI отдаст Permission denied"
fi

python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$ACL" 2>/dev/null \
	&& ok "ACL: валидный JSON" || fail "ACL: JSON невалиден"

# --- 3) страница -----------------------------------------------------------
for pat in "USSD request" "ussd-code" "ussd-result" "pejir-ussd"; do
	if grep -qF "$pat" "$JS"; then
		ok "sms.js: есть '$pat'"
	else
		fail "sms.js: нет '$pat'"
	fi
done

if grep -q "stdout" "$JS"; then
	ok "sms.js: используется stdout из ответа fs.exec"
else
	fail "sms.js: нет разбора stdout - будет показан [object Object]"
fi

# --- 4) переводы -----------------------------------------------------------
for s in "USSD request" "USSD code" "Operator response" "Send request"; do
	if grep -qF "msgid \"$s\"" "$PO"; then
		t=$(grep -A1 -F "msgid \"$s\"" "$PO" | sed -n 's/^msgstr "\(.*\)"$/\1/p' | head -1)
		if [ -n "$t" ] && [ "$t" != "$s" ]; then
			ok "po: '$s' -> '$t'"
		else
			fail "po: у '$s' пустой перевод"
		fi
	else
		fail "po: нет строки '$s'"
	fi
done

# --- 5) поведение helper'а на псевдо-терминале ------------------------------
if python3 - "$HELPER" <<'PY'
import os, pty, subprocess, sys, threading, time

helper = sys.argv[1]
master, slave = pty.openpty()
slave_name = os.ttyname(slave)

stop = False

def modem():
	buf = b''
	while not stop:
		try:
			data = os.read(master, 4096)
		except OSError:
			break
		if not data:
			break
		buf += data
		while b'\r' in buf:
			cmd, buf = buf.split(b'\r', 1)
			cmd = cmd.strip()
			if cmd == b'AT':
				os.write(master, b'\r\nOK\r\n')
			elif cmd.startswith(b'AT+CUSD'):
				os.write(master, b'\r\n+CUSD: 1,"Balance 100",0\r\n')
			elif cmd.startswith(b'AT+CGDCONT'):
				os.write(master, b'\r\nOK\r\n')

t = threading.Thread(target=modem, daemon=True)
t.start()

p = subprocess.run([helper, '-p', slave_name, '*100#'],
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                   timeout=60)
stop = True

out = p.stdout.decode('utf-8', 'replace').strip()
rc = p.returncode

if rc != 0:
	print("FAIL: helper вернул код %d, stdout=%r stderr=%r" % (rc, out, p.stderr.decode('utf-8','replace')[:200]))
	sys.exit(1)

if 'Balance 100' not in out:
	print("FAIL: в ответе нет текста оператора: %r" % out)
	sys.exit(1)

print("OK: helper вернул ответ оператора: %r" % out)
PY
then
	:
else
	fail "helper: неверное поведение на эмуляторе модема"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты USSD пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
