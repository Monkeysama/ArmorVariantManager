#!/usr/bin/env python3
"""Build comment-free plugin files and optional tag release notes."""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import sys
import subprocess
import tempfile
import zipfile
from html.parser import HTMLParser
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "ArmorVariantManager"
SOURCE_REFRAMEWORK = PROJECT / "reframework"
RELEASE_ROOT = ROOT / "release"
AUTORUN_SOURCE = SOURCE_REFRAMEWORK / "autorun"
PORTRAIT_DLL = SOURCE_REFRAMEWORK / "plugins" / "ArmorVariantManager_Portrait.dll"
PORTRAIT_ASSETS = PROJECT / "natives" / "STM" / "ArmorVariantManager" / "Portrait"
PORTRAIT_FILES = ("portrait_camera.pfb.18", "portrait_resources.user.3", "portrait.rtex.6")
REFF_PLUGIN = SOURCE_REFRAMEWORK / "reff" / "plugins" / "monkeysama.avm"
LICENSE = ROOT / "LICENSE"
CHANGELOG = ROOT / "CHANGELOG.md"
NATIVE_LICENSES = SOURCE_REFRAMEWORK / "plugins" / "source" / "THIRD_PARTY_LICENSES.txt"
GAMES = {"wilds": "MHWILDS", "rise": "MHRISE"}
# 通用包还服务 RE4(独立适配,只用 REF 原生面板与 REFF 页面);旧的单游戏参数不含 RE4。
UNIVERSAL_GAMES = [*GAMES.values(), "RE4"]


def long_bracket_end(text: str, start: int) -> tuple[str, int] | None:
    if start >= len(text) or text[start] != "[":
        return None
    index = start + 1
    while index < len(text) and text[index] == "=":
        index += 1
    if index >= len(text) or text[index] != "[":
        return None
    return "]" + "=" * (index - start - 1) + "]", index + 1


def strip_lua_comments(text: str, *, compact: bool = False) -> str:
    output: list[str] = []
    literal_chunks: set[int] = set()
    index = 0
    length = len(text)
    while index < length:
        character = text[index]
        if character in "\"'":
            quote = character
            start = index
            index += 1
            while index < length:
                if text[index] == "\\":
                    index += 2
                    continue
                if text[index] == quote:
                    index += 1
                    break
                index += 1
            literal_chunks.add(len(output))
            output.append(text[start:index])
            continue

        long_string = long_bracket_end(text, index)
        if long_string:
            closing, content_start = long_string
            closing_index = text.find(closing, content_start)
            end = length if closing_index < 0 else closing_index + len(closing)
            literal_chunks.add(len(output))
            output.append(text[index:end])
            index = end
            continue

        if character == "-" and index + 1 < length and text[index + 1] == "-":
            long_comment = long_bracket_end(text, index + 2)
            if long_comment:
                closing, content_start = long_comment
                closing_index = text.find(closing, content_start)
                end = length if closing_index < 0 else closing_index + len(closing)
                output.append(" " + "".join(ch for ch in text[index:end] if ch in "\r\n"))
                index = end
                continue
            end = text.find("\n", index)
            if end < 0:
                break
            output.append("\n")
            index = end + 1
            continue

        output.append(character)
        index += 1
    result = "".join(output)
    if not compact:
        return result
    # 空行压缩只作用于代码；字符串内的段落和转义换行属于运行内容。
    literal_lines: set[int] = set()
    line_number = 0
    for index, chunk in enumerate(output):
        end_line = line_number + chunk.count("\n")
        if index in literal_chunks:
            literal_lines.update(range(line_number, end_line + 1))
        line_number = end_line
    return "\n".join(
        line for number, line in enumerate(result.split("\n"))
        if line.strip() or number in literal_lines
    ).rstrip("\n") + "\n"


def read_version() -> str:
    source = (AUTORUN_SOURCE / "ArmorVariantManager.lua").read_text(encoding="utf-8")
    match = re.search(r'local\s+version\s*=\s*"([^"]+)"', source)
    if not match:
        raise RuntimeError("Unable to read version from ArmorVariantManager.lua")
    return match.group(1)


def normalize_version(value: str) -> str:
    match = re.fullmatch(r"v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?)", value)
    if not match:
        raise RuntimeError(f"Invalid release version: {value}")
    return match.group(1)


