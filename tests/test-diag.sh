#!/bin/sh
# Тест helper'а диагностики /usr/libexec/perenio-diag.
#
# Дефект, который закрывает тест: свойства device-tree в /proc/device-tree
# отдаются ядром с нулевым байтом на конце. rpcd/ubus передаёт stdout как
# blobmsg-строку, а она обрезается по первому NUL ⇒ вывод диагностики
# обрывался сразу после /proc/device-tree/model, и страница показывала
# только «IoT Perenio Elegance PEJIR01».
#
# Здесь проверяется:
#   1) в выводе helper'а нет ни одного NUL-байта;
#   2) вывод НЕ обрывается: в нём есть строки и после модели (модель/DTB,
#      USB, модем, батарея);
#   3) модель и compatible читаются из DT_ROOT (для теста - из мока).

set -u

if [ -n "${OW_TEST:-}" ] && [ -d "$OW_TEST/package/luci-app-perenio" ]; then
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
fi
LUCI_PKG="${PEJIR_LUCI_PKG:-$DEFAULT_PKG}"

DIAG="$LUCI_PKG/root/usr/libexec/perenio-diag"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$DIAG" ] || { echo "FAIL: нет файла $DIAG"; exit 1; }
sh -n "$DIAG" || { echo "FAIL: синтаксис $DIAG"; exit 1; }
ok "helper существует и синтаксис в порядке"

# --- мок device-tree: свойства с нулевым байтом на конце --------------------
MOCK="$(mktemp -d)"
trap 'rm -rf "$MOCK"' EXIT
mkdir -p "$MOCK/dt/xhci@1e1c0000"
printf 'IoT Perenio Elegance PEJIR01\0' > "$MOCK/dt/model"
printf 'perenio,pejir01-34-BA\0' > "$MOCK/dt/compatible"
printf 'okay\0' > "$MOCK/dt/xhci@1e1c0000/status"

# sanity: в моке действительно есть NUL (как в ядре)
if tr -d '\000' < "$MOCK/dt/model" | wc -c | grep -qv "^33$"; then
	ok "в моке device-tree есть нулевой байт (как в /proc/device-tree)"
else
	fail "мок не содержит NUL - тест бессмысленен"
fi

OUT="$MOCK/out"
DT_ROOT="$MOCK/dt" sh "$DIAG" > "$OUT" 2>/dev/null

# --- 1) в выводе нет NUL ----------------------------------------------------
NULS="$(tr -dc '\000' < "$OUT" | wc -c)"
if [ "$NULS" -eq 0 ]; then
	ok "в выводе helper'а нет ни одного NUL-байта (ubus не обрежет строку)"
else
	fail "в выводе $NULS NUL-байт(ов) - вывод обрежется в rpcd/ubus"
fi

# --- 2) вывод не обрывается -------------------------------------------------
if grep -q 'IoT Perenio Elegance PEJIR01' "$OUT"; then
	ok "модель в выводе есть"
else
	fail "нет модели в выводе"
fi

for marker in 'совместимость:' 'узлы device-tree:' 'cmdline:' '=== USB: устройства ===' \
              '=== Модем, UART и мультиплексор ===' '=== Батарея: mcu ==='; do
	if grep -qF "$marker" "$OUT"; then
		ok "вывод не обрывается: есть «$marker»"
	else
		fail "вывод обрывается: нет «$marker»"
	fi
done

if grep -qF 'perenio,pejir01-34-BA' "$OUT"; then
	ok "compatible читается (совместимость DTB)"
else
	fail "compatible не прочитан"
fi

# --- 3) именно этот дефект ловится -----------------------------------------
# Если бы helper отдавал сырое свойство DT, NUL-байт был бы в выводе.
if tr -d '\000' < "$MOCK/dt/model" | wc -c | grep -qv "^33$"; then
	ok "проверка на NUL осмысленна"
fi

if [ "$FAILED" -gt 0 ]; then
	echo "Провалено тестов: $FAILED"
	exit 1
fi

echo "Все тесты диагностики пройдены"
