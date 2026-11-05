"""Write tools/re4/material_profiles/auto_*.json: palette mappings for vanilla RE4 master materials, generated from
the offline material library (REE-Modding-Skill, library.json): names, function blocks, component split, ranges.

Hand-written mappings (re4_liltoon / re4_transparent / re4_dissolve) are not touched: masters from the user's own
lilToon family are skipped, and auto profiles have a low priority so any hand-written match wins.
Auto profiles match by recognised master (match.master, see Palette.lua) instead of parameter names.

Usage (repository root):
  python tools/re4/gen_auto_profiles.py <library.json>
  python tools/re4/gen_palette_profiles.py            # then regenerate PaletteProfiles.lua
"""
import json
import math
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "tools" / "re4" / "material_profiles"
SKIP = "/dimcirui/"            # the user's lilToon family has hand-written mappings
PRIORITY = 10                  # below every hand-written mapping

# library group id -> palette section
SECTION = {
    "base": "color", "detail": "color", "imperfect": "color", "record": "color", "stitch": "color", "leather": "color",
    "fading": "color", "scar": "color", "damage": "color", "tear": "color", "microdetail": "color",
    "native_rim": "light", "fresnel": "light", "hair": "light", "velvet": "light", "eye": "light", "occlusion": "light",
    "surface": "surface", "alpha": "surface", "wrinkle": "surface", "face_wrinkle": "surface", "flatten": "surface",
    "parallax": "surface", "rain": "surface", "heat": "surface", "oilfilm": "surface", "fakesphere": "surface", "glass": "surface",
    "native_emission": "emission", "bulb": "emission", "lampshade": "emission", "emission_fade": "emission",
}
SECTIONS = [
    {"id": "color", "label": {"zh": "颜色层", "en": "Colour layers"}},
    {"id": "light", "label": {"zh": "明暗", "en": "Light and shade"}},
    {"id": "surface", "label": {"zh": "质感", "en": "Surface"}},
    {"id": "emission", "label": {"zh": "发光", "en": "Emission"}},
    {"id": "system", "label": {"zh": "系统", "en": "System"}},
]
# groups shown under "basic"; the rest go to "advanced"
BASIC_GROUPS = {"base", "record", "native_emission", "native_rim", "fresnel", "hair", "eye", "detail", "stitch", "leather"}
# Low-confidence parameters (meaning only guessed from the name) go to a third area, "Other", outside basic / advanced.
# Their label is "Chinese (original name)"; when even the name is unclear, only the original name is shown.
UNCLEAR = re.compile(r"^(Rec_RTTChannelControl|SSSChannel|SSS_Channel|RimColorDetail|LayerNum|LightRecieve|Weight\d+)$")
# Ray tracing: "RT" / "RayTrac" in the name (not RTT = render-to-texture) and not read by the raster shaders
RAYTRACE = re.compile(r"(^|_)(RT(?!T)|RayTrac)")
RT_NOTE = {"zh": "可能只在开启光追时有效", "en": "Probably only effective with ray tracing on"}


def text(zh, en):
    return {"zh": zh or en or "", "en": en or zh or ""}


def low(p):
    return p.get("confidence") == "low"


def note_of(name, p):
    zh, en = p.get("note") or "", ""
    if RAYTRACE.search(name) and not p.get("pixelComponents"):
        zh, en = (zh + "；" if zh else "") + RT_NOTE["zh"], RT_NOTE["en"]
    return text(zh, en) if (zh or en) else None


def label_of(name, p):
    zh, en = p.get("zh") or name, p.get("en") or name
    if not low(p):
        return zh, en
    if UNCLEAR.match(name) or zh == name:
        return name, name
    return f"{zh}（{name}）", name


def slider(p, rng):
    if rng and len(rng) == 2:
        return rng[0], rng[1]
    d = p.get("default")
    d = d[0] if isinstance(d, list) and d else d
    top = max(1.0, math.ceil(abs(d) * 2)) if isinstance(d, (int, float)) else 1.0
    return (-top if isinstance(d, (int, float)) and d < 0 else 0.0), top


