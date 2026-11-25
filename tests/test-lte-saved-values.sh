#!/bin/sh
# Тест страницы "Настройки LTE": введённое значение и сохранённое
# значение показываются рядом.
#
# Дефект, который закрывает этот тест: страница показывала только поля
# ввода. Если сохранение не проходило (нет прав на uci network, опечатка
# в имени секции), поля выглядели пустыми, и пользователь не понимал,
# записались настройки или нет - значения "пропали".
#
# Теперь у каждого поля есть соседняя ячейка со значением, реально
# лежащим в network.lte, а расхождение с введённым подсвечивается.

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

# --- 1) механика "введено + сохранено" --------------------------------------
for f in rowSaved refreshSaved markSaved savedText; do
	if grep -q "$f" "$PAGE"; then
		ok "в странице есть $f()"
	else
		fail "в странице нет $f()"
	fi
done

# У каждого поля должна быть ячейка с сохранённым значением.
for k in apn pdptype username password auth dns modes; do
	if grep -q "pejir-saved-' + key" "$PAGE" && grep -q "'key': '$k'" "$PAGE"; then
		ok "для поля $k есть сохранённое значение"
	else
		fail "для поля $k нет сохранённого значения"
	fi
done

# После сохранения колонка обязана обновляться.
if grep -A6 "return uci.save().then(function()" "$PAGE" | grep -q "refreshSaved()"; then
	ok "после сохранения значения перечитываются из конфига"
else
	fail "после сохранения значения не перечитываются"
fi

# Ошибка сохранения тоже должна показывать реальное состояние конфига.
if grep -B6 "Failed to save" "$PAGE" | grep -q "refreshSaved()"; then
	ok "при ошибке сохранения показывается фактическое состояние"
else
	fail "при ошибке сохранения состояние не показывается"
fi

# --- 2) переводы -------------------------------------------------------------
for m in "Saved" "not set" "Differs from the entered value" "Last saved"; do
	if grep -qF "msgid \"$m\"" "$PO" && grep -A1 -F "msgid \"$m\"" "$PO" | grep -q 'msgstr "[^"]' ; then
		ok "перевод есть: $m"
	else
		fail "нет перевода для: $m"
	fi
done

if grep -qF "msgid \"The saved value is shown next to each field" "$PO"; then
	ok "перевод есть: описание сохранённых значений"
else
	fail "нет перевода для описания сохранённых значений"
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
