"""Generate Games/RE9/MaterialEffects.lua: palette parameters that have no effect while a texture slot uses a null texture.

RE9 has no offline material library. The RE4 rules (tools/re4/material_effects.json) are keyed by parameter and texture
slot names, which RE Engine shares across games, and almost never differ between RE4 master materials. So the RE9 module
merges them into one generic rule set that is not tied to a master material, and maps RE4 null textures to RE9 ones by
family (base name without a trailing size: nullwhite_64 and nullwhite_2048 are both "nullwhite").

Usage (repository root):
  python tools/re9/gen_material_effects.py --import-nulls <RE9_STM.list>   refresh re9_null_textures.txt, then generate
  python tools/re9/gen_material_effects.py                                generate
  python tools/re9/gen_material_effects.py --check                        exit 1 when the Lua module is out of date
"""
import json
import re
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
RE4_SRC = ROOT / "tools" / "re4" / "material_effects.json"
NULLS = ROOT / "tools" / "re9" / "re9_null_textures.txt"
OUT = ROOT / "ArmorVariantManager" / "reframework" / "autorun" / "ArmorVariantManager_Core" / "Games" / "RE9" / "MaterialEffects.lua"


def norm(path):
    p = path.strip().replace("\\", "/").lower()
    p = re.sub(r"^natives/stm/", "", p)
    return re.sub(r"\.tex(\.\d+)?$", "", p)


def family(path):
    return re.sub(r"_\d+$", "", path.rsplit("/", 1)[-1])


def import_nulls(list_path):
    names = set()
    for line in Path(list_path).read_text(encoding="utf-8", errors="replace").splitlines():
        low = line.strip().lower()
        if re.search(r"/null[^/]*\.tex\.\d+$", low):
            names.add(norm(low))
    NULLS.write_text("".join(n + "\n" for n in sorted(names)), encoding="utf-8")


def render():
    re4 = json.loads(RE4_SRC.read_text(encoding="utf-8"))
    nulls = [n for n in NULLS.read_text(encoding="utf-8").splitlines() if n.strip()]
    by_family = defaultdict(list)
    for i, n in enumerate(nulls, 1):
        by_family[family(n)].append(i)
    re4_nulls = re4["nulls"]
    merged = defaultdict(set)     # (param, comps, texture) -> RE9 null indices, or {"*"}
    for m in re4["masters"]:
        for r in m["rules"]:
            key = (r["param"], r["components"], r["texture"])
            if r["nulls"] == ["*"]:
                merged[key].add("*")
                continue
            for name in r["nulls"]:
                merged[key].update(by_family.get(family(name), []))
    rules = []
    for (param, comps, texture), ids in sorted(merged.items()):
        if "*" in ids:
            rules.append((param, comps, texture, "*"))
        elif ids:
            rules.append((param, comps, texture, sorted(ids)))
    q = lambda s: json.dumps(s, ensure_ascii=False)
    lines = [
        "-- 由 tools/re9/gen_material_effects.py 生成,不要手改。",
        "-- RE9 没有离线材质库:规则取自 RE4(tools/re4/material_effects.json),按参数名 + 贴图槽名合并成一份不分母材质的",
        "-- 通用规则;null 贴图来自 RE9 的文件清单(tools/re9/re9_null_textures.txt),按去掉尺寸后缀的名字和 RE4 的对应。",
        "-- rule = { 参数名, 分量, 贴图槽, null 序号列表 | \"*\"(任意 null) }。",
        "return {",
        "    nulls = {",
    ]
    lines += ["        %s," % q(n) for n in nulls]
    lines += ["    },", "    masters = {", "        {", '            id = "re9.generic", generic = true, params = 0, textures = {},', "            rules = {"]
    for param, comps, texture, ids in rules:
        ids_s = '"*"' if ids == "*" else "{ " + ", ".join(str(i) for i in ids) + " }"
        lines.append("                { %s, %s, %s, %s }," % (q(param), q(comps), q(texture), ids_s))
    lines += ["            },", "        },", "    },", "}", ""]
    return "\n".join(lines)


def main(argv):
    if len(argv) >= 2 and argv[0] == "--import-nulls":
        import_nulls(argv[1])
    text = render()
    if argv[:1] == ["--check"]:
        current = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if current.replace("\r\n", "\n") != text:
            print("Games/RE9/MaterialEffects.lua is out of date; run tools/re9/gen_material_effects.py")
            return 1
        return 0
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print("wrote %s" % OUT.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
