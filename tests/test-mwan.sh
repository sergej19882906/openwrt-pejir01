#!/bin/sh
# Тест собственного модуля multi-WAN (pejir-mwan) для PEJIR01.
#
# Модуль заменяет mwan3 (в OpenWrt 25.12 mwan3 работает только через
# iptables и тянул за собой стоковый конфиг из образа). Проверяется:
#   1) пакет, init-скрипт и helper на месте, синтаксис в порядке;
#   2) пакет ставится в образ, ip-full добавлен в build.sh;
#   3) в ACL есть гранты (uci pejir_mwan + exec helper'а), в меню есть
#      пункт страницы;
#   4) поведение демона на моках ubus/jsonfilter/ip/nft/ping/uci:
#        - balance: nft помечает новые соединения, ip rule ведёт их в
#          свои таблицы;
#        - balance при упавшем WAN: весь трафик уходит в LTE;
#        - failover: правило на активную таблицу, разметки нет;
#        - pbr: правило "to <CIDR> lookup 200";
#        - оба канала мертвы: правил нет;
#        - модуль выключен: маршрутизация не меняется;
#        - cleanup снимает всё.

set -u

if [ -n "${OW_TEST:-}" ]; then
	DEFAULT_TREE="$OW_TEST"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева $DEFAULT_TREE"; exit 1; }
else
	DEFAULT_TREE="/workspace/ow-test"
	[ -d "$DEFAULT_TREE" ] || { echo "FAIL: нет дерева $DEFAULT_TREE (задайте OW_TEST)"; exit 1; }
fi
TREE="${PEJIR_TREE:-$DEFAULT_TREE}"

PKG="$TREE/package/pejir-mwan"
LUCI="$TREE/package/luci-app-perenio"
DAEMON="$PKG/root/usr/libexec/pejir-mwan"
CTL="$PKG/root/usr/libexec/pejir-mwan-ctl"
INIT="$PKG/root/etc/init.d/50-pejir-mwan"
CONF="$PKG/root/etc/config/pejir_mwan"
PAGE="$LUCI/htdocs/luci-static/resources/view/perenio/mwan.js"
ACL="$LUCI/root/usr/share/rpcd/acl.d/luci-app-perenio.json"
MENU="$LUCI/root/usr/share/luci/menu.d/luci-app-perenio.json"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$REPO/build.sh"

FAILED=0
ok()   { echo "OK: $1"; }
fail() { echo "FAIL: $1"; FAILED=$((FAILED + 1)); }

# --- 1) файлы пакета -------------------------------------------------------
for f in "$PKG/Makefile" "$DAEMON" "$CTL" "$INIT" "$CONF" "$PAGE" "$ACL" "$MENU"; do
	[ -f "$f" ] || { echo "FAIL: нет файла $f"; exit 1; }
done
ok "файлы пакета и страницы на месте"

for f in "$DAEMON" "$CTL" "$INIT"; do
	sh -n "$f" 2>/dev/null || { echo "FAIL: синтаксис $f"; exit 1; }
done
ok "синтаксис демона, helper'а и init-скрипта в порядке"

grep -q "pejir-mwan" "$PKG/Makefile" || { fail "пакет не ставится в образ"; }
grep -q "root/usr/libexec/pejir-mwan" "$PKG/Makefile" || { fail "Makefile не ставит демон"; }
grep -q "root/usr/libexec/pejir-mwan-ctl" "$PKG/Makefile" || { fail "Makefile не ставит helper"; }
grep -q "root/etc/init.d/50-pejir-mwan" "$PKG/Makefile" || { fail "Makefile не ставит init-скрипт"; }
grep -q "root/etc/config/pejir_mwan" "$PKG/Makefile" || { fail "Makefile не ставит конфиг"; }
ok "Makefile ставит демон, helper, init и конфиг"

grep -q "option enabled '0'" "$CONF" || { fail "модуль не выключен по умолчанию"; }
ok "модуль выключен по умолчанию"

