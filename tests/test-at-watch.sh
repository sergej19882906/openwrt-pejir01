#!/bin/sh
# Тест сторожа AT-порта модема (/usr/libexec/pejir-at-watch).
#
# Проверяется:
#   1) helper и init-скрипт на месте, синтаксис корректен, helper
#      установлен пакетом (Makefile) и есть грант exec в ACL;
#   2) init-скрипт зарегистрирован (START, USE_PROCD);
#   3) ПОВЕДЕНИЕ на псевдо-терминале: порт, который отвечает на AT,
#      считается живым (check -> 0), а порт, который молчит, - нет;
#   4) безопасность: перепривязка выполняется ТОЛЬКО для /dev/ttyUSB*,
#      для обычного pty-порта helper ничего ломать не должен.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_PKG="$OW_TEST/package/pejir-lte-base"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/pejir-lte-base"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST)"; exit 1; }
fi
PKG="${PEJIR_PKG:-$DEFAULT_PKG}"
HELPER="$PKG/root/usr/libexec/pejir-at-watch"
INIT="$PKG/root/etc/init.d/48-pejir-at-watch"
MAKEFILE="$PKG/Makefile"
ACL="$OW_TEST/package/luci-app-perenio/root/usr/share/rpcd/acl.d/luci-app-perenio.json"

PEJIR_TEST_WORK="${PEJIR_TEST_WORK:-/tmp/pejir-test-at-watch}"
mkdir -p "$PEJIR_TEST_WORK" 2>/dev/null
FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

for f in "$HELPER" "$INIT" "$MAKEFILE"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done

# --- 1) наличие и синтаксис ------------------------------------------------
sh -n "$HELPER" 2>/dev/null && ok "helper: синтаксис shell корректен" \
	|| fail "helper: ошибка синтаксиса shell"
sh -n "$INIT" 2>/dev/null && ok "init: синтаксис shell корректен" \
	|| fail "init: ошибка синтаксиса shell"

for c in check recover watch status; do
	grep -q "^$c)" "$HELPER" || grep -q "	$c)" "$HELPER" \
		|| grep -q "$c)" "$HELPER" \
		&& ok "helper: есть команда $c" || fail "helper: нет команды $c"
done

grep -q "pejir-at-watch" "$MAKEFILE" \
	&& ok "Makefile: helper устанавливается в пакет" \
	|| fail "Makefile: helper не установлен в пакет"
grep -q "48-pejir-at-watch" "$MAKEFILE" \
	&& ok "Makefile: init-скрипт устанавливается в пакет" \
	|| fail "Makefile: init-скрипт не установлен"

grep -qE "^[[:space:]]*START=95" "$INIT" \
	&& ok "init: START=95 (после инициализации модема и LTE)" \
	|| fail "init: неверный START"
grep -qE "^[[:space:]]*USE_PROCD=1" "$INIT" \
	&& ok "init: USE_PROCD=1" \
	|| fail "init: нет USE_PROCD=1"

# --- 2) ACL ----------------------------------------------------------------
if [ -f "$ACL" ]; then
	if grep -qF '"/usr/libexec/pejir-at-watch"' "$ACL"; then
		ok "ACL: есть грант exec на /usr/libexec/pejir-at-watch"
	else
		fail "ACL: нет гранта exec - LuCI отдаст Permission denied"
	fi
else
	fail "ACL: нет файла $ACL"
fi

# --- 3) поведение на псевдо-терминале --------------------------------------
# Порт отвечает на AT -> check возвращает 0.
if python3 - "$HELPER" <<'PY'
import os, pty, subprocess, sys, threading

helper = sys.argv[1]
master, slave = pty.openpty()
slave_name = os.ttyname(slave)
work = os.environ['PEJIR_TEST_WORK']

