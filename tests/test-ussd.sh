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

if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
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


# Сценарий: ответ оператора приходит в UCS2 (UTF-16BE) - так отвечает
# GM510 на русском тексте. Без декодирования пользователь видит вместо
# ответа "кучу непонятных символов" (мусорные байты).
if python3 - "$HELPER" <<'UCS2CASE'
import os, pty, subprocess, sys, threading

helper = sys.argv[1]
master, slave = pty.openpty()
slave_name = os.ttyname(slave)
stop = False

# Ответ оператора в UCS2: "Баланс" = U+0411 U+0430 ...
text = "Баланс 100"
ucs2 = text.encode('utf-16-be')

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
				# Формат: +CUSD: <status>,"<rspstr>",<dcs>; dcs=15 - UCS2
				body = b'\r\n+CUSD: 1,"' + ucs2 + b'",15\r\n'
				os.write(master, body)
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
	print("FAIL: helper вернул код %d, stdout=%r" % (rc, out))
	sys.exit(1)

if 'Баланс' not in out:
	print("FAIL: ответ в UCS2 не декодирован: %r" % out)
	sys.exit(1)

print("OK: ответ в UCS2 декодирован: %r" % out)
UCS2CASE
then
	:
else
	fail "helper: ответ оператора в UCS2 не декодируется в читаемый текст"
fi

# Сценарий: ответ оператора в UCS2, но модем сообщает DCS=0 (GSM-7).
# Так ведёт себя GM510 на русском тексте: байты ответа - UTF-16BE
# (кириллица 0x04xx), а в DCS модем пишет 0. В ответе без пробелов нет
# байта 0x00, поэтому прежняя эвристика ("нет NUL -> один байт на
# символ") ломала текст на "кучу символов". Эталон - стоковый dcs.sh:
# первая кодовая точка из диапазона кириллицы означает UCS2 независимо
# от того, что модем написал в DCS.
if python3 - "$HELPER" <<'DCSV0CASE'
import os, pty, subprocess, sys, threading

helper = sys.argv[1]
master, slave = pty.openpty()
slave_name = os.ttyname(slave)
stop = False

# "Баланс" без пробелов -> в UCS2 нет байта 0x00
text = "Баланс"
ucs2 = text.encode('utf-16-be')
assert b'\x00' not in ucs2

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
				# dcs=0 - модем сообщает GSM-7, а присылает UCS2
				body = b'\r\n+CUSD: 1,"' + ucs2 + b'",0\r\n'
				os.write(master, body)
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
	print("FAIL: helper вернул код %d, stdout=%r" % (rc, out))
	sys.exit(1)

if 'Баланс' not in out:
	print("FAIL: ответ в UCS2 с DCS=0 не декодирован: %r" % out)
	sys.exit(1)

print("OK: ответ в UCS2 с DCS=0 декодирован: %r" % out)
DCSV0CASE
then
	:
else
	fail "helper: ответ оператора в UCS2 при DCS=0 не декодируется в читаемый текст"
fi

# Сценарий: ответ оператора С ПРЕФИКСОМ-ЗАГОЛОВКОМ и с неверным DCS.
#
# ФАКТ с живого устройства (релиз .56, ответ м��дема GM510):
#
#   +CUSD: 0,"00300002e003700310440002e000d000a04200435043a043b04
#            30043c0430002e00204120430043a0430043d0441043804380020
#            0434043b044f0020044204350431044f002100200416043c043800
#            20002a0038003200320023", 17
#
# То есть:
#   * статус 0, а DCS = 17 (не 15!). Схема по формуле стока
#     (dcs/4)%3 даёт 0 -> GSM-7, и текст разбирался по одному байту
#     на символ -> пользователь видел "набор символов";
#   * первые 34 байта ответа - служебный заголовок оператора
#     ("00300002e003700310440002e000d000a" + "Реклама. "), дальше идёт
#     настоящий UCS-2BE-текст "Вакансии для тебя! Жми *822#".
#
# Значит одного признака "первая кодовая точка кириллическая"
# (патч 0088) мало: первая кодовая точка здесь - мусор из заголовка.
# Нужен разбор, который сам находит в ответе самый длинный участок
# правдоподобного текста.
if python3 - "$HELPER" <<'REALCASE'
import os, pty, subprocess, sys, threading

