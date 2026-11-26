#!/bin/sh
# Тест страницы "Настройки LTE": поле показывает СОХРАНЁННОЕ значение,
# а красным отмечаются несохранённые правки.
#
# Дефект, который закрывает этот тест (исходный): страница показывала
# только поля ввода, и если сохранение не проходило (нет прав на uci
# network, опечатка в имени секции), поля выглядели пустыми - понять,
# записались настройки или нет, было невозможно.
#
# Вторая правка (жалоба пользователя): рядом с полем показывалось
# СРАЗУ два значения - введённое (в поле) и сохранённое (рядом), при
#чём расхождение подсвечивалось красным. Страница выглядела так,
# будто настройки не сохранились, и приходилось гадать, что записано
# на самом деле. Теперь поле всегда показывает то, что реально лежит
# в network.lte, а красным отмечается только несохранённая правка.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG (задайте OW_TEST с деревом OpenWrt)"; exit 1; }
fi
LUCI_PKG="${PEJIR_LUCI_PKG:-$DEFAULT_PKG}"
PAGE="$LUCI_PKG/htdocs/luci-static/resources/view/perenio/lte.js"
PO="$LUCI_PKG/po/ru/luci-app-perenio.po"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$PAGE" ] || { echo "FAIL: нет файла $PAGE"; exit 1; }
[ -f "$PO" ] || { echo "FAIL: нет файла $PO"; exit 1; }

# --- 1) механика "поле = сохранённое значение" ------------------------------
for f in rowSaved refreshSaved markSaved savedText readSaved savedValue fillFromSaved; do
	if grep -q "$f" "$PAGE"; then
		ok "в странице есть $f()"
	else
		fail "в странице нет $f()"
	fi
done

# У каждого поля должна быть ячейка рядом с ним.
for k in apn pdptype username password auth dns modes; do
	if grep -q "pejir-saved-' + key" "$PAGE" && grep -q "'key': '$k'" "$PAGE"; then
		ok "для поля $k есть ячейка рядом"
	else
		fail "для поля $k нет ячейки рядом"
	fi
done

# Поля заполняются сохранёнными значениями, а не введёнными.
if grep -q "savedValue('apn')" "$PAGE" && grep -q "savedValue('modes')" "$PAGE"; then
	ok "поля заполняются сохранёнными значениями"
else
	fail "поля заполняются не сохранёнными значениями"
fi

# После сохранения поле должно снова показать записанное значение.
if grep -A8 "return uci.save().then(function()" "$PAGE" | grep -q "fillFromSaved()"; then
	ok "после сохранения поле показывает записанное значение"
else
	fail "после сохранения поле не обновляется"
fi

# Ошибка сохранения тоже должна показывать фактическое состояние конфига.
if grep -B8 "Failed to save" "$PAGE" | grep -q "refreshSaved()"; then
	ok "при ошибке сохранения показывается фактическое состояние"
else
	fail "при ошибке сохранения состояние не показывается"
fi

# Красным должен помечаться только случай несохранённой правки.
if grep -q "inp.value !== savedValue" "$PAGE"; then
	ok "красным помечается расхождение поля с сохранённым значением"
else
	fail "красным помечается не то"
fi

# После применения к модему конфиг перечитывается с диска.
if grep -q "reloadSaved()" "$PAGE" && grep -q "rpc.call('uci', 'get'" "$PAGE"; then
	ok "после применения конфиг перечитывается с диска"
else
	fail "после применения конфиг не перечитывается"
fi

# Старая формулировка (два значения рядом) больше не должна быть.
if grep -q "keeps what you entered" "$PAGE"; then
	fail "на странице остался старый текст про введённое и сохранённое значение"
else
	ok "старый текст про два значения рядом убран"
fi

# --- 2) переводы -------------------------------------------------------------
for m in "Saved" "not set" "Last saved" "Not saved" "The field has been changed, but not saved yet"; do
	if grep -qF "msgid \"$m\"" "$PO" && grep -A1 -F "msgid \"$m\"" "$PO" | grep -q 'msgstr "[^"]' ; then
		ok "перевод есть: $m"
	else
		fail "нет перевода для: $m"
	fi
done

if grep -qF "msgid \"Each field shows the value that is really saved in network.lte" "$PO"; then
	ok "перевод есть: описание сохранённых значений"
else
	fail "нет перевода для описания сохранённых значений"
fi

if grep -qF "keeps what you entered" "$PO"; then
	fail "в .po остался старый перевод про два значения рядом"
else
	ok "старый перевод убран"
fi

# --- 3) синтаксис ------------------------------------------------------------
if command -v node >/dev/null 2>&1; then
	if node --check "$PAGE" >/dev/null 2>&1; then
		ok "синтаксис страницы OK"
	else
		fail "синтаксис страницы сломан"
	fi
else
	echo "ПРОПУСК: нет node - синтаксис не проверен"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты страницы LTE пройдены"
