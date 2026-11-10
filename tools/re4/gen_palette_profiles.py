"""Generate Games/RE4/PaletteProfiles.lua from tools/re4/material_profiles/*.json.

The built-in material profiles ship as a Lua module (the release package carries no reframework/data files);
extra profiles written by users or mod authors are read at runtime from
reframework/data/ArmorVariantManager/material_profiles/*.json.

Usage (repository root): python tools/re4/gen_palette_profiles.py [--check]
--check exits with 1 when the generated file is out of date (used by the tests).

Shared dictionary: most parameters mean the same thing in every master, so an entry that is identical in two or more
profiles (same fields, same enum options) is written once under `params[<name>]` and the profiles reference it as
`"<name>"` (all of the dictionary's entries, in order) or `{ param = "<name>", refs = { i, ... } }`.
An entry that differs from the dictionary's version stays inline in its profile: that is how exceptions are kept.
The JSON sources stay complete; Palette.load_profiles expands the references when it loads the built-in profiles.
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "re4" / "material_profiles"
OUT = ROOT / "ArmorVariantManager" / "reframework" / "autorun" / "ArmorVariantManager_Core" / "Games" / "RE4" / "PaletteProfiles.lua"


def lua(value, indent=0):
    pad = "\t" * indent
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        if not value:
            return "{}"
        if all(not isinstance(v, (dict, list)) for v in value):
            flat = "{ " + ", ".join(lua(v) for v in value) + " }"
            if len(flat) <= 110:
                return flat
        items = [lua(v, indent + 1) for v in value]
        if all("\n" not in it for it in items):
            # short items: pack several per line
            lines, cur = [], ""
            for it in items:
                if cur and len(pad) * 4 + 4 + len(cur) + len(it) + 2 > 120:
                    lines.append(cur)
                    cur = ""
                cur += it + ", "
            if cur:
                lines.append(cur)
            return "{\n" + "".join(pad + "\t" + ln.rstrip() + "\n" for ln in lines) + pad + "}"
        return "{\n" + "".join(pad + "\t" + it + ",\n" for it in items) + pad + "}"
    if isinstance(value, dict):
        if not value:
            return "{}"
        items = []
        for k, v in value.items():
            key = k if k.isidentifier() else "[" + json.dumps(k, ensure_ascii=False) + "]"
            items.append(f"{key} = {lua(v, indent + 1)}")
        flat = "{ " + ", ".join(items) + " }"
        if len(flat) <= 110 and "\n" not in flat:
            return flat
        return "{\n" + "".join(pad + "\t" + item + ",\n" for item in items) + pad + "}"
    raise TypeError(type(value))


def slot_of(e):
    return e.get("component") or "*"


def variant_of(e, profile):
    enum = e.get("enum")
    defs = (profile.get("enums") or {}).get(enum) if enum else None
    return json.dumps([e, defs], ensure_ascii=False, sort_keys=True)


def dedupe(profiles):
    # count each (param, slot, variant) once per profile
    counts, order, entry_of = {}, {}, {}
    for p in profiles:
        seen = set()
        for g in p.get("groups", []):
            for e in g.get("params", []):
                key = (e["param"], slot_of(e), variant_of(e, p))
                entry_of.setdefault(key, e)
                if key not in seen:
                    seen.add(key)
                    counts[key] = counts.get(key, 0) + 1
                order.setdefault(e["param"], [])
                if slot_of(e) not in order[e["param"]]:
                    order[e["param"]].append(slot_of(e))
    # canonical variant per (param, slot): the most common one, used by at least two profiles
    best = {}
    for (param, slot, var), n in counts.items():
        if n < 2:
            continue
        cur = best.get((param, slot))
        if cur is None or n > cur[1] or (n == cur[1] and var < cur[0]):
            best[(param, slot)] = (var, n)
    dictionary, index = {}, {}
    for param in sorted(order):
        for slot in order[param]:
            b = best.get((param, slot))
            if b:
                lst = dictionary.setdefault(param, [])
                lst.append(entry_of[(param, slot, b[0])])
                index[(param, slot, b[0])] = len(lst)
    out = []
    for p in profiles:
        q = dict(p)
        q["groups"] = []
        for g in p.get("groups", []):
            h = dict(g)
            params = []
            for e in g.get("params", []):
                i = index.get((e["param"], slot_of(e), variant_of(e, p)))
                last = params[-1] if params else None
                if i is None:
                    params.append(e)
                elif last is not None and "kind" not in last and last["param"] == e["param"]:
                    last["refs"].append(i)
                else:
                    params.append({"param": e["param"], "refs": [i]})
            for r in params:
                if "kind" not in r and r["refs"] == list(range(1, len(dictionary[r["param"]]) + 1)):
                    del r["refs"]
            # a reference to all of a parameter's dictionary entries is written as just its name
            h["params"] = [r["param"] if ("kind" not in r and "refs" not in r) else r for r in params]
            q["groups"].append(h)
        out.append(q)
    # the references must expand back to exactly the source entries
    for src, q in zip(profiles, out):
        for gs, gq in zip(src.get("groups", []), q["groups"]):
            expanded = []
            for r in gq["params"]:
                if isinstance(r, str):
                    r = {"param": r}
                if "kind" in r:
                    expanded.append(r)
                else:
                    lst = dictionary[r["param"]]
                    expanded.extend(lst[i - 1] for i in r.get("refs", range(1, len(lst) + 1)))
            assert expanded == gs.get("params", []), (src.get("id"), gs.get("id"))
    return dictionary, out


def build():
    profiles = []
    for path in sorted(SRC.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        data.pop("source", None)
        profiles.append(data)
    dictionary, profiles = dedupe(profiles)
    nl = chr(10)
    params = "".join("\t\t[" + json.dumps(k, ensure_ascii=False) + "] = " + lua(v, 2) + "," + nl
                     for k, v in dictionary.items())
    body = "".join("\t\t" + lua(p, 2) + "," + nl for p in profiles)
    head = [
        "-- 由 tools/re4/gen_palette_profiles.py 从 tools/re4/material_profiles/*.json 生成,不要手改。",
        "-- 内置材质映射;用户 / mod 作者的映射放在 reframework/data/ArmorVariantManager/material_profiles/。",
        "-- params:共享参数字典(多份映射里完全相同的项只写一次);profiles 里不带 kind 的项是对它的引用。",
        "return {",
        "\tparams = {",
    ]
    return nl.join(head) + nl + params + "\t}," + nl + "\tprofiles = {" + nl + body + "\t}," + nl + "}" + nl


def main():
    text = build()
    if "--check" in sys.argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print(f"{OUT.relative_to(ROOT)} is out of date; run python tools/re4/gen_palette_profiles.py")
            sys.exit(1)
        print("PaletteProfiles.lua is up to date")
        return
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.relative_to(ROOT)} ({len(text)} bytes)")


if __name__ == "__main__":
    main()
