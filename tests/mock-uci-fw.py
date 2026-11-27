#!/usr/bin/env python3
"""Минимальный мок uci для проверок 47-pejir-lte (сеть + файрвол).

Поддерживает подмножество, нужное скрипту:
  uci -q get <pkg>.<sect>
  uci -q get <pkg>.<sect>.<opt>
  uci set <pkg>.<sect>=<type>
  uci set <pkg>.<sect>.<opt>=<value>
  uci -q add_list <pkg>.<sect>.<opt>=<value>
  uci commit [<pkg>]
  uci -q show <pkg>

Секции вида @zone[0] адресуются по порядковому номеру среди секций
одного типа в пакете (как в настоящем uci).

Состояние живёт в файле $UCI_FW_STATE (формат: "pkg.sect[.opt]=value"
по строке на запись).
"""
import os
import re
import sys

STATE = os.environ.get("UCI_FW_STATE", "/tmp/uci_fw_state")


def load():
    data = {}          # "pkg.sect" -> {"type":..., "opts":{opt:val}}
    order = []         # порядок секций внутри пакета
    if not os.path.exists(STATE):
        return data, order
    with open(STATE) as fh:
        for raw in fh:
            raw = raw.strip()
            if not raw or raw.startswith("#"):
                continue
            key, _, val = raw.partition("=")
            pkg, sect_expr, opt = parse(key)
            if not sect_expr:
                continue
            if opt is None:
                data.setdefault((pkg, sect_expr), {"type": val, "opts": {}})
                order.append((pkg, sect_expr))
            else:
                data.setdefault((pkg, sect_expr), {"type": "", "opts": {}})
                data[(pkg, sect_expr)]["opts"][opt] = val
    return data, order


def save(data, order):
    with open(STATE, "w") as fh:
        for pkg, sect in order:
            sec = data[(pkg, sect)]
            fh.write("%s.%s=%s\n" % (pkg, sect, sec["type"]))
            for opt, val in sec["opts"].items():
                fh.write("%s.%s.%s=%s\n" % (pkg, sect, opt, val))


def parse(key):
    """key вида network.lte или firewall.@zone[0].name -> (pkg, sect_expr, opt)."""
    parts = key.split(".")
    pkg = parts[0]
    rest = parts[1:]
    if not rest:
        return pkg, "", None
    return pkg, rest[0], (rest[1] if len(rest) > 1 else None)


def resolve(data, order, key):
    """key вида network.lte или firewall.@zone[0] -> (pkg, real_sect)."""
    pkg, sect_expr, _ = parse(key)
    m = re.match(r"^@(\w+)\[(\d+)\]$", sect_expr)
    if m:
        want_type, idx = m.group(1), int(m.group(2))
        n = 0
        for p, s in order:
            if p != pkg:
                continue
            if data[(p, s)]["type"] == want_type:
                if n == idx:
                    return pkg, s
                n += 1
        return None, None
    if (pkg, sect_expr) in data:
        return pkg, sect_expr
    return None, None


def main():
    argv = sys.argv[1:]
    while argv and argv[0].startswith("-"):
        if argv[0] == "-q":
            argv = argv[1:]
        elif argv[0] == "-c":
            argv = argv[2:]
        else:
            argv = argv[1:]
    if not argv:
        return 1
    cmd = argv.pop(0)
    args = argv
    data, order = load()

    if cmd == "commit":
        save(data, order)
        return 0

    if cmd == "show":
        for pkg, sect in order:
            if args and args[0] != pkg:
                continue
            sec = data[(pkg, sect)]
            print("%s.%s=%s" % (pkg, sect, sec["type"]))
            for opt, val in sec["opts"].items():
                print("%s.%s.%s='%s'" % (pkg, sect, opt, val))
        return 0

    if cmd in ("get", "set", "add_list"):
        if not args:
            return 1
        key = args[0].split("=", 1)[0]
        pkg, sect = resolve(data, order, key)
        if cmd == "get":
            if sect is None:
                return 1
            opt = parse(key)[2]
            if opt is None:
                return 0
            if opt not in data[(pkg, sect)]["opts"]:
                return 1
            print(data[(pkg, sect)]["opts"][opt])
            return 0
        # set / add_list
        value = ""
        if cmd == "add_list" and len(args) > 1:
            value = args[1]
        elif "=" in args[0]:
            value = args[0].split("=", 1)[1]
        opt = parse(key)[2]
        if opt is not None:
            if sect is None:
                return 1
            if cmd == "add_list":
                cur = data[(pkg, sect)]["opts"].get(opt, "")
                parts = cur.split() if cur else []
                if value not in parts:
                    parts.append(value)
                data[(pkg, sect)]["opts"][opt] = " ".join(parts)
            else:
                data[(pkg, sect)]["opts"][opt] = value
        else:
            sect_expr = parse(key)[1]
            if sect is None:
                data[(pkg, sect_expr)] = {"type": value, "opts": {}}
                order.append((pkg, sect_expr))
            else:
                data[(pkg, sect)]["type"] = value
        save(data, order)
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
