#!/bin/sh
# Тест меню LuCI: каждый пункт должен быть РЕАЛЬНО зарегистрирован,
# а каждая наша страница - видима в меню.
#
# Дефект, который закрывает тест (релиз .57): в файле
# package/luci-app-perenio/root/usr/share/luci/menu.d/luci-app-perenio.json
# пункт "admin/status/perenio-lte" оказался ВЛОЖЕН внутрь объекта
# "admin/status/perenio-bands" (патч 0089 вставил его в неверное место
# hunk'а). Файл при этом остался ВАЛИДНЫМ JSON, поэтому json-проверка
# его не ловила:
#
#   "admin/status/perenio-bands": {
#       "title": "...", "order": 70,
#       "action": { "type": "view", "path": "perenio/bands" },
#   "admin/status/perenio-lte": {          <-- вложенный ключ
#       "title": "...", "order": 71,
#       "action": { "type": "view", "path": "perenio/lte" }
#   },
#       "depends": { "acl": [ "luci-app-perenio" ] }
#   }
#
# Следствие: страница perenio/lte.js была в образе, но пункт меню
# не появлялся - пользователь не находил настройки APN/PIN в веб-интерфейсе.
#
# Проверки:
#   1) все menu.d/*.json и acl.d/*.json разбираются как JSON;
#   2) в узле меню нет вложенных узлов (ключей с "/" внутри значения);
#   3) у каждого узла есть title и action.path, и соответствующий
#      view-файл существует в дереве;
#   4) ОБРАТНАЯ проверка: каждая наша страница (view/*.js) зарегистрирована
#      в меню (иначе страница недостижима из интерфейса).

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева $DEFAULT_TREE (задайте OW_TEST)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"

echo "== дерево: $TREE =="

python3 - "$TREE" <<'PYEOF'
import glob, json, os, sys

tree = sys.argv[1]
errs = []
our_pkgs = ("package/luci-app-perenio", "package/pejir-ota")

# --- 1) все файлы меню и ACL должны разбираться -----------------------
files = sorted(glob.glob(os.path.join(tree, "package/*/root/usr/share/luci/menu.d/*.json")))
files += sorted(glob.glob(os.path.join(tree, "package/*/root/usr/share/rpcd/acl.d/*.json")))
if not files:
    print("FAIL: не найдено ни одного menu.d/acl.d json")
    sys.exit(1)

menus = []
for f in files:
    try:
        with open(f, encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as e:
        errs.append("%s: JSON не разбирается: %s" % (os.path.relpath(f, tree), e))
        continue
    if "/menu.d/" in f:
        menus.append((f, data))

# --- 2,3) структура узлов меню ---------------------------------------
registered = {}
for f, data in menus:
    rel = os.path.relpath(f, tree)
    if not isinstance(data, dict):
        errs.append("%s: корень меню - не объект" % rel)
        continue
    for node, val in data.items():
        if not isinstance(val, dict):
            errs.append("%s: узел %s - не объект" % (rel, node))
            continue
        # вложенный узел меню = неверная склейка hunk'а (дефект 0089)
        for k in val:
            if isinstance(k, str) and "/" in k:
                errs.append("%s: узел %s содержит ВЛОЖЕННЫЙ узел %s - "
                            "пункт меню не зарегистрируется" % (rel, node, k))
        if not val.get("title"):
            errs.append("%s: узел %s без title" % (rel, node))
        act = val.get("action")
        if not isinstance(act, dict):
            errs.append("%s: узел %s без action" % (rel, node))
            continue
        path = act.get("path")
        if act.get("type") == "view":
            if not path:
                errs.append("%s: узел %s без action.path" % (rel, node))
                continue
            registered.setdefault(path, node)
            found = glob.glob(os.path.join(
                tree, "package/*/htdocs/luci-static/resources/view", path + ".js"))
            if not found:
                errs.append("%s: узел %s ссылается на отсутствующий view %s.js"
                            % (rel, node, path))

# --- 4) обратная проверка: наши страницы должны быть в меню -----------
for pkg in our_pkgs:
    for v in sorted(glob.glob(os.path.join(tree, pkg,
            "htdocs/luci-static/resources/view/**/*.js"), recursive=True)):
        view = os.path.relpath(v, os.path.join(
            tree, pkg, "htdocs/luci-static/resources/view"))[:-3]
        if view not in registered:
            errs.append("страница %s (%s) НЕ зарегистрирована в меню - "
                        "недостижима из веб-интерфейса" % (view, pkg))

if errs:
    print("FAIL: найдено проблем: %d" % len(errs))
    for e in errs:
        print("  - %s" % e)
    sys.exit(1)

print("OK: меню корректно, пунктов-узлов: %d, наших страниц: %d"
      % (sum(len(d) for _, d in menus), len(registered)))
for p in sorted(registered):
    if p.startswith("perenio/"):
        print("   - %-18s -> %s" % (p, registered[p]))
PYEOF
rc=$?
[ "$rc" -eq 0 ] || exit "$rc"
echo "PASS: test-menu-json"
