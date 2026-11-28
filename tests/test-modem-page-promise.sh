#!/bin/sh
# Тест: страница «Модем» (вкладка Сеть) не показывает "[object Promise]".
#
# Дефект, который закрывает тест: в LuCI 25.12 form.Map.render() возвращает
# PROMISE, а не готовый узел DOM. Если такой промис положить в E() как
# узел, страница показывает "[object Promise]" вместо таблицы с данными
# модема (релизы .73 и .74).

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

MAIN_JS="$DEFAULT_TREE/package/luci-app-modeminfo/htdocs/luci-static/resources/view/modem/main.js"

[ -f "$MAIN_JS" ] || { echo "FAIL: нет файла $MAIN_JS"; exit 1; }

# Промис нельзя класть в E() как готовый узел.
if grep -qE "E\('[^']+'[^)]*\.render\(\)" "$MAIN_JS"; then
	fail "в странице промис form.Map.render() кладётся прямо в E() - будет [object Promise]"
else
	ok "form.Map.render() не кладётся прямо в E()"
fi

# Промис должен разрешаться перед вставкой в DOM.
if grep -q "Promise.resolve(m.render())" "$MAIN_JS"; then
	ok "карта страницы подставляется после разрешения промиса"
else
	fail "нет Promise.resolve(m.render()) - карта страницы не отрисуется"
fi

if grep -q "appendChild(mapNode)" "$MAIN_JS"; then
	ok "узел карты вставляется в контейнер"
else
	fail "узел карты не вставляется в контейнер"
fi

# Остальные страницы модема отдают карту как есть - так делать нельзя.
for f in "$DEFAULT_TREE/package/luci-app-modeminfo/htdocs/luci-static/resources/view/modem/hw.js" \
         "$DEFAULT_TREE/package/luci-app-modeminfo/htdocs/luci-static/resources/view/modem/setup.js"; do
	[ -f "$f" ] || continue
	if grep -qE "E\('[^']+'[^)]*\.render\(\)" "$f"; then
		fail "в $(basename "$f") промис карты кладётся в E() - будет [object Promise]"
	else
		ok "$(basename "$f"): карта отдаётся без обёртки"
	fi
done

if [ "$FAILED" -eq 0 ]; then
	echo "Все проверки пройдены"
	exit 0
fi
echo "Провалено проверок: $FAILED"
exit 1
