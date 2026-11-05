"""Generate Games/RE4/MaterialEffects.lua: which palette parameters have no effect when a texture slot is a null texture.

Source: the RE4 material library built offline from mmtr shaders (REE-Modding-Skill, library.json). Only what the
runtime needs is kept, in tools/re4/material_effects.json (committed); the Lua module is generated from that.

Usage (repository root):
  python tools/re4/gen_material_effects.py --import <library.json>   refresh material_effects.json, then generate
  python tools/re4/gen_material_effects.py                            generate from material_effects.json
  python tools/re4/gen_material_effects.py --check                    exit 1 when the Lua module is out of date
"""
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "tools" / "re4" / "material_effects.json"
OUT = ROOT / "ArmorVariantManager" / "reframework" / "autorun" / "ArmorVariantManager_Core" / "Games" / "RE4" / "MaterialEffects.lua"


def import_library(path):
    lib = json.loads(Path(path).read_text(encoding="utf-8"))
    nulls = set(lib.get("nullTextures", {}))
    masters = []
    for mid, m in sorted(lib.get("masters", {}).items()):
        rules = []
        for r in m.get("ineffective", []):
            when = r.get("when", {})
            names = when.get("isNull", [])
            if not names or not r.get("param") or not when.get("texture"):
                continue
            nulls.update(n for n in names if n != "*")
            rules.append({"param": r["param"], "components": r.get("components", ""), "texture": when["texture"],
                          "nulls": ["*"] if "*" in names else sorted(names)})
        rules.sort(key=lambda r: (r["texture"], r["param"], r["components"]))
        masters.append({"id": mid, "aliases": sorted(m.get("aliases", [])),
                        "params": m["signature"]["paramCount"], "textures": sorted(m["signature"]["textures"]),
                        "rules": rules})
    data = {"source": "RE4 material library v%s (REE-Modding-Skill, library.json)" % lib.get("version"),
            "nulls": sorted(nulls), "masters": masters}
    SRC.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")


def q(s):
    return json.dumps(s, ensure_ascii=False)


def render():
    data = json.loads(SRC.read_text(encoding="utf-8"))
    nulls = data["nulls"]
    index = {n: i + 1 for i, n in enumerate(nulls)}
    lines = [
        "-- 由 tools/re4/gen_material_effects.py 从 tools/re4/material_effects.json 生成,不要手改。",
        "-- 来源:" + data["source"] + "。",
        "-- 贴图槽绑定 null 贴图时哪些参数(分量)改了不生效:rule = { 参数名, 分量, 贴图槽, null 序号列表 | \"*\"(任意 null) }。",
        "-- 母材质按签名认:参数个数 + 贴图槽名集合(运行时拿不到 mmtr 路径)。",
        "return {",
        "    nulls = {",
    ]
    lines += ["        %s," % q(n) for n in nulls]
    lines += ["    },", "    masters = {"]
    for m in data["masters"]:
        lines.append("        {")
        lines.append("            id = %s," % q(m["id"]))
        lines.append("            params = %d," % m["params"])
        lines.append("            textures = { %s }," % ", ".join(q(t) for t in m["textures"]))
        lines.append("            rules = {")
        for r in m["rules"]:
            ns = q("*") if r["nulls"] == ["*"] else "{ " + ", ".join(str(index[n]) for n in r["nulls"]) + " }"
            lines.append("                { %s, %s, %s, %s }," % (q(r["param"]), q(r["components"]), q(r["texture"]), ns))
        lines.append("            },")
        lines.append("        },")
    lines += ["    },", "}", ""]
    return "\n".join(lines)


def main(argv):
    if "--import" in argv:
        import_library(argv[argv.index("--import") + 1])
    text = render()
    if "--check" in argv:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current != text:
            print("MaterialEffects.lua is out of date; run python tools/re4/gen_material_effects.py")
            return 1
        return 0
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print("wrote %s (%d bytes)" % (OUT.relative_to(ROOT), len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
