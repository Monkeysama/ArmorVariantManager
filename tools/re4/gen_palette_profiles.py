"""Generate Games/RE4/PaletteProfiles.lua from tools/re4/material_profiles/*.json.

The built-in material profiles ship as a Lua module (the release package carries no reframework/data files);
extra profiles written by users or mod authors are read at runtime from
reframework/data/ArmorVariantManager/material_profiles/*.json.

Usage (repository root): python tools/re4/gen_palette_profiles.py [--check]
--check exits with 1 when the generated file is out of date (used by the tests).
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "re4" / "material_profiles"
OUT = ROOT / "ArmorVariantManager" / "reframework" / "autorun" / "ArmorVariantManager_Core" / "Games" / "RE4" / "PaletteProfiles.lua"


def lua(value, indent=0):
    pad = "    " * indent
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
            return "{ " + ", ".join(lua(v) for v in value) + " }"
        return "{\n" + "".join(pad + "    " + lua(v, indent + 1) + ",\n" for v in value) + pad + "}"
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
        return "{\n" + "".join(pad + "    " + item + ",\n" for item in items) + pad + "}"
    raise TypeError(type(value))


def build():
    profiles = []
    for path in sorted(SRC.glob("*.json")):
        data = json.loads(path.read_text(encoding="utf-8"))
        data.pop("source", None)
        profiles.append(data)
    body = "".join("    " + lua(p, 1) + ",\n" for p in profiles)
    return ("-- 由 tools/re4/gen_palette_profiles.py 从 tools/re4/material_profiles/*.json 生成,不要手改。\n"
            "-- 内置材质映射;用户 / mod 作者的映射放在 reframework/data/ArmorVariantManager/material_profiles/。\n"
            "return {\n" + body + "}\n")


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
