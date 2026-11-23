#!/bin/sh
# Тест поведения страницы диагностики (diag.js) при отказе запуска helper'а.
#
# Дефект, который закрывает тест: на устройстве helper лежит в overlay
# (верхний слой на флешке extroot). Если этот слой смонтирован с noexec
# или осталась «висящая» копия от горячего фикса, exec файла возвращает
# EACCES, а rpcd отдаёт code 127. Страница при этом показывала "(empty)":
# вывод helper'а просто не дошёл.
#
# Ресурс, который нельзя перекрыть overlay, - неизменяемая копия образа
# в /rom (это squashfs корневого образа: /rom/usr/libexec/perenio-diag).
# Страница обязана обращаться к нему, когда основной путь не сработал.
#
# Проверяется поведение (не grep по исходнику):
#   1) если основной путь отработал - берём его вывод, /rom не трогаем;
#   2) если основной путь не отработал (code != 0, пустой вывод или
#      исключение) - страница обращается к /rom и показывает его вывод;
#   3) если и /rom не отработал - страница показывает ошибку, а не "(empty)";
#   4) в ACL есть грант exec на оба пути (иначе LuCI ответит
#      "Permission denied" ещё до запуска).

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_PKG="$OW_TEST/package/luci-app-perenio"
	[ -d "$DEFAULT_PKG" ] || { echo "FAIL: нет $DEFAULT_PKG"; exit 1; }
else
	DEFAULT_PKG="/workspace/ow-test/package/luci-app-perenio"
fi
LUCI_PKG="${PEJIR_LUCI_PKG:-$DEFAULT_PKG}"

JS="$LUCI_PKG/htdocs/luci-static/resources/view/perenio/diag.js"
ACL="$LUCI_PKG/root/usr/share/rpcd/acl.d/luci-app-perenio.json"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED+1)); }

[ -f "$JS" ] || { echo "FAIL: нет файла $JS"; exit 1; }
[ -f "$ACL" ] || { echo "FAIL: нет файла $ACL"; exit 1; }

if command -v node >/dev/null 2>&1; then
	ok "node доступен"
else
	fail "node не найден - поведение страницы проверить нечем"
	exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

cat > "$WORK/check.js" <<'JS'
'use strict';
const fs = require('fs');
const path = require('path');

const diagPath = process.argv[2];

// --- заглушки окружения LuCI ------------------------------------------------
const view = { extend: (o) => o };
const ui = { createHandlerFn: () => () => {} };
const _ = (s) => s;
const E = () => ({});

function loadDiag(execImpl) {
	const src = fs.readFileSync(diagPath, 'utf-8');
	const fn = new Function('view', 'fs', 'ui', '_', 'E', src);
	return fn(view, { exec: execImpl }, ui, _, E);
}

// Сценарий: основной путь падает (code 127 = exec не состоялся),
// запасной /rom отрабатывает.
async function caseFallback() {
	const calls = [];
	const diag = loadDiag((cmd, args) => {
		calls.push(cmd);
		if (cmd === '/usr/libexec/perenio-diag')
			return Promise.resolve({ code: 127, stdout: '', stderr: '' });
		if (cmd === '/rom/usr/libexec/perenio-diag')
			return Promise.resolve({ code: 0, stdout: 'ДИАГНОСТИКА ИЗ ROM', stderr: '' });
		return Promise.resolve({ code: 1, stdout: '', stderr: 'unknown path' });
	});

	const out = await diag.load();
	const text = Array.isArray(out) ? String(out[0]) : String(out);

	if (!calls.includes('/rom/usr/libexec/perenio-diag')) {
		console.log('FAIL: страница не обратилась к /rom при отказе основного пути');
		return 1;
	}
	if (!text.includes('ДИАГНОСТИКА ИЗ ROM')) {
		console.log('FAIL: страница не показала вывод из /rom: ' + JSON.stringify(text));
		return 1;
	}
	console.log('OK: при отказе основного пути страница берёт вывод из /rom');
	return 0;
}

// Сценарий: основной путь отработал - запасной не трогаем.
async function caseMainOk() {
	const calls = [];
	const diag = loadDiag((cmd, args) => {
		calls.push(cmd);
		return Promise.resolve({ code: 0, stdout: 'ДИАГНОСТИКА ОСНОВНАЯ', stderr: '' });
	});

	const out = await diag.load();
	const text = Array.isArray(out) ? String(out[0]) : String(out);

	if (!text.includes('ДИАГНОСТИКА ОСНОВНАЯ')) {
		console.log('FAIL: страница не показала вывод основного пути: ' + JSON.stringify(text));
		return 1;
	}
	if (calls.includes('/rom/usr/libexec/perenio-diag')) {
		console.log('FAIL: страница дёрнула /rom, хотя основной путь отработал');
		return 1;
	}
	console.log('OK: при рабочем основном пути страница не трогает /rom');
	return 0;
}

// Сценарий: оба пути не отработали - показываем ошибку, а не "(empty)".
async function caseBothFail() {
	const diag = loadDiag(() => Promise.reject(new Error('Access denied')));

	const out = await diag.load();
	const text = Array.isArray(out) ? String(out[0]) : String(out);

	if (!text.trim() || text === '(empty)') {
		console.log('FAIL: страница показала пустоту вместо ошибки: ' + JSON.stringify(text));
		return 1;
	}
	if (!text.includes('Access denied') && !text.includes('Failed')) {
		console.log('FAIL: в сообщении об ошибке нет ни текста исключения, ни пометки о сбое: ' + JSON.stringify(text));
		return 1;
	}
	console.log('OK: при отказе обоих путей страница показывает ошибку, а не пустоту');
	return 0;
}

(async () => {
	let failed = 0;
	failed += await caseFallback();
	failed += await caseMainOk();
	failed += await caseBothFail();
	process.exit(failed ? 1 : 0);
})();
JS

if node "$WORK/check.js" "$JS"; then
	:
else
	fail "поведение страницы диагностики не соответствует ожидаемому"
fi

# --- ACL: гранты exec на оба пути -------------------------------------------
for p in "/usr/libexec/perenio-diag" "/rom/usr/libexec/perenio-diag"; do
	if grep -qF "\"$p\"" "$ACL"; then
		ok "ACL: есть грант exec на '$p'"
	else
		fail "ACL: нет гранта exec на '$p' - LuCI ответит Permission denied"
	fi
done

if python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$ACL" 2>/dev/null; then
	ok "ACL: валидный JSON"
else
	fail "ACL: JSON невалиден"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "Все тесты страницы диагностики пройдены"
	exit 0
fi
echo "Провалено тестов: $FAILED"
exit 1
