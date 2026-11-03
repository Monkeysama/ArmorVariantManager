"""python -m unittest discover -s tests -p test_release.py"""
from pathlib import Path
from contextlib import ExitStack, contextmanager, redirect_stdout
import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import build_release as release


LUA = os.environ.get("LUA") or shutil.which("lua54") or shutil.which("lua")


@contextmanager
def release_inputs(root):
    autorun = root / "source/reframework/autorun"
    scripts = {
        "ArmorVariantManager.lua": 'local version = "1.2.3"\nreturn version\n',
        "ArmorVariantManager_Core/PresetAutoFinder.lua": 'return require("ArmorVariantManager_Core.Games.Rise.PresetSearch")\n',
        "ArmorVariantManager_Core/Games/Rise/PresetSearch.lua": 'return {game="Rise"}\n',
        "ArmorVariantManager_Core/TransformManager.lua": 'return require("ArmorVariantManager_Core.Games.Wilds.Rules")\n',
        "ArmorVariantManager_Core/Games/Wilds/Rules.lua": 'return {game="Wilds"}\n',
    }
    for name, content in scripts.items():
        path = autorun / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("-- removed by release\n\n" + content, encoding="utf-8")
    plugin = root / "source/reframework/reff/plugins/monkeysama.avm"
    (plugin / "ui/dist/assets").mkdir(parents=True)
    (plugin / "manifest.json").write_text(json.dumps({
        "id": "monkeysama.avm", "games": ["MHWILDS", "MHRISE"],
        "ui": {"entry": "ui/dist/index.html"}, "extra": {"keep": True},
    }), encoding="utf-8")
    for name in ("index.html", "REFF-LICENSE.txt", "assets/page.js", "assets/page.css"):
        (plugin / "ui/dist" / name).write_text(name, encoding="utf-8")
    paths = {
        "AUTORUN_SOURCE": autorun,
        "REFF_PLUGIN": plugin,
        "UI_DLL": root / "source/reframework/plugins/ArmorVariantManager_UI.dll",
        "PORTRAIT_DLL": root / "source/reframework/plugins/ArmorVariantManager_Portrait.dll",
        "PORTRAIT_ASSETS": root / "source/natives/STM/ArmorVariantManager/Portrait",
        "LICENSE": root / "source/LICENSE",
        "NATIVE_LICENSES": root / "source/reframework/plugins/source/THIRD_PARTY_LICENSES.txt",
        "D2D_LICENSE": root / "source/reframework/plugins/source/d2d/LICENSE",
    }
    for key in ("UI_DLL", "PORTRAIT_DLL", "LICENSE", "NATIVE_LICENSES", "D2D_LICENSE"):
        paths[key].parent.mkdir(parents=True, exist_ok=True)
        paths[key].write_bytes(key.encode())
    paths["PORTRAIT_ASSETS"].mkdir(parents=True)
    for name in release.PORTRAIT_FILES:
        (paths["PORTRAIT_ASSETS"] / name).write_bytes(name.encode())
    # 同一源目录中的真实开发/用户内容不能跟随打包。
    for name in ("source/reframework/data/player.json", "source/AvatarVariantManager.dev.txt",
                 "source/reframework/reff/node_modules/dependency.js"):
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("not released", encoding="utf-8")
    with ExitStack() as stack:
        for name, path in paths.items():
            stack.enter_context(patch.object(release, name, path))
        stack.enter_context(redirect_stdout(io.StringIO()))
        yield


