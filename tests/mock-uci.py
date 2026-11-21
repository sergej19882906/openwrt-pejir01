#!/usr/bin/env python3
"""Мини-реализация uci для проверки wifi-config.sh и 47-pejir-lte.

Поддерживает подмножество, которое используют скрипты:
  uci -q get <pkg>.<sect>.<opt>
  uci -q get <pkg>.<sect>
  uci set <pkg>.<sect>=<type>
  uci set <pkg>.<sect>.<opt>=<value>
  uci commit [<pkg>]
  uci -q show <pkg>
  uci -q show <pkg>.<sect>.<opt>
"""
import os
import re
import sys

STATE = os.environ.get("UCI_STATE", "/tmp/uci_state")
CFG = os.path.join(STATE, "wireless")
NET = os.path.join(STATE, "network")


def load(path):
    data = {}
    if not os.path.exists(path):
        return data
    section = None
    with open(path) as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            m = re.match(r"config\s+(\S+)(?:\s+'?([^'\s]+)'?)?$", line)
            if m:
                section = m.group(2) or "@%s[%d]" % (m.group(1), len(data))
                data[section] = {"type": m.group(1), "options": {}, "order": []}
                continue
            m = re.match(r"option\s+(\S+)\s+'?([^']*)'?$", line)
            if m and section:
                data[section]["options"][m.group(1)] = m.group(2)
                data[section]["order"].append(m.group(1))
    return data


def save(path, data):
    with open(path, "w") as fh:
        for name, sec in data.items():
            if name.startswith("@"):
                fh.write("config %s\n" % sec["type"])
            else:
                fh.write("config %s '%s'\n" % (sec["type"], name))
            for opt in sec["order"]:
                fh.write("\toption %s '%s'\n" % (opt, sec["options"][opt]))


def dump(data, prefix, only=None):
    out = []
    for name, sec in data.items():
        if only and name != only:
            continue
        out.append("%s.%s=%s" % (prefix, name, sec["type"]))
        for opt, val in sec["options"].items():
            out.append("%s.%s.%s='%s'" % (prefix, name, opt, val))
    return out


def main():
    argv = sys.argv[1:]
    quiet = False
    if argv and argv[0] == "-q":
        quiet = True
        argv = argv[1:]
    if not argv:
        return 1
    cmd = argv[0]
    args = argv[1:]

    if cmd in ("get", "set", "show"):
        if not args:
            return 1
        first = args[0]
        pkg = first.split(".")[0]
    else:
        pkg = args[0].split(".")[0] if args else ""

    path = {"wireless": CFG, "network": NET}.get(pkg)
    if path is None:
        sys.stderr.write("uci: unknown package %s\n" % pkg)
        return 1
    data = load(path)

    if cmd == "get":
        key = args[0]
        parts = key.split(".")
        if len(parts) == 2:
            if parts[1] not in data:
                return 1
            print(data[parts[1]]["type"])
            return 0
        sect, opt = parts[1], parts[2]
        # Важно: у секции "config interface" нет опции "type" — тип секции
        # задаётся словом config. Реальный uci на "pkg.sect.type" отвечает
        # "Entry not found" и возвращает код 1 (проверено на uci 25.12).
        if sect not in data or opt not in data[sect]["options"]:
            return 1
        print(data[sect]["options"][opt])
        return 0

    if cmd == "set":
        key = args[0]
        if "=" in key:
            name, val = key.split("=", 1)
            parts = name.split(".")
            if len(parts) >= 3:
                # установка опции: pkg.section.option=value
                sect, opt = parts[1], parts[2]
                if sect not in data:
                    data[sect] = {"type": "wifi-iface", "options": {}, "order": []}
                if opt not in data[sect]["options"]:
                    data[sect]["order"].append(opt)
                data[sect]["options"][opt] = val
            else:
                # установка типа секции: pkg.section=type
                sect = parts[1]
                if sect not in data:
                    data[sect] = {"type": val, "options": {}, "order": []}
                else:
                    data[sect]["type"] = val
        else:
            parts = key.split(".")
            sect, opt = parts[1], parts[2]
            val = args[1] if len(args) > 1 else ""
            if sect not in data:
                data[sect] = {"type": "wifi-iface", "options": {}, "order": []}
            if opt not in data[sect]["options"]:
                data[sect]["order"].append(opt)
            data[sect]["options"][opt] = val
        save(path, data)
        return 0

    if cmd == "commit":
        save(path, data)
        return 0

    if cmd == "show":
        only = None
        if len(args) > 1:
            only = args[1].split(".")[-1]
        for line in dump(data, pkg, only):
            print(line)
        return 0

    sys.stderr.write("uci: unsupported command %s\n" % cmd)
    return 1


if __name__ == "__main__":
    sys.exit(main())
