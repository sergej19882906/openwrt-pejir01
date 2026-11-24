#!/bin/sh
# Тест двуязычности страниц порта:
#   1) в исходниках страниц нет кириллицы внутри _() - msgid английские;
#   2) в po/ru есть перевод для каждого английского msgid;
#   3) собранный .lmo содержит русские переводы;
#   4) русские переводы не конфликтуют с базовым каталогом LuCI.

set -u

# Пакет берём из применённого дерева OpenWrt (в CI переменная OW_TEST
# указывает на него), иначе - из локального.
if [ -n "${OW_TEST:-}" ]; then
	# OW_TEST задан (в CI это всегда так): отсутствие пакета - ошибка.
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

# Проверка одного пакета: $1 - каталог пакета, $2 - файл .po,
# $3 - каталог со страницами .js, $4 - имя каталога .lmo.
# Тело функции НЕ сдвигается по отступам: в нём есть heredoc'и, а их
# терминатор должен начинаться в начале строки.
check_pkg() {
PKG="$1"
PO="$2"
JS="$3"
LMO_NAME="$4"

echo ""
echo "--- $PKG ---"

[ -f "$PO" ] || { fail "нет файла $PO"; return 0; }

# --- 1) кириллицы в msgid -------------------------------------------------
if python3 - "$JS" <<'PY'
import re, sys, os
d = sys.argv[1]
bad = []
for fn in sorted(os.listdir(d)):
    if not fn.endswith('.js'):
        continue
    s = open(os.path.join(d, fn), encoding='utf-8').read()
    for m in re.finditer(r"_\(\s*'((?:[^'\\]|\\.)*)'", s):
        if re.search(r'[А-Яа-я]', m.group(1)):
            bad.append((fn, m.group(1)))
for fn, t in bad:
    print("  кириллица в msgid: %s: %r" % (fn, t))
sys.exit(1 if bad else 0)
PY
then
	ok "в msgid страниц нет кириллицы (исходники английские)"
else
	fail "в msgid страниц осталась кириллица"
fi

# --- 2) перевод на каждый английский msgid --------------------------------
missing=$(python3 - "$JS" "$PO" <<'PY'
import re, sys, os

jsdir, po = sys.argv[1], sys.argv[2]

def unq(b):
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', b)
    out = ""
    for p in parts:
        out += p.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
    return out

txt = open(po, encoding='utf-8').read()
pairs = {}
for a, c in re.findall(r'msgid ((?:"(?:[^"\\]|\\.)*"\s*)+)msgstr ((?:"(?:[^"\\]|\\.)*"\s*)+)', txt):
    k = unq(a)
    if k:
        pairs[k] = unq(c)

ids = set()
for fn in sorted(os.listdir(jsdir)):
    if not fn.endswith('.js'):
        continue
    s = open(os.path.join(jsdir, fn), encoding='utf-8').read()
    for m in re.finditer(r"_\(\s*'((?:[^'\\]|\\.)*)'", s):
        ids.add(m.group(1).replace("\\'", "'"))

miss = sorted(i for i in ids if i not in pairs)
for m in miss:
    print("  нет перевода: %r" % m)
print("ВСЕГО_НЕТ=%d" % len(miss))
PY
)
cnt=$(printf '%s\n' "$missing" | sed -n 's/^ВСЕГО_НЕТ=//p')
if [ "${cnt:-1}" = "0" ]; then
	ok "на каждый msgid страниц есть перевод в .po"
else
	fail "в .po нет переводов для $cnt строк"
	printf '%s\n' "$missing" | grep -v '^ВСЕГО_НЕТ='
fi

# --- 3) .lmo собирается и содержит переводы -------------------------------
PO2LMO="${PO2LMO:-/tmp/ptest/po2lmo}"
if [ -x "$PO2LMO" ]; then
	LMO="/tmp/test-$LMO_NAME.ru.lmo"
	rm -f "$LMO"
	if "$PO2LMO" "$PO" "$LMO" >/dev/null 2>&1 && [ -s "$LMO" ]; then
		ok "po2lmo собрал каталог ($(wc -c < "$LMO") Б)"
		if python3 - "$LMO" "$PO" <<'PY'
import re, sys
lmo, po = sys.argv[1], sys.argv[2]
b = open(lmo, 'rb').read()

def unq(x):
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', x)
    out = ""
    for p in parts:
        out += p.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
    return out

txt = open(po, encoding='utf-8').read()
pairs = {}
for a, c in re.findall(r'msgid ((?:"(?:[^"\\]|\\.)*"\s*)+)msgstr ((?:"(?:[^"\\]|\\.)*"\s*)+)', txt):
    k = unq(a)
    if k:
        pairs[k] = unq(c)

# переводы, отличающиеся от оригинала, обязаны попасть в .lmo
need = [v for k, v in pairs.items() if v != k]
miss = [v for v in need if v.encode('utf-8') not in b]
for m in miss:
    print("  нет в .lmo: %r" % m)
print("ВСЕГО_НЕТ=%d" % len(miss))
PY
		then
			ok "все отличающиеся переводы попали в .lmo"
		else
			fail "часть переводов не попала в .lmo"
		fi
	else
		fail "po2lmo не собрал каталог"
	fi
else
	echo "ПРОПУСК: нет po2lmo ($PO2LMO)"
fi

# --- 4) конфликты с базовым каталогом LuCI --------------------------------
# Базовый каталог LuCI: в CI - в дереве сборки, локально - в /tmp/lucib.
if [ -z "${BASE_PO:-}" ]; then
	for cand in "${OW_TEST:-}/feeds/luci/modules/luci-base/po/ru" \
	            "${OW_TEST:-}/../luci/modules/luci-base/po/ru" \
	            /tmp/lucib/modules/luci-base/po/ru; do
		if [ -d "$cand" ]; then
			BASE_PO="$cand"
			break
		fi
	done
fi
BASE_PO="${BASE_PO:-/tmp/lucib/modules/luci-base/po/ru}"
if [ -d "$BASE_PO" ]; then
	conf=$(python3 - "$PO" "$BASE_PO" <<'PY'
import re, sys, glob, os
po, basedir = sys.argv[1], sys.argv[2]

def unq(x):
    parts = re.findall(r'"((?:[^"\\]|\\.)*)"', x)
    out = ""
    for p in parts:
        out += p.replace('\\"', '"').replace('\\n', '\n').replace('\\\\', '\\')
    return out

def load(path):
    txt = open(path, encoding='utf-8').read()
    d = {}
    for a, c in re.findall(r'msgid ((?:"(?:[^"\\]|\\.)*"\s*)+)msgstr ((?:"(?:[^"\\]|\\.)*"\s*)+)', txt):
        k = unq(a)
        if k:
            d[k] = unq(c)
    return d

ours = load(po)
conf = []
for f in sorted(glob.glob(os.path.join(basedir, '*.po'))):
    for k, v in load(f).items():
        if k in ours and ours[k] != v:
            conf.append((os.path.basename(f), k, ours[k], v))
for c in conf:
    print("  конфликт %s: %r -> %r / %r" % c)
print("ВСЕГО_НЕТ=%d" % len(conf))
PY
	)
	cnt=$(printf '%s\n' "$conf" | sed -n 's/^ВСЕГО_НЕТ=//p')
	if [ "${cnt:-1}" = "0" ]; then
		ok "конфликтов переводов с базовым каталогом LuCI нет"
	else
		fail "конфликтов переводов с базовым каталогом: $cnt"
		printf '%s\n' "$conf" | grep -v '^ВСЕГО_НЕТ='
	fi
else
	echo "ПРОПУСК: нет базового каталога ($BASE_PO)"
fi
}
# --- проверяем все наши страницы -----------------------------------------
# Основной пакет страниц и пакет страницы обновления прошивки.
check_pkg "$DEFAULT_PKG" \
"$DEFAULT_PKG/po/ru/luci-app-perenio.po" \
"$DEFAULT_PKG/htdocs/luci-static/resources/view/perenio" \
"perenio"

OTA_PKG="${OW_TEST:-/workspace/ow-test}/package/pejir-ota"
if [ -d "$OTA_PKG" ]; then
check_pkg "$OTA_PKG" \
"$OTA_PKG/po/ru/luci-app-pejir-ota.po" \
"$OTA_PKG/htdocs/luci-static/resources/view/perenio" \
"pejir-ota"
else
echo ""
echo "FAIL: нет пакета pejir-ota ($OTA_PKG)"
FAILED=$((FAILED+1))
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты двуязычности пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