helper = sys.argv[1]
master, slave = pty.openpty()
slave_name = os.ttyname(slave)
stop = False

# Байты ответа как пришли от модема (без кавычек).
payload = bytes.fromhex(
    "00300002e003700310440002e000d000a04200435043a043b0430043c0430002e0020412"
    "0430043a0430043d04410438043800200434043b044f0020044204350431044f00210020"
    "0416043c04380020002a0038003200320023"
)

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
				# DCS=17 - модем сообщает не UCS2; статус 0.
				body = b'\r\n+CUSD: 0,"' + payload + b'", 17\r\n'
				os.write(master, body)
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
	print("FAIL: helper вернул код %d, stdout=%r" % (rc, out))
	sys.exit(1)

# Ответ оператора начинается с 34 байт служебного заголовка (в нём
# непечатные кодовые точки) - в результат он попасть не должен.
if out != 'Вакансии для тебя! Жми *822#':
	print("FAIL: ответ декодирован неверно: %r" % out)
	sys.exit(1)

bad = [c for c in out if ord(c) > 0x2fff]
if bad:
	print("FAIL: в ответе остались непечатные символы: %r" % out)
	sys.exit(1)

print("OK: ответ с заголовком и DCS=17 декодирован: %r" % out)
REALCASE
then
	:
else
	fail "helper: ответ оператора с заголовком и неверным DCS не декодируется"
fi

# Сценарий: stty возвращает ошибку (на живом устройстве он всегда
# возвращает "unable to perform all requested operations", хотя порт
# рабочий). Helper обязан продолжить обмен и вернуть ответ оператора.
if python3 - "$HELPER" <<'USSDCASE'
import os, pty, subprocess, sys, tempfile, threading

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

t = threading.Thread(target=modem, daemon=True)
t.start()

# mock stty: всегда возвращает ошибку (как на живом устройстве).
# Мок создаётся во ВРЕМЕННОМ каталоге: раньше он клался рядом с helper'ом
# (в дереве пакета), из-за чего попадал в git и в патчи.
mockbin = tempfile.mkdtemp(prefix='pejir-mockbin-')
with open(os.path.join(mockbin, 'stty'), 'w') as f:
	f.write('#!/bin/sh\necho "stty: unable to perform all requested operations" >&2\nexit 1\n')
os.chmod(os.path.join(mockbin, 'stty'), 0o755)

env = dict(os.environ)
env['PATH'] = mockbin + ':' + env['PATH']

p = subprocess.run([helper, '-p', slave_name, '*100#'], stdout=subprocess.PIPE,
                   stderr=subprocess.PIPE, timeout=60, env=env)
stop = True
out = p.stdout.decode('utf-8', 'replace').strip()

if p.returncode != 0:
	print("FAIL: helper прервался из-за ошибки stty (код %d): %r" % (p.returncode, out))
	sys.exit(1)
if 'Balance 100' not in out:
	print("FAIL: ответ оператора не получен при падающем stty: %r" % out)
	sys.exit(1)
print("OK: helper не сломался на ошибке stty, ответ: %r" % out)
USSDCASE
then
	:
else
	fail "helper: падает, когда stty возвращает ошибку"
fi

# --- 6) чистота дерева пакета ----------------------------------------------
# Моки тестов не должны оставаться в дереве пакета: иначе они попадают
# в git-коммиты серии патчей (случилось с .mockbin/stty).
if [ -d "$PKG/root/usr/libexec/.mockbin" ]; then
	fail "в дереве пакета остался тестовый каталог .mockbin - он попадёт в патчи"
else
	ok "в дереве пакета нет тестовых артефактов (.mockbin)"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты USSD пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
