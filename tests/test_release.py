"""python -m unittest discover -s tests -p test_release.py"""
from pathlib import Path
import json
import tempfile
import unittest
from unittest.mock import patch

import build_release as release


class ReleaseTests(unittest.TestCase):
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