def release_notes(version: str) -> str:
    text = CHANGELOG.read_text(encoding="utf-8")
    headings = list(re.finditer(r"^##[ \t]+(.+?)\r?$", text, re.MULTILINE))
    for index, heading in enumerate(headings):
        name = heading.group(1).split()[0].strip("[]").lstrip("vV")
        if name == version:
            end = headings[index + 1].start() if index + 1 < len(headings) else len(text)
            content = text[heading.end():end].strip()
            if content:
                return content + "\n"
    raise RuntimeError(f"Missing or empty changelog section for version {version}")


def strip_html_comments(text: str) -> str:
    ranges = []
    lines = text.splitlines(keepends=True)

    class Comments(HTMLParser):
        def handle_comment(self, content):
            line, column = self.getpos()
            start = sum(map(len, lines[:line - 1])) + column
            ranges.append((start, start + len(content) + 7))

    Comments().feed(text)
    for start, end in reversed(ranges):
        text = text[:start] + text[end:]
    return text


def assert_no_duplicate_scripts() -> None:
    """防止把同一份脚本的副本一起打包。

    REFramework 的 ScriptRunner 遍历 autorun 时只看扩展名（`path.extension() == ".lua"`），
    因此 `ArmorVariantManager.dev.lua`、`ArmorVariantManager_backup.lua` 这类文件会和正式
    脚本一起被加载两次，导致 on_frame / on_draw_ui 回调重复注册、热键与输入拦截互相打架。
    这里在打包前把这种情况拦下来，避免带着重复脚本发版。
    """
    scripts = sorted(AUTORUN_SOURCE.glob("*.lua"))
    conflicts: list[tuple[str, str]] = []
    for index, left in enumerate(scripts):
        for right in scripts[index + 1:]:
            if left.stem in right.stem or right.stem in left.stem:
                conflicts.append((left.name, right.name))
    if conflicts:
        detail = "\n".join(f"  - {a} <-> {b}" for a, b in conflicts)
        raise RuntimeError(
            "autorun 中存在会被重复加载的同名脚本，请移出后再打包（备份请使用非 .lua 扩展名）:\n" + detail
        )


def ensure_inputs(game: str = "universal") -> None:
    required = [AUTORUN_SOURCE / "ArmorVariantManager.lua", LICENSE,
                REFF_PLUGIN / "manifest.json", REFF_PLUGIN / "ui" / "dist" / "index.html",
                REFF_PLUGIN / "ui" / "dist" / "REFF-LICENSE.txt"]
    if game in ("universal", "wilds"):
        required.extend([PORTRAIT_DLL, NATIVE_LICENSES,
                         *(PORTRAIT_ASSETS / name for name in PORTRAIT_FILES)])
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        raise RuntimeError("Missing release inputs:\n" + "\n".join(missing))
    assert_no_duplicate_scripts()


def reff_files() -> list[Path]:
    return [REFF_PLUGIN / "manifest.json", *(path for path in (REFF_PLUGIN / "ui").rglob("*")
             if path.is_file() and path.suffix.lower() not in (".txt", ".md", ".map"))]


def plugin_notices(game: str) -> str:
    manifest = json.loads((REFF_PLUGIN / "manifest.json").read_text(encoding="utf-8"))
    web_license = (REFF_PLUGIN / manifest["ui"]["entry"]).parent / "REFF-LICENSE.txt"
    paths = [LICENSE, web_license]
    if game != "rise":
        paths.append(NATIVE_LICENSES)
    return "\n\n".join(path.read_text(encoding="utf-8").strip() for path in paths)