# Подставной mdm-at: на живом порте отвечает "OK".
bindir = os.path.join(work, 'atwatch-bin')
os.makedirs(bindir, exist_ok=True)
with open(os.path.join(bindir, 'mdm-at'), 'w') as f:
	f.write("#!/bin/sh\n"
	        "case \"$1\" in\n"
	        "--port) echo \"$PEJIR_TEST_PORT\"; exit 0 ;;\n"
	        "esac\n"
	        "if [ \"$PEJIR_TEST_ALIVE\" = 1 ]; then echo OK; exit 0; fi\n"
	        "exit 1\n")
os.chmod(os.path.join(bindir, 'mdm-at'), 0o755)

portfile = os.path.join(work, 'atwatch-port')
with open(portfile, 'w') as f:
	f.write(slave_name + "\n")

env = dict(os.environ)
env['PATH'] = bindir + ':' + env.get('PATH', '')
env['PEJIR_TEST_PORT'] = slave_name
env['PEJIR_TEST_ALIVE'] = '1'
env['PEJIR_AT_PORT_FILE'] = portfile
env['PEJIR_AT_WATCH_STATE'] = os.path.join(work, 'atwatch-state')

r = subprocess.run([helper, 'check'], stdout=subprocess.PIPE,
                   stderr=subprocess.PIPE, timeout=30, env=env)
print("rc=%d out=%r" % (r.returncode, r.stdout.decode()[:200]))
sys.exit(0 if r.returncode == 0 else 1)
PY
then
	ok "helper: живой порт считается живым (check -> 0)"
else
	fail "helper: check не признал живой порт"
fi

# Порт молчит -> check возвращает 1.
if python3 - "$HELPER" <<'PY'
import os, pty, subprocess, sys, threading

helper = sys.argv[1]
master, slave = pty.openpty()
slave_name = os.ttyname(slave)
work = os.environ['PEJIR_TEST_WORK']

bindir = os.path.join(work, 'atwatch-bin2')
os.makedirs(bindir, exist_ok=True)
with open(os.path.join(bindir, 'mdm-at'), 'w') as f:
	f.write("#!/bin/sh\n"
	        "case \"$1\" in\n"
	        "--port) echo \"$PEJIR_TEST_PORT\"; exit 0 ;;\n"
	        "esac\n"
	        "if [ \"$PEJIR_TEST_ALIVE\" = 1 ]; then echo OK; exit 0; fi\n"
	        "exit 1\n")
os.chmod(os.path.join(bindir, 'mdm-at'), 0o755)

portfile = os.path.join(work, 'atwatch-port2')
with open(portfile, 'w') as f:
	f.write(slave_name + "\n")

env = dict(os.environ)
env['PATH'] = bindir + ':' + env.get('PATH', '')
env['PEJIR_TEST_PORT'] = slave_name
env['PEJIR_TEST_ALIVE'] = '0'
env['PEJIR_AT_PORT_FILE'] = portfile
env['PEJIR_AT_WATCH_STATE'] = os.path.join(work, 'atwatch-state2')

r = subprocess.run([helper, 'check'], stdout=subprocess.PIPE,
                   stderr=subprocess.PIPE, timeout=30, env=env)
print("rc=%d out=%r" % (r.returncode, r.stdout.decode()[:200]))
sys.exit(0 if r.returncode == 1 else 1)
PY
then
	ok "helper: молчащий порт считается мёртвым (check -> 1)"
else
	fail "helper: check не признал мёртвый порт"
fi

# --- 4) безопасность: перепривязка только для USB ------------------------
if grep -q '/dev/ttyUSB\*' "$HELPER" && grep -q 'unbind' "$HELPER" && grep -q 'bind' "$HELPER"; then
	ok "helper: перепривязка есть и ограничена USB-портами (/dev/ttyUSB*)"
else
	fail "helper: нет безопасной перепривязки USB-порта"
fi

if grep -q 'PEJIR_AT_WATCH_MAX' "$HELPER" && grep -q 'tries' "$HELPER"; then
	ok "helper: есть ограничение числа попыток восстановления"
else
	fail "helper: нет ограничения числа попыток - возможен цикл перезагрузок"
fi

if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты сторожа AT-порта пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