# --- 2) build.sh -----------------------------------------------------------
if grep -q "CONFIG_PACKAGE_pejir-mwan=y" "$BUILD"; then
	ok "build.sh включает pejir-mwan"
else
	fail "в build.sh нет pejir-mwan"
fi
if grep -q "CONFIG_PACKAGE_ip-full=y" "$BUILD"; then
	ok "build.sh включает ip-full"
else
	fail "в build.sh нет ip-full"
fi

# --- 3) ACL и меню ---------------------------------------------------------
grep -qF '"pejir_mwan"' "$ACL" || { fail "в ACL нет uci-скоупа pejir_mwan"; }
grep -qF '"/usr/libexec/pejir-mwan-ctl"' "$ACL" || { fail "в ACL нет гранта exec на helper"; }
grep -q "perenio-mwan" "$MENU" || { fail "в меню нет пункта multi-WAN"; }
grep -q "perenio/mwan" "$MENU" || { fail "в меню нет пути страницы perenio/mwan"; }
grep -q "pejir-mwan-ctl" "$PAGE" || { fail "страница не зовёт helper"; }
ok "ACL, меню и страница на месте"

# --- 4) поведение демона на моках -----------------------------------------
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT INT TERM

mkdir -p "$WORK/bin" "$WORK/conf/ifaces" "$WORK/sys/eth0" "$WORK/sys/eth1"

cat > "$WORK/bin/uci" <<'EOF'
#!/usr/bin/env python3
"""Мок uci: только get/set/commit для пакета pejir_mwan."""
import os, re, sys

conf = os.environ.get("MOCK_CONF", "")
argv = sys.argv[1:]
while argv and argv[0].startswith("-"):
    argv = argv[1:]
if not argv:
    sys.exit(1)
cmd, args = argv[0], argv[1:]

if cmd == "get":
    if not args:
        sys.exit(1)
    opt = args[0].split(".")[-1]
    path = os.path.join(conf, "pejir_mwan")
    if not os.path.exists(path):
        sys.exit(1)
    for line in open(path):
        m = re.match(r"\s*option\s+(\S+)\s+'?([^']*)'?\s*$", line.rstrip())
        if m and m.group(1) == opt:
            print(m.group(2))
            sys.exit(0)
    sys.exit(1)

if cmd == "set":
    with open(os.path.join(conf, "uci.log"), "a") as fh:
        fh.write("set " + " ".join(args) + "\n")
    sys.exit(0)

if cmd == "commit":
    sys.exit(0)

sys.exit(1)
EOF