def entries(name, p):
    used = (p.get("pixelComponents") or "") + (p.get("vertexComponents") or "")
    rt_only = RAYTRACE.search(name) and not used
    if p.get("noEffect") or (not used and not rt_only):
        return []
    if rt_only:
        used = "xyzw" if p["type"] == "float4" else "x"
    zh, en = label_of(name, p)
    note = note_of(name, p)
    out = []

    def add(e):
        if note and "note" not in e:
            e["note"] = note
        if low(p):
            e["tier"] = "other"
        out.append(e)

    if p["type"] == "float":
        if p.get("kind") == "switch":
            add({"param": name, "kind": "bool", "label": text(zh, en), "tier": "basic"})
        else:
            lo, hi = slider(p, p.get("range"))
            add({"param": name, "kind": "float", "min": lo, "max": hi, "label": text(zh, en), "tier": "more"})
        return out
    comps = p.get("components") or {}
    if not comps:
        add({"param": name, "kind": "vec", "label": text(zh, en), "tier": "more"})
        return out
    color = all((comps.get(c) or {}).get("kind") == "color" for c in "xyz")
    if color:
        add({"param": name, "kind": "color", "channels": "rgb", "label": text(zh, en), "tier": "basic"})
    for c in "xyzw":
        info = comps.get(c) or {}
        if (color and c in "xyz") or info.get("kind") == "unused" or c not in used:
            continue
        lo, hi = slider(p, info.get("range") or p.get("range"))
        kind = "bool" if info.get("kind") == "switch" else "float"
        cz = c.upper() if (low(p) and zh == name) else (info.get("zh") or c.upper())
        e = {"param": name, "component": c, "kind": kind,
             "label": text(f"{zh} · {cz}", f"{en} · {info.get('en') or c.upper()}"),
             "tier": "basic" if kind == "bool" else "more"}
        if kind == "float":
            e["min"], e["max"] = lo, hi
        add(e)
    return out


def short(mid):
    return re.sub(r"\.mmtr$", "", mid.rsplit("/", 1)[-1])


def main(argv):
    if not argv:
        print(__doc__)
        return 2
    lib = json.loads(Path(argv[0]).read_text(encoding="utf-8"))
    groups_meta = lib.get("groups", {})
    # masters with the same signature (parameter count + texture slots) cannot be told apart at runtime: one profile
    by_sig = {}
    for mid, m in sorted(lib["masters"].items()):
        if SKIP in mid:
            continue
        sig = (m["signature"]["paramCount"], tuple(sorted(m["signature"]["textures"])))
        by_sig.setdefault(sig, []).append((mid, m))
    for old in OUT.glob("auto_*.json"):
        old.unlink()
    written = []
    for members in by_sig.values():
        mid, m = members[0]
        ids = [x[0] for x in members]
        groups, order = {}, []
        for name, p in m["params"].items():
            es = entries(name, p)
            if not es:
                continue
            base = p.get("group") or "misc"
            gid = base + "_other" if low(p) else base
            if gid not in groups:
                meta = groups_meta.get(base, {})
                groups[gid] = {"id": gid, "section": SECTION.get(base, "system"),
                               "tier": "other" if low(p) else ("basic" if base in BASIC_GROUPS else "more"),
                               "label": text(meta.get("zh") or base, meta.get("en") or base), "params": []}
                order.append(gid)
            groups[gid]["params"].extend(es)
        if not order:
            continue           # e.g. bindless-only masters: no parameter is known to reach the output
        names = " / ".join(short(i) for i in ids)
        profile = {
            "format": 1, "id": "auto_" + short(mid),
            "source": "自动生成：tools/re4/gen_auto_profiles.py ← 离线材质库 library.json（%s）" % ", ".join(ids),
            "label": text("原版：" + names, "Vanilla: " + names), "priority": PRIORITY,
            "match": {"master": ids}, "sections": SECTIONS,
            "groups": [groups[g] for g in sorted(order, key=lambda g: [s["id"] for s in SECTIONS].index(groups[g]["section"]))],
        }
        path = OUT / (profile["id"] + ".json")
        path.write_text(json.dumps(profile, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        written.append((path.name, sum(len(g["params"]) for g in profile["groups"]), len(ids)))
    for name, n, k in written:
        print(f"{name}: {n} entries" + (f" (shared by {k} masters)" if k > 1 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
