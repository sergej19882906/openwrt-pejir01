#!/bin/sh
# Тест: на наших страницах нет бесполезного подвала LuCI.
#
# Дефект, который закрывает тест: стандартный подвал LuCI («Сохранить и
# применить», «Сохранить», «Сбросить») рисуется на ЛЮБОЙ странице, если
# обработчики не отключены. Наши страницы собраны вручную (а не на
# form.Map), поэтому эти кнопки ничего не делают - а на странице multi-WAN
# «Сохранить» показывается дважды: своя кнопка и кнопка подвала.

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

PAGES="package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/mwan.js
package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/lte.js
package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/diag.js
package/pejir-ota/htdocs/luci-static/resources/view/perenio/ota.js"

for rel in $PAGES; do
	f="$DEFAULT_TREE/$rel"
	name="$(basename "$rel")"

	[ -f "$f" ] || { fail "нет файла $rel"; continue; }

	miss=""
	for h in handleSaveApply handleSave handleReset; do
		grep -qE "^[[:space:]]*$h:[[:space:]]*null" "$f" || miss="$miss $h"
	done

	if [ -z "$miss" ]; then
		ok "$name: бесполезный подвал LuCI отключён"
	else
		fail "$name: подвал LuCI включён (не отключено:$miss) - лишние кнопки «Сохранить»/«Сбросить»"
	fi
done

# Свои обработчики не должны называться handleSave - иначе подвал и своя
# кнопка вызывают одно и то же.
for rel in package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/mwan.js \
           package/luci-app-perenio/htdocs/luci-static/resources/view/perenio/lte.js; do
	f="$DEFAULT_TREE/$rel"
	[ -f "$f" ] || continue
	name="$(basename "$rel")"
	if grep -qE "handleSave:[[:space:]]*function" "$f"; then
		fail "$name: свой обработчик назван handleSave - он попадёт и в подвал"
	else
		ok "$name: свой обработчик сохранения назван иначе (saveSettings)"
	fi
done

if [ "$FAILED" -eq 0 ]; then
	echo "Все проверки пройдены"
	exit 0
fi
echo "Провалено проверок: $FAILED"
exit 1