cat > "$WORK/bin/ubus" <<'EOF'
#!/bin/sh
# Мок ubus: "ubus call network.interface.<имя> status"
# и "ubus call network.interface dump" (общий дамп netifd).
case "$2" in
network.interface)
	# Настоящий netifd отдаёт общий дамп МАССИВОМ объектов:
	# {"interface":[{"interface":"wan",...},{"interface":"lte",...}]},
	# а не объектом, где имя интерфейса - ключ.
	out='{"interface":['
	first=1
	for f in "$MOCK_CONF"/ifaces/*.json; do
		[ -f "$f" ] || continue
		n="$(basename "$f" .json)"
		[ "$first" = "1" ] || out="$out,"
		first=0
		# Имя интерфейса - часть того же объекта, поэтому вставляем его
		# внутрь JSON статуса, а не рядом с ним.
		out="$out$(sed 's/^{/{\"interface\":\"$n\",/' "$f")"
	done
	echo "$out]}"
	exit 0
	;;
esac
name="${2##*.}"
f="$MOCK_CONF/ifaces/$name.json"
# Метка .hidden означает: объекта с таким именем нет (ubus пишет ошибку
# в stderr, в stdout пусто), но в общем дампе интерфейс есть.
if [ -f "$f" ] && [ ! -f "$MOCK_CONF/ifaces/$name.hidden" ]; then
	cat "$f"
else
	# Настоящий ubus на запрос несуществующего объекта печатает ошибку
	# в stderr и ничего в stdout - и возвращает непустой код.
	echo "ubus: object not found" >&2
	exit 1
fi
EOF

cat > "$WORK/bin/jsonfilter" <<'EOF'
#!/usr/bin/env python3
"""Мок jsonfilter: поддерживает @.key, @.key[0], @.key[*] и вложенность."""
import json, re, sys

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(1)


def out(v):
    # jsonfilter печатает булевы как true/false, а не True/False.
    if isinstance(v, bool):
        print("true" if v else "false")
    elif v is not None:
        print(v)


PART = re.compile(r"^([^\[\]]*)(?:\[(\d+|\*)\])?$")


def matches(obj, path):
    """Все значения по пути: поддерживаются "key", "key[0]" и "key[*]"."""
    cur = [obj]
    for part in [p for p in path.split(".") if p]:
        m = PART.match(part)
        if not m:
            return []
        name, idx = m.group(1), m.group(2)
        nxt = []
        for c in cur:
            if name:
                if isinstance(c, dict) and name in c:
                    c = c[name]
                else:
                    continue
            if idx is None:
                nxt.append(c)
            elif idx == "*":
                if isinstance(c, list):
                    nxt.extend(c)
            else:
                if isinstance(c, list):
                    try:
                        nxt.append(c[int(idx)])
                    except (ValueError, IndexError):
                        pass
        cur = nxt
    return cur


for arg in sys.argv[1:]:
    if not arg.startswith("@"):
        continue
    p = arg[1:]
    if p.endswith("[*]"):
        base = p[:-3]
        for v in matches(data, base):
            out(v)
    else:
        for v in matches(data, p):
            out(v)
EOF

cat > "$WORK/bin/ping" <<'EOF'
#!/bin/sh
# Мок ping: устройство из MOCK_DEAD_DEV не отвечает.
dev=""
prev=""
for a in "$@"; do
	[ "$prev" = "-I" ] && dev="$a"
	prev="$a"
done
dead=" ${MOCK_DEAD_DEV:-} "
case "$dead" in
	*" $dev "*) exit 1 ;;
esac
exit 0
EOF

cat > "$WORK/bin/logger" <<'EOF'
#!/bin/sh
exit 0
EOF

cat > "$WORK/bin/ip" <<'EOF'
#!/usr/bin/env python3
"""Мок ip: правила и маршруты хранятся в файлах MOCK_CONF."""
import os, sys

conf = os.environ.get("MOCK_CONF", "")
rules_path = os.path.join(conf, "rules")
routes_path = os.path.join(conf, "routes.log")
argv = [a for a in sys.argv[1:] if a != "-4"]


def load_rules():
    if not os.path.exists(rules_path):
        return []
    return [l.rstrip("\n") for l in open(rules_path) if l.strip()]


def save_rules(rules):
    with open(rules_path, "w") as fh:
        for r in rules:
            fh.write(r + "\n")


def rule_fields(line):
    """Разбор строки "100:\tfrom all to 1.2.3.0/24 fwmark 0x1 lookup 200"."""
    out = {"pref": None, "from": None, "to": None, "fwmark": None, "lookup": None}
    if ":" in line:
        head = line.split(":", 1)[0]
        if head.strip().isdigit():
            out["pref"] = head.strip()
    rest = line.split(":", 1)[1] if ":" in line else ""
    for part in rest.split():
        if part in ("from", "to", "fwmark", "lookup"):
            pass
    toks = rest.split()
    for i, t in enumerate(toks):
        if t in ("from", "to", "fwmark", "lookup") and i + 1 < len(toks):
            out[t] = toks[i + 1]
    return out


if not argv:
    sys.exit(1)
cmd, args = argv[0], argv[1:]

if cmd == "rule":
    sub = args[0] if args else ""
    rest = args[1:]
    if sub == "show":
        for r in load_rules():
            print(r)
        sys.exit(0)
    if sub == "add":
        pref = mark = lookup = dest = None
        i = 0
        while i < len(rest):
            t = rest[i]
            if t == "pref":
                pref = rest[i + 1]; i += 2
            elif t == "fwmark":
                mark = rest[i + 1]; i += 2
            elif t == "lookup":
                lookup = rest[i + 1]; i += 2
            elif t == "to":
                dest = rest[i + 1]; i += 2
            else:
                i += 1
        parts = "to %s" % dest if dest else "from all"
        if mark:
            parts += " fwmark %s" % mark
        if lookup:
            parts += " lookup %s" % lookup
        save_rules(load_rules() + ["%s:\t%s" % (pref, parts)])
        sys.exit(0)
    if sub == "del":
        # Настоящий iproute2 сравнивает ВСЕ поля запроса с полями
        # правила: не заданные считаются нулевыми. Поэтому правило с
        # "to ..." не снимается командой "del pref N" без "to ...".
        sel = {"pref": None, "from": None, "to": None, "fwmark": None, "lookup": None}
        i = 0
        while i < len(rest):
            if rest[i] in sel and i + 1 < len(rest):
                sel[rest[i]] = rest[i + 1]; i += 2
            else:
                i += 1
        keep = []
        for r in load_rules():
            f = rule_fields(r)
            match = True
            for key, val in sel.items():
                if val is None:
                    continue
                if f.get(key) != val:
                    match = False
                    break
            if not match:
                keep.append(r)
        save_rules(keep)
        sys.exit(0)
    sys.exit(0)

if cmd == "route":
    if len(args) >= 2 and args[0] == "show":
        # Реальный ip печатает маршруты главной таблицы. Мок берёт их
        # из файла kernel_routes (по одной строке на маршрут) и умеет
        # фильтровать по устройству и по "scope link".
        dev = None
        if "dev" in args:
            dev = args[args.index("dev") + 1]
        scope_link = "link" in args
        kpath = os.path.join(conf, "kernel_routes")
        lines = []
        if os.path.exists(kpath):
            lines = [l.rstrip("\n") for l in open(kpath) if l.strip()]
        else:
            lines = [os.environ.get("MOCK_LINK_ROUTE",
                    "192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.5")]
        for line in lines:
            ldev = None
            if " dev " in line:
                ldev = line.split(" dev ", 1)[1].split()[0]
            if dev and ldev != dev:
                continue
            if scope_link and " scope link" not in line:
                continue
            print(line)
        sys.exit(0)
    with open(routes_path, "a") as fh:
        fh.write(" ".join(argv) + "\n")
    sys.exit(0)

sys.exit(0)
EOF

cat > "$WORK/bin/nft" <<'EOF'
#!/usr/bin/env python3
"""Мок nft: набор правил хранится в MOCK_CONF/nft.rules."""
import os, sys

conf = os.environ.get("MOCK_CONF", "")
store = os.path.join(conf, "nft.rules")
argv = sys.argv[1:]

if "-f" in argv:
    path = argv[argv.index("-f") + 1]
    try:
        content = open(path).read()
    except OSError:
        sys.exit(1)
    if "table inet pejir_mwan" in content:
        with open(store, "w") as fh:
            fh.write(content)
    sys.exit(0)

if "delete" in argv and "table" in argv:
    if "pejir_mwan" in argv and os.path.exists(store):
        os.remove(store)
    sys.exit(0)

if "list" in argv:
    if os.path.exists(store):
        content = open(store).read()
        print(content.replace("counter", "counter packets 7 bytes 70"))
    sys.exit(0)

sys.exit(0)
EOF

chmod +x "$WORK/bin"/*

prep_conf() { # $1 - режим, $2 - enabled, $3 - pbr_list
	cat > "$WORK/conf/pejir_mwan" <<EOF
config mwan 'main'
	option enabled '$2'
	option mode '$1'
	option wan_iface 'wan'
	option wan_device 'eth0'
	option lte_iface 'lte'
	option lte_device 'eth1'
	option wan_table '100'
	option lte_table '200'
	option wan_weight '50'
	option check_interval '10'
	option check_count '3'
	option check_target ''
	option pbr_list '$3'
EOF
	# Формат - как у настоящего netifd: статус плоский, шлюза
	# отдельным ключом нет, он лежит в маршруте 0.0.0.0/0.
	cat > "$WORK/conf/ifaces/wan.json" <<'EOF'
{"up":true,"pending":false,"available":true,"autostart":true,"l3_device":"eth0","proto":"dhcp","device":"eth0","ipv4-address":[{"address":"192.168.1.5","mask":24}],"route":[{"target":"192.168.1.0/24","mask":24,"nexthop":"0.0.0.0"},{"target":"0.0.0.0/0","mask":0,"nexthop":"192.168.1.1"}],"data":{"dns":["8.8.8.8"]}}
EOF
	cat > "$WORK/conf/ifaces/lte.json" <<'EOF'
{"up":true,"pending":false,"available":true,"autostart":true,"l3_device":"eth1","proto":"dhcp","device":"eth1","ipv4-address":[{"address":"10.10.10.5","mask":24}],"route":[{"target":"10.10.0.0/24","mask":24,"nexthop":"0.0.0.0"},{"target":"0.0.0.0/0","mask":0,"nexthop":"10.10.10.1"}],"data":{"dns":["8.8.4.4"]}}
EOF
	# Маршруты ядра (главная таблица) - их видит ip -4 route show.
	cat > "$WORK/conf/kernel_routes" <<'EOF'
default via 192.168.1.1 dev eth0
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.5
default via 10.10.10.1 dev eth1
10.10.0.0/24 dev eth1 proto kernel scope link src 10.10.10.5
EOF
	rm -f "$WORK/conf/ifaces/wan.hidden" "$WORK/conf/ifaces/lte.hidden"
	rm -f "$WORK/conf/rules" "$WORK/conf/nft.rules" "$WORK/conf/routes.log" "$WORK/state" "$WORK/applied"
}

run_daemon() { # $1 - "мёртвое" устройство (пусто = все живы)
	PATH="$WORK/bin:$PATH" \
	MOCK_CONF="$WORK/conf" \
	MOCK_DEAD_DEV="${1:-}" \
	PEJIR_MWAN_STATE="$WORK/state" \
	PEJIR_MWAN_APPLIED="$WORK/applied" \
	PEJIR_MWAN_LOG="$WORK/log" \
	PEJIR_MWAN_NFT="$WORK/nft.rules.tmp" \
	PEJIR_MWAN_PID="$WORK/pid" \
	PEJIR_MWAN_SYSNET="$WORK/sys" \
	sh "$DAEMON" once
}

# --- 4.1 баланс: оба канала живы -----------------------------------------
prep_conf balance 1 ""
run_daemon ""
if grep -q "numgen random mod 10" "$WORK/conf/nft.rules" 2>/dev/null; then
	ok "balance: nft помечает новые соединения (numgen)"
else
	fail "balance: нет разметки numgen в nft"
fi
if grep -q "jump to_wan" "$WORK/conf/nft.rules" 2>/dev/null &&
   grep -q "jump to_lte" "$WORK/conf/nft.rules" 2>/dev/null; then
	ok "balance: обе метки в карте разметки"
else
	fail "balance: в карте разметки нет обоих каналов"
fi
if grep -q "fwmark 0x1 lookup 100" "$WORK/conf/rules" 2>/dev/null &&
   grep -q "fwmark 0x2 lookup 200" "$WORK/conf/rules" 2>/dev/null; then
	ok "balance: ip rule ведёт метки в свои таблицы"
else
	fail "balance: нет правил ip rule по меткам"
fi
if grep -q "900:.*lookup 100" "$WORK/conf/rules" 2>/dev/null; then
	ok "balance: есть запасное правило на WAN"
else
	fail "balance: нет запасного правила"
fi
if grep -q "active=both" "$WORK/state" 2>/dev/null; then
	ok "balance: оба канала живые"
else
	fail "balance: в состоянии не both"
fi

# --- 4.2 баланс: WAN упал -------------------------------------------------
prep_conf balance 1 ""
run_daemon "eth0"
if grep -q "fwmark 0x1 lookup 200" "$WORK/conf/rules" 2>/dev/null &&
   grep -q "fwmark 0x2 lookup 200" "$WORK/conf/rules" 2>/dev/null; then
	ok "balance при упавшем WAN: весь трафик в LTE"
else
	fail "balance при упавшем WAN: трафик не переключился на LTE"
fi
if grep -q "jump to_lte" "$WORK/conf/nft.rules" 2>/dev/null &&
   ! grep -q "jump to_wan" "$WORK/conf/nft.rules" 2>/dev/null; then
	ok "balance при упавшем WAN: разметка только в LTE"
else
	fail "balance при упавшем WAN: разметка не переключилась"
fi
if grep -q "active=lte" "$WORK/state" 2>/dev/null; then
	ok "balance при упавшем WAN: активен LTE"
else
	fail "balance при упавшем WAN: в состоянии не lte"
fi

# --- 4.3 failover ---------------------------------------------------------
prep_conf failover 1 ""
run_daemon ""
if grep -q "100:.*lookup 100" "$WORK/conf/rules" 2>/dev/null; then
	ok "failover: правило на основной канал (WAN)"
else
	fail "failover: нет правила на WAN"
fi
if ! grep -q "fwmark" "$WORK/conf/rules" 2>/dev/null; then
	ok "failover: разметки по меткам нет"
else
	fail "failover: остались правила по меткам"
fi
if [ ! -f "$WORK/conf/nft.rules" ]; then
	ok "failover: nft-таблица не создаётся"
else
	fail "failover: nft-таблица создана зря"
fi

prep_conf failover 1 ""
run_daemon "eth0"
if grep -q "100:.*lookup 200" "$WORK/conf/rules" 2>/dev/null; then
	ok "failover при упавшем WAN: трафик в LTE"
else
	fail "failover при упавшем WAN: нет переключения на LTE"
fi

# --- 4.4 PBR --------------------------------------------------------------
prep_conf pbr 1 "77.88.8.0/21"
run_daemon ""
if grep -q "to 77.88.8.0/21 lookup 200" "$WORK/conf/rules" 2>/dev/null; then
	ok "pbr: адрес из списка идёт через LTE"
else
	fail "pbr: нет правила по адресу"
fi
if grep -q "900:.*lookup 100" "$WORK/conf/rules" 2>/dev/null; then
	ok "pbr: остальное идёт через WAN"
else
	fail "pbr: нет запасного правила на WAN"
fi

# --- 4.5 оба канала мертвы -------------------------------------------------
prep_conf balance 1 ""
run_daemon "eth0 eth1"
if [ ! -s "$WORK/conf/rules" ] 2>/dev/null; then
	ok "оба канала мертвы: правил не ставим"
else
	fail "оба канала мертвы: правила всё равно поставлены"
fi
if grep -q "active=none" "$WORK/state" 2>/dev/null; then
	ok "оба канала мертвы: в состоянии none"
else
	fail "оба канала мертвы: в состоянии не none"
fi

# --- 4.4a интерфейс берётся из общего дампа netifd ------------------------
# На устройстве объект "network.interface.wan" может не ответить - тогда
# интерфейс ищется в общем дампе netifd. Дамп - это МАССИВ объектов,
# а не объект с именами в качестве ключей, и в нём лежит полный статус
# интерфейса вместе с маршрутами. Шлюза в ядре в этом сценарии нет:
# он должен взяться из маршрута 0.0.0.0/0 в статусе netifd.
prep_conf failover 1 ""
touch "$WORK/conf/ifaces/wan.hidden"
grep -v "default via 192.168.1.1 dev eth0" "$WORK/conf/kernel_routes" > "$WORK/conf/kr.tmp"
mv "$WORK/conf/kr.tmp" "$WORK/conf/kernel_routes"
run_daemon ""
if grep -q "wan_gw=192.168.1.1" "$WORK/state" 2>/dev/null; then
	ok "интерфейс взят из общего дампа netifd"
else
	fail "интерфейс не взят из общего дампа netifd (wan_gw пустой)"
fi

# --- 4.4b шлюз берётся из таблицы маршрутизации ядра --------------------
# В статусе netifd маршрута по умолчанию нет (не все версии netifd его
# отдают) - тогда шлюз берётся из главной таблицы маршрутизации.
prep_conf failover 1 ""
cat > "$WORK/conf/ifaces/wan.json" <<'EOF'
{"up":true,"l3_device":"eth0","proto":"dhcp","ipv4-address":[{"address":"192.168.1.5","mask":24}],"data":{"dns":["8.8.8.8"]}}
EOF
run_daemon ""
if grep -q "wan_gw=192.168.1.1" "$WORK/state" 2>/dev/null; then
	ok "шлюз взят из таблицы маршрутизации ядра"
else
	fail "шлюз не взят из таблицы маршрутизации ядра (wan_gw пустой)"
fi

# --- 4.5a cleanup снимает правила с "to" (PBR) ----------------------------
# iproute2 сравнивает ВСЕ поля запроса с полями правила: правило
# "to <CIDR> lookup 200" не снимается командой "ip rule del pref N"
# без селектора "to". Модуоль обязан собирать команду удаления из
# самой строки "ip rule show".
prep_conf pbr 1 "77.88.8.0/21"
run_daemon ""
if grep -q "to 77.88.8.0/21 lookup 200" "$WORK/conf/rules" 2>/dev/null; then
	ok "pbr: правило с "to" поставлено"
else
	fail "pbr: правило с \"to\" не поставлено"
fi
PATH="$WORK/bin:$PATH" MOCK_CONF="$WORK/conf" PEJIR_MWAN_STATE="$WORK/state" \
	PEJIR_MWAN_APPLIED="$WORK/applied" PEJIR_MWAN_LOG="$WORK/log" \
	PEJIR_MWAN_NFT="$WORK/nft.rules.tmp" PEJIR_MWAN_PID="$WORK/pid" \
	PEJIR_MWAN_SYSNET="$WORK/sys" \
	sh "$DAEMON" cleanup
if [ ! -s "$WORK/conf/rules" ] 2>/dev/null; then
	ok "cleanup снимает правила с \"to\" (PBR)"
else
	fail "cleanup не снял правила с \"to\" (PBR)"
fi

# --- 4.6 модуль выключен --------------------------------------------------
prep_conf balance 0 ""
run_daemon ""
if [ ! -s "$WORK/conf/rules" ] 2>/dev/null; then
	ok "выключенный модуль не меняет маршрутизацию"
else
	fail "выключенный модуль всё равно поставил правила"
fi
if [ ! -f "$WORK/conf/nft.rules" ]; then
	ok "выключенный модуль не создаёт nft-таблицу"
else
	fail "выключенный модуль создал nft-таблицу"
fi

# --- 4.7 cleanup снимает всё ----------------------------------------------
prep_conf balance 1 ""
run_daemon ""
PATH="$WORK/bin:$PATH" MOCK_CONF="$WORK/conf" PEJIR_MWAN_STATE="$WORK/state" \
	PEJIR_MWAN_APPLIED="$WORK/applied" PEJIR_MWAN_LOG="$WORK/log" \
	PEJIR_MWAN_NFT="$WORK/nft.rules.tmp" PEJIR_MWAN_PID="$WORK/pid" \
	PEJIR_MWAN_SYSNET="$WORK/sys" \
	sh "$DAEMON" cleanup
if [ ! -s "$WORK/conf/rules" ] 2>/dev/null; then
	ok "cleanup снимает правила ip rule"
else
	fail "cleanup не снял правила ip rule"
fi
if [ ! -f "$WORK/conf/nft.rules" ]; then
	ok "cleanup снимает nft-таблицу"
else
	fail "cleanup не снял nft-таблицу"
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
	echo "ИТОГ: все проверки пройдены"
	exit 0
fi

echo "ИТОГ: провалено проверок: $FAILED"
exit 1