def copy_reff_plugin(destination: Path, game: str = "universal", version: str | None = None) -> None:
    """只复制插件清单与已构建页面，不打包 REFF 本体或 Web 开发依赖。"""
    target = destination / "reframework" / "reff" / "plugins" / REFF_PLUGIN.name
    target.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((REFF_PLUGIN / "manifest.json").read_text(encoding="utf-8"))
    manifest["games"] = UNIVERSAL_GAMES if game == "universal" else [GAMES[game]]
    if version is not None:
        manifest["version"] = version
    (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for source in reff_files()[1:]:
        output = target / source.relative_to(REFF_PLUGIN)
        output.parent.mkdir(parents=True, exist_ok=True)
        if source.suffix.lower() == ".html":
            content = strip_html_comments(source.read_text(encoding="utf-8"))
            if source.relative_to(REFF_PLUGIN).as_posix() == manifest["ui"]["entry"]:
                notice = f'<meta name="avm-notices" content="{html.escape(plugin_notices(game), quote=True)}">'
                content = content.replace("</head>", notice + "\n</head>", 1)
            output.write_text(content, encoding="utf-8", newline="\n")
        else:
            shutil.copy2(source, output)
    subprocess.run(["node", str(ROOT / "web/scripts/strip-release-comments.mjs"), str(target)], check=True)


def copy_native_plugins(destination: Path, game: str = "universal") -> None:
    """通用包保留独立预览 DLL；崛起不启动其能力。"""
    if game == "rise":
        return
    target = destination / "reframework" / "plugins"
    target.mkdir(parents=True, exist_ok=True)
    shutil.copy2(PORTRAIT_DLL, target / PORTRAIT_DLL.name)


def verify_reff_plugin(release_directory: Path, game: str = "universal") -> None:
    target = release_directory / "reframework" / "reff" / "plugins" / REFF_PLUGIN.name
    manifest = json.loads((target / "manifest.json").read_text(encoding="utf-8"))
    expected_games = UNIVERSAL_GAMES if game == "universal" else [GAMES[game]]
    if manifest.get("games") != expected_games:
        raise RuntimeError(f"Release verification failed: REFF manifest does not target {game}")
    if not (target / manifest["ui"]["entry"]).is_file():
        raise RuntimeError("Release verification failed: REFF page entry is missing")
    expected = {path.relative_to(REFF_PLUGIN) for path in reff_files()}
    actual = {path.relative_to(target) for path in target.rglob("*") if path.is_file()}
    if actual != expected:
        raise RuntimeError("Release verification failed: REFF plugin files are incomplete")
    notice = f'<meta name="avm-notices" content="{html.escape(plugin_notices(game), quote=True)}">'
    if notice not in (target / manifest["ui"]["entry"]).read_text(encoding="utf-8"):
        raise RuntimeError("Release verification failed: embedded third-party notices are missing")


def copy_stripped_lua_files(destination_autorun: Path, version: str | None = None) -> int:
    # 保留完整 Lua 库存：旧公开入口仍会跨游戏目录 require。
    count = 0
    for source_path in AUTORUN_SOURCE.rglob("*.lua"):
        relative_path = source_path.relative_to(AUTORUN_SOURCE)
        destination_path = destination_autorun / relative_path
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        source = source_path.read_text(encoding="utf-8")
        compact = strip_lua_comments(source, compact=True)
        if relative_path == Path("ArmorVariantManager.lua") and version is not None:
            compact = re.sub(r'(local\s+version\s*=\s*")[^"]+(")',
                             lambda match: match.group(1) + version + match.group(2), compact, count=1)
        destination_path.write_text(compact, encoding="utf-8", newline="\n")
        count += 1
    return count


def verify_release(release_directory: Path, game: str = "universal") -> None:
    verify_reff_plugin(release_directory, game)
    if game in ("universal", "wilds"):
        if not (release_directory / "reframework" / "plugins" / PORTRAIT_DLL.name).is_file():
            raise RuntimeError(f"Release verification failed: required DLL is missing: {PORTRAIT_DLL.name}")
        for name in PORTRAIT_FILES:
            asset = release_directory / "natives" / "STM" / "ArmorVariantManager" / "Portrait" / name
            if not asset.is_file() or asset.read_bytes() != (PORTRAIT_ASSETS / name).read_bytes():
                raise RuntimeError(f"Release verification failed: missing or changed portrait asset: {name}")
    forbidden = [
        release_directory / "reframework" / "data",
        release_directory / "reframework" / "plugins" / "source",
        release_directory / "reframework" / "plugins" / "ArmorVariantManager_UI.dll",
        release_directory / "reframework" / "plugins" / "AVM_InputBridge.dll",
        release_directory / "reframework" / "autorun" / "ArmorVariantManager_UI",
        release_directory / "reframework" / "autorun" / "ArmorVariantManager_Core" / "UI" / "Legacy.lua",
        release_directory / "reframework" / "autorun" / "ArmorVariantManager_Core" / "UI" / "VariantManagerUI.lua",
    ]
    if game == "rise":
        forbidden.extend([release_directory / "reframework" / "plugins", release_directory / "natives"])
    present = [str(path) for path in forbidden if path.exists()]
    if present:
        raise RuntimeError("Release verification failed: development content found:\n" + "\n".join(present))
    expected = {"reframework/autorun/" + path.relative_to(AUTORUN_SOURCE).as_posix()
                for path in AUTORUN_SOURCE.rglob("*.lua")}
    expected.update("reframework/reff/plugins/" + REFF_PLUGIN.name + "/" + path.relative_to(REFF_PLUGIN).as_posix()
                    for path in reff_files())
    if game in ("universal", "wilds"):
        expected.add("reframework/plugins/" + PORTRAIT_DLL.name)
        expected.update("natives/STM/ArmorVariantManager/Portrait/" + name for name in PORTRAIT_FILES)
    actual = {path.relative_to(release_directory).as_posix() for path in release_directory.rglob("*") if path.is_file()}
    if actual != expected:
        raise RuntimeError(f"Release verification failed: plugin inventory differs: missing={sorted(expected - actual)}, extra={sorted(actual - expected)}")


def create_zip(release_directory: Path, archive_path: Path) -> None:
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in release_directory.rglob("*"):
            if path.is_file():
                archive.write(path, path.relative_to(release_directory))


def release_paths(output_root: Path, version: str, game: str = "universal") -> tuple[Path, Path]:
    # 通用包沿用无游戏后缀的名称；显式旧游戏参数保留原输出路径。
    suffix = "_Rise" if game == "rise" else ""
    paths = (output_root / f"ArmorVariantManager{suffix}_v{version}",
             output_root / f"差分管理器{suffix}_v{version}.zip")
    if any(path.resolve().parent != output_root.resolve() for path in paths):
        raise RuntimeError("Release version must not contain path separators")
    return paths


def _build_release(output_root: Path, version: str, game: str) -> None:
    release_directory, archive_path = release_paths(output_root, version, game)
    output_root.mkdir(parents=True, exist_ok=True)
    # 唯一暂存目录不会清掉其他构建留下的待检查内容。
    with tempfile.TemporaryDirectory(prefix=f".ArmorVariantManager_{game}_", dir=output_root) as temporary:
        staging_directory = Path(temporary) / "package"
        staging_autorun = staging_directory / "reframework" / "autorun"
        lua_count = copy_stripped_lua_files(staging_autorun, version)
        copy_native_plugins(staging_directory, game)
        if game in ("universal", "wilds"):
            asset_directory = staging_directory / "natives" / "STM" / "ArmorVariantManager" / "Portrait"
            asset_directory.mkdir(parents=True, exist_ok=True)
            for name in PORTRAIT_FILES:
                shutil.copy2(PORTRAIT_ASSETS / name, asset_directory / name)
        copy_reff_plugin(staging_directory, game, version)
        verify_release(staging_directory, game)
        staging_archive = Path(temporary) / "package.zip"
        create_zip(staging_directory, staging_archive)
        if release_directory.exists():
            shutil.rmtree(release_directory)
        if archive_path.exists():
            archive_path.unlink()
        shutil.move(str(staging_directory), release_directory)
        shutil.move(str(staging_archive), archive_path)
    print(f"Built {game}: {release_directory}")
    print(f"Built {archive_path}")
    print(f"Stripped comments from {lua_count} Lua files")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build an Armor Variant Manager distribution package.")
    versions = parser.add_mutually_exclusive_group()
    versions.add_argument("--version", default=None, help="Package version. Defaults to the Lua script version.")
    versions.add_argument("--tag", help="Git tag, for example v4.4.0. Requires matching CHANGELOG.md notes.")
    parser.add_argument("--release-notes", type=Path, help="Write the matching changelog section outside the package.")
    parser.add_argument("--game", choices=("universal", *GAMES, "all"), default="universal",
                        help="Defaults to one universal package. Explicit wilds/rise/all retain legacy build targets.")
    parser.add_argument("--output-dir", type=Path, default=RELEASE_ROOT, help="Output directory. Defaults to release/.")
    parser.add_argument("--overwrite", action="store_true", help="Replace an existing release with the same version.")
    args = parser.parse_args(argv)

    version = normalize_version(args.tag or args.version or read_version())
    notes = release_notes(version) if args.tag or args.release_notes else None
    games = tuple(GAMES) if args.game == "all" else (args.game,)
    # 双包构建先检查所有目标，避免第二个目标已有输出时先改动第一个。
    for game in games:
        ensure_inputs(game)
        if any(path.exists() for path in release_paths(args.output_dir, version, game)) and not args.overwrite:
            raise RuntimeError("Release output already exists. Use --overwrite after reviewing the target.")
    for game in games:
        _build_release(args.output_dir, version, game)
    if args.release_notes:
        args.release_notes.parent.mkdir(parents=True, exist_ok=True)
        args.release_notes.write_text(notes, encoding="utf-8", newline="\n")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Release build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