class ReleaseTests(unittest.TestCase):
    def assert_inventory(self, directory, archive_path, game):
        expected = {"LICENSE"}
        expected.update("reframework/autorun/" + path.relative_to(release.AUTORUN_SOURCE).as_posix()
                        for path in release.AUTORUN_SOURCE.rglob("*.lua"))
        expected.update("reframework/reff/plugins/monkeysama.avm/" + path.relative_to(release.REFF_PLUGIN).as_posix()
                        for path in release.REFF_PLUGIN.rglob("*") if path.is_file())
        if game == "wilds":
            expected.update("reframework/plugins/" + path.name for path in (release.UI_DLL, release.PORTRAIT_DLL))
            expected.update("natives/STM/ArmorVariantManager/Portrait/" + name for name in release.PORTRAIT_FILES)
            expected.update(("licenses/THIRD_PARTY_LICENSES.txt", "licenses/reframework-d2d-LICENSE.txt"))
        actual = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file()}
        self.assertEqual(actual, expected)
        with release.zipfile.ZipFile(archive_path) as archive:
            self.assertEqual(set(archive.namelist()), expected)
            for name in expected:
                self.assertEqual(archive.read(name), (directory / name).read_bytes())
        manifest_path = directory / "reframework/reff/plugins/monkeysama.avm/manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["games"], [release.GAMES[game]])
        self.assertEqual(manifest["extra"], {"keep": True})

    def test_all_games_have_complete_separate_inventories_and_manifests(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                self.assertEqual(release.main(["--game", "all", "--output-dir", str(root / "out")]), 0)
                for game in release.GAMES:
                    directory, archive = release.release_paths(root / "out", "1.2.3", game)
                    self.assert_inventory(directory, archive, game)
                    for source in release.AUTORUN_SOURCE.rglob("*.lua"):
                        output = directory / "reframework/autorun" / source.relative_to(release.AUTORUN_SOURCE)
                        self.assertEqual(output.read_text(encoding="utf-8"),
                                         release.strip_lua_comments(source.read_text(encoding="utf-8"), compact=True))
                manifest = json.loads((release.REFF_PLUGIN / "manifest.json").read_text(encoding="utf-8"))
                self.assertEqual(manifest["games"], ["MHWILDS", "MHRISE"])

    def test_default_cli_retains_old_output_names_and_version_detection(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                release.main(["--output-dir", str(root / "out")])
                self.assert_inventory(root / "out/ArmorVariantManager_v1.2.3", root / "out/差分管理器_v1.2.3.zip", "wilds")
                self.assertFalse((root / "out/ArmorVariantManager_Rise_v1.2.3").exists())

    def test_rise_does_not_require_any_wilds_native_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                dependencies = [release.UI_DLL, release.PORTRAIT_DLL, release.NATIVE_LICENSES, release.D2D_LICENSE,
                                *(release.PORTRAIT_ASSETS / name for name in release.PORTRAIT_FILES)]
                for path in dependencies:
                    with self.subTest(path=path.name):
                        content = path.read_bytes()
                        path.unlink()
                        release.ensure_inputs("rise")
                        with self.assertRaisesRegex(RuntimeError, path.name):
                            release.ensure_inputs()
                        path.write_bytes(content)
                for path in dependencies:
                    path.unlink()
                release.main(["--game", "rise", "--output-dir", str(root / "out")])
                directory, archive = release.release_paths(root / "out", "1.2.3", "rise")
                self.assert_inventory(directory, archive, "rise")

    def test_missing_shared_inputs_fail_before_creating_any_game_output(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                for path in (release.LICENSE, release.REFF_PLUGIN / "manifest.json",
                             release.REFF_PLUGIN / "ui/dist/index.html", release.REFF_PLUGIN / "ui/dist/REFF-LICENSE.txt"):
                    with self.subTest(path=path):
                        content = path.read_bytes()
                        path.unlink()
                        with self.assertRaisesRegex(RuntimeError, "Missing release inputs"):
                            release.main(["--game", "all", "--output-dir", str(root / "out")])
                        self.assertFalse((root / "out").exists())
                        path.write_bytes(content)

    def test_all_preflight_protects_existing_output_and_unreviewed_staging(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                out = root / "out"
                out.mkdir()
                existing = out / "差分管理器_Rise_v1.2.3.zip"
                existing.write_bytes(b"review first")
                staging = out / ".ArmorVariantManager_v1.2.3.staging"
                staging.mkdir()
                (staging / "keep.txt").write_text("review first")
                with self.assertRaisesRegex(RuntimeError, "already exists"):
                    release.main(["--game", "all", "--output-dir", str(out)])
                self.assertFalse((out / "ArmorVariantManager_v1.2.3").exists())
                self.assertEqual(existing.read_bytes(), b"review first")
                release.main(["--game", "all", "--output-dir", str(out), "--overwrite"])
                self.assertEqual((staging / "keep.txt").read_text(), "review first")
                self.assertEqual(len(list(out.iterdir())), 5)

    def test_failed_staging_preserves_existing_reviewed_outputs(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                out = root / "out"
                directory, archive = release.release_paths(out, "1.2.3")
                directory.mkdir(parents=True)
                (directory / "old.txt").write_text("old release")
                archive.write_bytes(b"old archive")
                with patch.object(release, "verify_release", side_effect=RuntimeError("broken stage")):
                    with self.assertRaisesRegex(RuntimeError, "broken stage"):
                        release.main(["--output-dir", str(out), "--overwrite"])
                self.assertEqual((directory / "old.txt").read_text(), "old release")
                self.assertEqual(archive.read_bytes(), b"old archive")
                self.assertEqual(len(list(out.iterdir())), 2)

    def test_verify_rejects_other_game_manifest_and_wilds_files_in_rise(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                release.main(["--game", "rise", "--output-dir", str(root / "out")])
                directory, _ = release.release_paths(root / "out", "1.2.3", "rise")
                with self.assertRaisesRegex(RuntimeError, "does not target wilds"):
                    release.verify_release(directory)
                release.copy_native_plugins(directory)
                with self.assertRaisesRegex(RuntimeError, "development content"):
                    release.verify_release(directory, "rise")

    @unittest.skipUnless(LUA, "Set LUA to a Lua 5.4 executable for runtime semantics checks")
    def test_package_literals_and_legacy_require_entrypoints_execute_unchanged(self):
        source = r'''-- stripped comment
local values = {"-- kept", 'single \' -- kept', [==[first

-- still text
]=] text
last]==], "joined\z

next", "line\
\
end"}
local result = 7--[=[ inline comment ]=]+2
for _, value in ipairs(values) do io.write(#value, ":", value, "\n") end
io.write(result, "\n")
'''
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                literal = release.AUTORUN_SOURCE / "ArmorVariantManager_Core/Literals.lua"
                literal.write_text(source, encoding="utf-8")
                expected = subprocess.run([LUA, str(literal)], check=True, capture_output=True).stdout
                release.main(["--game", "all", "--output-dir", str(root / "out")])
                for game in release.GAMES:
                    directory, _ = release.release_paths(root / "out", "1.2.3", game)
                    autorun = directory / "reframework/autorun"
                    output = subprocess.run([LUA, str(autorun / literal.relative_to(release.AUTORUN_SOURCE))],
                                            check=True, capture_output=True).stdout
                    self.assertEqual(output, expected)
                    script = ('package.path = "./?.lua;" .. package.path\n'
                              'assert(require("ArmorVariantManager_Core.PresetAutoFinder").game == "Rise")\n'
                              'assert(require("ArmorVariantManager_Core.TransformManager").game == "Wilds")\n')
                    subprocess.run([LUA, "-"], input=script.encode(), cwd=autorun, check=True, capture_output=True)

    def test_ui_and_independent_portrait_are_both_required(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ui, portrait = root / "ArmorVariantManager_UI.dll", root / "ArmorVariantManager_Portrait.dll"
            ui.write_bytes(b"legacy-ui")
            portrait.write_bytes(b"independent-portrait")
            with patch.object(release, "UI_DLL", ui), patch.object(release, "PORTRAIT_DLL", portrait), \
                    patch.object(release, "PORTRAIT_FILES", ()), patch.object(release, "verify_reff_plugin"):
                release.copy_native_plugins(root / "out")
                release.verify_release(root / "out")
                target = root / "out/reframework/plugins"
                self.assertEqual((target / ui.name).read_bytes(), b"legacy-ui")
                self.assertEqual((target / portrait.name).read_bytes(), b"independent-portrait")
                (target / portrait.name).unlink()
                with self.assertRaisesRegex(RuntimeError, "ArmorVariantManager_Portrait.dll"):
                    release.verify_release(root / "out")

    def test_reff_page_and_assets_are_packaged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "monkeysama.avm"
            (source / "ui/assets").mkdir(parents=True)
            (source / "manifest.json").write_text(json.dumps({"ui":{"entry":"ui/index.html"}}))
            (source / "ui/index.html").write_text('<script src="./assets/page.js"></script>')
            (source / "ui/assets/page.js").write_text("export {}")
            (source / "ui/REFF-LICENSE.txt").write_text("MIT License\nCopyright (c) 2026 MK\n")
            (root / "node_modules").mkdir()
            with patch.object(release, "REFF_PLUGIN", source):
                release.copy_reff_plugin(root / "out")
                release.verify_reff_plugin(root / "out")
                target = root / "out/reframework/reff/plugins/monkeysama.avm"
                self.assertFalse((target / "node_modules").exists())
                self.assertEqual((target / "ui/REFF-LICENSE.txt").read_text(), "MIT License\nCopyright (c) 2026 MK\n")
                (target / "ui/assets/page.js").unlink()
                with self.assertRaisesRegex(RuntimeError, "incomplete"):
                    release.verify_reff_plugin(root / "out")

    def test_comments_preserve_runtime_text(self):
        source = 'local name = "-- not a comment" -- comment\nreturn [=[first\n\nlast]=]\n'
        stripped = release.strip_lua_comments(source)
        self.assertIn('"-- not a comment"', stripped)
        self.assertNotIn(' -- comment', stripped)
        self.assertIn('[=[first\n\nlast]=]', stripped)

    def test_package_lua_preserves_document_paragraphs(self):
        # 游戏内说明与模板使用长字符串，空行属于文本内容。
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()
            (source / "example.lua").write_text('-- comment\n\nreturn [=[first\n\nlast]=]\n', encoding="utf-8")
            with patch.object(release, "AUTORUN_SOURCE", source):
                self.assertEqual(release.copy_stripped_lua_files(root / "out"), 1)
            self.assertEqual((root / "out/example.lua").read_text(encoding="utf-8"), 'return [=[first\n\nlast]=]\n')

    def test_long_comment_separates_tokens(self):
        self.assertEqual(release.strip_lua_comments('return 1--[[note]]..2'), 'return 1 ..2')

    def test_zip_contains_only_staged_runtime_files(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            stage = root / "stage"
            (stage / "reframework/autorun").mkdir(parents=True)
            (stage / "reframework/autorun/ArmorVariantManager.lua").write_text("return {}\n")
            release.create_zip(stage, root / "package.zip")
            with release.zipfile.ZipFile(root / "package.zip") as archive:
                self.assertEqual(archive.namelist(), ["reframework/autorun/ArmorVariantManager.lua"])


if __name__ == "__main__":
    unittest.main()
