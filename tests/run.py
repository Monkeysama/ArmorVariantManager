"""Run offline regressions: python tests/run.py --lua /path/to/lua54 [test.lua ...]."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TESTS = (
    "tests/config_compatibility.lua",
    "tests/config_store.lua",
    "tests/config_session.lua",
    "tests/preset_compatibility.lua",
    "tests/preset_editor.lua",
    "tests/preset_selection.lua",
    "tests/preset_capture.lua",
    "tests/preset_finder.lua",
    "tests/visibility.lua",
    "tests/condition_ui.lua",
    "tests/material_ui.lua",
    "tests/runtime_state.lua",
    "tests/wilds_equipment.lua",
    "tests/wilds_actors.lua",
    "tests/wilds_runtime.lua",
    "tests/rise_equipment.lua",
    "tests/rise_actors.lua",
    "tests/rise_materials.lua",
    "tests/rise_dissolve.lua",
    "tests/rise_runtime.lua",
    "tests/appearance.lua",
    "tests/rules_compatibility.lua",
    "tests/high_heel_height_regression.lua",
    "tests/ground_clipping_targets_regression.lua",
    "tests/scanner_ui_regression.lua",
)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lua", default=os.environ.get("LUA", "lua"), help="Lua 5.4 executable (or set LUA)")
    parser.add_argument("tests", nargs="*", help="Lua test paths relative to repository root")
    args = parser.parse_args()
    lua = shutil.which(args.lua)
    if not lua:
        parser.error("Lua 5.4 not found; pass --lua or set LUA to an existing executable")
    subprocess.run([lua, "-e", 'assert(_VERSION == "Lua 5.4", "Lua 5.4 required")'], check=True)
    for path in args.tests or DEFAULT_TESTS:
        print(f"RUN {path}", flush=True)
        subprocess.run([lua, path], cwd=ROOT, check=True)
    # 编译而不执行运行脚本；不依赖独立安装的 luac。
    paths = sorted((ROOT / "ArmorVariantManager/reframework/autorun").rglob("*.lua"))
    for path in paths:
        subprocess.run([lua, "-e", 'assert(loadfile(arg[0])); os.exit(0)', str(path)], cwd=ROOT, check=True)
    print(f"PASS: syntax of {len(paths)} runtime Lua files")


if __name__ == "__main__":
    main()
