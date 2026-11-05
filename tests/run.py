"""Run offline regressions: python tests/run.py --lua /path/to/lua54 [test.lua ...]."""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_TESTS = (
    "tests/entrypoint.lua",
    "tests/re4_entrypoint.lua",
    "tests/re4_localization.lua",
    "tests/re4_ops.lua",
    "tests/re4_model_v3.lua",
    "tests/re4_presets.lua",
    "tests/re4_dissolve.lua",
"tests/re4_height.lua",
    "tests/re4_targets.lua",
    "tests/re4_input_guard.lua",
    "tests/re4_portrait_camera.lua",
    "tests/re4_portrait_copy.lua",
    "tests/app_ui.lua",
    "tests/material_ui.lua",
    "tests/parts_ui.lua",
    "tests/condition_ui.lua",
    "tests/reff_bridge.lua",
    "tests/reff_conditions.lua",
    "tests/reff_settings.lua",
    "tests/reff_help.lua",
    "tests/wilds_hp.lua",
    "tests/portrait_service.lua",
    "tests/portrait_preview_regression.lua",
    "tests/portrait_camera_settings_regression.lua",
    "tests/rise_options.lua",
    "tests/config_compatibility.lua",
    "tests/config_store.lua",
    "tests/config_session.lua",
    "tests/global_settings.lua",
    "tests/preset_compatibility.lua",
    "tests/preset_editor.lua",
    "tests/preset_selection.lua",
    "tests/preset_capture.lua",
    "tests/preset_finder.lua",
    "tests/manual_import.lua",
    "tests/runtime_state.lua",
    "tests/wilds_equipment.lua",
    "tests/wilds_actors.lua",
    "tests/rise_equipment.lua",
    "tests/rise_actors.lua",
    "tests/rise_materials.lua",
    "tests/rise_dissolve.lua",
    "tests/rise_runtime.lua",
    "tests/rise_application.lua",
    "tests/wilds_application.lua",
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
    # 编译而不执行运行脚本；所有路径一次交给 Lua，回归用例仍各用独立进程。
    paths = sorted((ROOT / "ArmorVariantManager/reframework/autorun").rglob("*.lua"))
    script = 'assert(_VERSION == "Lua 5.4", "Lua 5.4 required"); for _, path in ipairs(arg) do assert(loadfile(path)) end'
    subprocess.run([lua, "-", *(path.relative_to(ROOT).as_posix() for path in paths)],
                   input=script, text=True, cwd=ROOT, check=True)
    print(f"PASS: syntax of {len(paths)} runtime Lua files", flush=True)
    for path in args.tests or DEFAULT_TESTS:
        print(f"RUN {path}", flush=True)
        subprocess.run([lua, path], cwd=ROOT, check=True)


if __name__ == "__main__":
    main()
