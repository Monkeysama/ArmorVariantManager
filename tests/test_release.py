"""python -m unittest discover -s tests -p test_release.py"""
from pathlib import Path
from contextlib import ExitStack, contextmanager, redirect_stdout
import io
import base64
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
    for name, content in {
        "index.html": '<!doctype html><html><head><!-- HTML comment --></head><body></body></html>',
        "REFF-LICENSE.txt": 'MIT License\nCopyright REFF',
        "assets/page.js": '/*! JS license */\n// JS comment\nexport const text = "/* literal */ -- kept";',
        "assets/page.css": '/*! CSS license */\n/* CSS comment */\na { color: red; }',
        "assets/page.js.map": '{"sourcesContent":["development source"]}',
    }.items():
        (plugin / "ui/dist" / name).write_text(content, encoding="utf-8")
    paths = {
        "AUTORUN_SOURCE": autorun,
        "REFF_PLUGIN": plugin,
        "PORTRAIT_DLL": root / "source/reframework/plugins/ArmorVariantManager_Portrait.dll",
        "PORTRAIT_ASSETS": root / "source/natives/STM/ArmorVariantManager/Portrait",
        "DISSOLVE_ASSETS": root / "source/natives/STM/ArmorVariantManager/Dissolve",
        "LICENSE": root / "source/LICENSE",
        "CHANGELOG": root / "source/CHANGELOG.md",
        "NATIVE_LICENSES": root / "source/reframework/plugins/source/THIRD_PARTY_LICENSES.txt",
    }
    for key in ("PORTRAIT_DLL", "LICENSE", "CHANGELOG", "NATIVE_LICENSES"):
        paths[key].parent.mkdir(parents=True, exist_ok=True)
        paths[key].write_bytes(key.encode())
    paths["CHANGELOG"].write_text('# 更新日志\n\n## 未发布\n\nFuture\n\n## V1.2.3\n\n### 修复\n\n- Exact release.\n\n## V1.2.2\n\nOld\n', encoding="utf-8")
    paths["PORTRAIT_ASSETS"].mkdir(parents=True)
    for name in release.PORTRAIT_FILES:
        (paths["PORTRAIT_ASSETS"] / name).write_bytes(name.encode())
    paths["DISSOLVE_ASSETS"].mkdir(parents=True)
    for name in release.DISSOLVE_FILES:
        (paths["DISSOLVE_ASSETS"] / name).write_bytes(name.encode())
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
        expected = set()
        expected.update("reframework/autorun/" + path.relative_to(release.AUTORUN_SOURCE).as_posix()
                        for path in release.AUTORUN_SOURCE.rglob("*.lua"))
        expected.update("reframework/reff/plugins/monkeysama.avm/" + path.relative_to(release.REFF_PLUGIN).as_posix()
                        for path in release.reff_files())
        if game in ("universal", "wilds"):
            expected.add("reframework/plugins/" + release.PORTRAIT_DLL.name)
            expected.update("natives/STM/ArmorVariantManager/Portrait/" + name for name in release.PORTRAIT_FILES)
        if game == "universal":
            expected.update("natives/STM/ArmorVariantManager/Dissolve/" + name for name in release.DISSOLVE_FILES)
        actual = {path.relative_to(directory).as_posix() for path in directory.rglob("*") if path.is_file()}
        self.assertEqual(actual, expected)
        page = (directory / 'reframework/reff/plugins/monkeysama.avm/ui/dist/index.html').read_text(encoding='utf-8')
        self.assertIn('name="avm-notices"', page)
        self.assertIn('Copyright REFF', page)
        self.assertIn('LICENSE', page)
        self.assertNotIn('HTML comment', page)
        for path in directory.rglob('*'):
            if path.suffix in ('.js', '.css'):
                text = path.read_text(encoding='utf-8')
                self.assertNotIn('license */', text)
                self.assertNotIn(' comment', text)
        with release.zipfile.ZipFile(archive_path) as archive:
            self.assertEqual(set(archive.namelist()), expected)
            for name in expected:
                self.assertEqual(archive.read(name), (directory / name).read_bytes())
        manifest_path = directory / "reframework/reff/plugins/monkeysama.avm/manifest.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(manifest["games"], release.UNIVERSAL_GAMES if game == "universal" else [release.GAMES[game]])
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

    def test_default_and_explicit_universal_build_one_shared_package(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                for name, args in (("default", []), ("explicit", ["--game", "universal"])):
                    out = root / name
                    release.main([*args, "--output-dir", str(out)])
                    self.assert_inventory(out / "ArmorVariantManager_v1.2.3", out / "差分管理器_v1.2.3.zip", "universal")
                    self.assertEqual(len(list(out.iterdir())), 2)

    def test_rise_does_not_require_any_wilds_native_input(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                dependencies = [release.PORTRAIT_DLL, release.NATIVE_LICENSES,
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
                with self.assertRaisesRegex(RuntimeError, "does not target universal"):
                    release.verify_release(directory)
                release.copy_native_plugins(directory)
                with self.assertRaisesRegex(RuntimeError, "development content"):
                    release.verify_release(directory, "rise")

    def test_verify_rejects_documents_licenses_and_other_non_plugin_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with release_inputs(root):
                release.main(["--output-dir", str(root / "out")])
                directory, _ = release.release_paths(root / "out", "1.2.3")
                for name in ('README.md', 'CHANGELOG.md', 'LICENSE', 'licenses/notice.txt', 'reframework/notes.txt'):
                    document = directory / name
                    document.parent.mkdir(parents=True, exist_ok=True)
                    document.write_bytes(b'not a plugin')
                    with self.assertRaisesRegex(RuntimeError, 'inventory'):
                        release.verify_release(directory)
                    document.unlink()

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

    def test_only_independent_portrait_is_required_and_retired_ui_is_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with release_inputs(root):
                release.main(["--output-dir", str(root / "out")])
                output, _ = release.release_paths(root / "out", "1.2.3")
                target = output / "reframework/plugins"
                self.assertFalse((target / "ArmorVariantManager_UI.dll").exists())
                self.assertEqual((target / release.PORTRAIT_DLL.name).read_bytes(), b"PORTRAIT_DLL")
                for name in ("ArmorVariantManager_UI.dll", "AVM_InputBridge.dll"):
                    retired = target / name
                    retired.write_bytes(b"retired")
                    with self.assertRaisesRegex(RuntimeError, "development content"):
                        release.verify_release(output)
                    retired.unlink()
                (target / release.PORTRAIT_DLL.name).unlink()
                with self.assertRaisesRegex(RuntimeError, "ArmorVariantManager_Portrait.dll"):
                    release.verify_release(output)

    def test_reff_page_and_assets_are_packaged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "monkeysama.avm"
            (source / "ui/assets").mkdir(parents=True)
            (source / "manifest.json").write_text(json.dumps({"ui":{"entry":"ui/index.html"}}))
            (source / "ui/index.html").write_text('<html><head></head><body><script src="./assets/page.js"></script></body></html>')
            (source / "ui/assets/page.js").write_text("export {}")
            (source / "ui/REFF-LICENSE.txt").write_text("MIT License\nCopyright (c) 2026 MK\n")
            (root / "node_modules").mkdir()
            with patch.object(release, "REFF_PLUGIN", source):
                release.copy_reff_plugin(root / "out")
                release.verify_reff_plugin(root / "out")
                target = root / "out/reframework/reff/plugins/monkeysama.avm"
                self.assertFalse((target / "node_modules").exists())
                self.assertFalse((target / "ui/REFF-LICENSE.txt").exists())
                self.assertIn('Copyright (c) 2026 MK', (target / 'ui/index.html').read_text())
                (target / "ui/assets/page.js").unlink()
                with self.assertRaisesRegex(RuntimeError, "incomplete"):
                    release.verify_reff_plugin(root / "out")

    def test_tag_versions_and_matching_notes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with release_inputs(root):
                out = root / 'out'
                notes = root / 'notes.md'
                release.main(['--tag', 'v1.2.3', '--release-notes', str(notes), '--output-dir', str(out)])
                self.assertEqual(notes.read_text(encoding='utf-8'), '### 修复\n\n- Exact release.\n')
                package, _ = release.release_paths(out, '1.2.3')
                manifest = json.loads((package / 'reframework/reff/plugins/monkeysama.avm/manifest.json').read_text())
                self.assertEqual(manifest['version'], '1.2.3')
                release.CHANGELOG.write_text('## V9.8.7\n\n- Next release.\n', encoding='utf-8')
                release.main(['--tag', 'v9.8.7', '--output-dir', str(root / 'next')])
                package, _ = release.release_paths(root / 'next', '9.8.7')
                entry = (package / 'reframework/autorun/ArmorVariantManager.lua').read_text()
                self.assertIn('local version = "9.8.7"', entry)
                manifest = json.loads((package / 'reframework/reff/plugins/monkeysama.avm/manifest.json').read_text())
                self.assertEqual(manifest['version'], '9.8.7')
                self.assertIn('local version = "1.2.3"', (release.AUTORUN_SOURCE / 'ArmorVariantManager.lua').read_text())

    def test_missing_or_empty_tag_notes_and_invalid_versions_do_not_build(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with release_inputs(root):
                for tag in ('v1.2.4', '../escape', 'v1.2.3/other', 'main'):
                    with self.subTest(tag=tag), self.assertRaisesRegex(RuntimeError, 'version|changelog'):
                        release.main(['--tag', tag, '--output-dir', str(root / 'out')])
                    self.assertFalse((root / 'out').exists())
                release.CHANGELOG.write_text('## V1.2.3\n\n## V1.2.2\n\nOld\n')
                with self.assertRaisesRegex(RuntimeError, 'changelog'):
                    release.main(['--tag', 'v1.2.3', '--output-dir', str(root / 'out')])

    def test_comment_literals_and_runtime_documents_remain_data(self):
        html = '<head><!-- removed --><script>const text = "<!-- literal -->";</script></head>'
        stripped = release.strip_html_comments(html)
        self.assertNotIn('<!-- removed -->', stripped)
        self.assertIn('"<!-- literal -->"', stripped)

    def test_web_stripping_preserves_literals_and_pure_annotated_calls(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with release_inputs(root):
                source = release.REFF_PLUGIN / 'ui/dist/assets/page.js'
                source.write_text('''/*! remove license comment */
export const text = "/* literal */ // literal";
export const template = `first\n// template`;
export const regex = /\\/\\*literal\\*\\//.source;
export const calls = [];
function call() { calls.push('kept'); }
/* @__PURE__ */ call(); // remove ordinary comment
''')
                css = release.REFF_PLUGIN / 'ui/dist/assets/page.css'
                css.write_text('/* remove CSS comment */ a::after { content: "/* literal */"; }')
                release.main(['--output-dir', str(root / 'out')])
                package, _ = release.release_paths(root / 'out', '1.2.3')
                web = package / 'reframework/reff/plugins/monkeysama.avm/ui/dist/assets'
                code = (web / 'page.js').read_text()
                self.assertNotIn('@__PURE__', code)
                self.assertNotIn('remove ', code)
                encoded = base64.b64encode(code.encode()).decode()
                result = subprocess.run(['node', '--input-type=module', '-e',
                    f'const m=await import("data:text/javascript;base64,{encoded}"); console.log(JSON.stringify(m));'],
                    check=True, capture_output=True, text=True)
                values = json.loads(result.stdout)
                self.assertEqual(values['text'], '/* literal */ // literal')
                self.assertEqual(values['template'], 'first\n// template')
                self.assertEqual(values['regex'], r'\/\*literal\*\/')
                self.assertEqual(values['calls'], ['kept'])
                self.assertIn('/* literal */', (web / 'page.css').read_text())

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
