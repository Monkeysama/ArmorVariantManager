#!/usr/bin/env python3
"""Build a minimal Armor Variant Manager release package."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
import tempfile
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent
PROJECT = ROOT / "ArmorVariantManager"
SOURCE_REFRAMEWORK = PROJECT / "reframework"
RELEASE_ROOT = ROOT / "release"
AUTORUN_SOURCE = SOURCE_REFRAMEWORK / "autorun"
UI_DLL = SOURCE_REFRAMEWORK / "plugins" / "ArmorVariantManager_UI.dll"
PORTRAIT_DLL = SOURCE_REFRAMEWORK / "plugins" / "ArmorVariantManager_Portrait.dll"
PORTRAIT_ASSETS = PROJECT / "natives" / "STM" / "ArmorVariantManager" / "Portrait"
PORTRAIT_FILES = ("portrait_camera.pfb.18", "portrait_resources.user.3", "portrait.rtex.6")
REFF_PLUGIN = SOURCE_REFRAMEWORK / "reff" / "plugins" / "monkeysama.avm"
LICENSE = ROOT / "LICENSE"
NATIVE_LICENSES = SOURCE_REFRAMEWORK / "plugins" / "source" / "THIRD_PARTY_LICENSES.txt"
D2D_LICENSE = SOURCE_REFRAMEWORK / "plugins" / "source" / "ArmorVariantManagerUI" / "upstream" / "reframework-d2d" / "LICENSE"
GAMES = {"wilds": "MHWILDS", "rise": "MHRISE"}


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


def ensure_inputs(game: str = "wilds") -> None:
    required = [AUTORUN_SOURCE / "ArmorVariantManager.lua", LICENSE,
                REFF_PLUGIN / "manifest.json", REFF_PLUGIN / "ui" / "dist" / "index.html",
                REFF_PLUGIN / "ui" / "dist" / "REFF-LICENSE.txt"]
    if game == "wilds":
        required.extend([UI_DLL, PORTRAIT_DLL, NATIVE_LICENSES, D2D_LICENSE,
                         *(PORTRAIT_ASSETS / name for name in PORTRAIT_FILES)])
    missing = [str(path) for path in required if not path.exists()]
    if missing:
        raise RuntimeError("Missing release inputs:\n" + "\n".join(missing))
    assert_no_duplicate_scripts()


def copy_reff_plugin(destination: Path, game: str = "wilds") -> None:
    """只复制插件清单与已构建页面，不打包 REFF 本体或 Web 开发依赖。"""
    target = destination / "reframework" / "reff" / "plugins" / REFF_PLUGIN.name
    target.mkdir(parents=True, exist_ok=True)
    manifest = json.loads((REFF_PLUGIN / "manifest.json").read_text(encoding="utf-8"))
    manifest["games"] = [GAMES[game]]
    (target / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    shutil.copytree(REFF_PLUGIN / "ui", target / "ui")


def copy_native_plugins(destination: Path, game: str = "wilds") -> None:
    """旧弹窗与独立预览分别发布，不能遗漏任一运行依赖。"""
    if game != "wilds":
        return
    target = destination / "reframework" / "plugins"
    target.mkdir(parents=True, exist_ok=True)
    for source in (UI_DLL, PORTRAIT_DLL):
        shutil.copy2(source, target / source.name)


def copy_licenses(destination: Path, game: str = "wilds") -> None:
    shutil.copy2(LICENSE, destination / "LICENSE")
    if game == "wilds":
        target = destination / "licenses"
        target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(NATIVE_LICENSES, target / NATIVE_LICENSES.name)
        shutil.copy2(D2D_LICENSE, target / "reframework-d2d-LICENSE.txt")


def verify_reff_plugin(release_directory: Path, game: str = "wilds") -> None:
    target = release_directory / "reframework" / "reff" / "plugins" / REFF_PLUGIN.name
    manifest = json.loads((target / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("games") != [GAMES[game]]:
        raise RuntimeError(f"Release verification failed: REFF manifest does not target {game}")
    if not (target / manifest["ui"]["entry"]).is_file():
        raise RuntimeError("Release verification failed: REFF page entry is missing")
    expected = {path.relative_to(REFF_PLUGIN) for path in REFF_PLUGIN.rglob("*") if path.is_file()}
    actual = {path.relative_to(target) for path in target.rglob("*") if path.is_file()}
    if actual != expected:
        raise RuntimeError("Release verification failed: REFF plugin files are incomplete")


def copy_stripped_lua_files(destination_autorun: Path) -> int:
    # 两包保留相同 Lua 库存：旧公开入口仍会跨游戏目录 require。
    count = 0
    for source_path in AUTORUN_SOURCE.rglob("*.lua"):
        relative_path = source_path.relative_to(AUTORUN_SOURCE)
        destination_path = destination_autorun / relative_path
        destination_path.parent.mkdir(parents=True, exist_ok=True)
        source = source_path.read_text(encoding="utf-8")
        compact = strip_lua_comments(source, compact=True)
        destination_path.write_text(compact, encoding="utf-8", newline="\n")
        count += 1
    return count


def verify_release(release_directory: Path, game: str = "wilds") -> None:
    verify_reff_plugin(release_directory, game)
    if game == "wilds":
        for source in (UI_DLL, PORTRAIT_DLL):
            if not (release_directory / "reframework" / "plugins" / source.name).is_file():
                raise RuntimeError(f"Release verification failed: required DLL is missing: {source.name}")
        for name in PORTRAIT_FILES:
            asset = release_directory / "natives" / "STM" / "ArmorVariantManager" / "Portrait" / name
            if not asset.is_file() or asset.read_bytes() != (PORTRAIT_ASSETS / name).read_bytes():
                raise RuntimeError(f"Release verification failed: missing or changed portrait asset: {name}")
    forbidden = [
        release_directory / "reframework" / "data",
        release_directory / "reframework" / "plugins" / "source",
    ]
    if game == "rise":
        forbidden.extend([release_directory / "reframework" / "plugins", release_directory / "natives"])
    present = [str(path) for path in forbidden if path.exists()]
    if present:
        raise RuntimeError("Release verification failed: development content found:\n" + "\n".join(present))


def create_zip(release_directory: Path, archive_path: Path) -> None:
    with zipfile.ZipFile(archive_path, "w", compression=zipfile.ZIP_DEFLATED) as archive:
        for path in release_directory.rglob("*"):
            if path.is_file():
                archive.write(path, path.relative_to(release_directory))


def release_paths(output_root: Path, version: str, game: str = "wilds") -> tuple[Path, Path]:
    # Wilds 沿用旧命名，保留现有发布目录消费者；Rise 使用独立名称。
    suffix = "" if game == "wilds" else "_Rise"
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
        lua_count = copy_stripped_lua_files(staging_autorun)
        copy_native_plugins(staging_directory, game)
        if game == "wilds":
            asset_directory = staging_directory / "natives" / "STM" / "ArmorVariantManager" / "Portrait"
            asset_directory.mkdir(parents=True, exist_ok=True)
            for name in PORTRAIT_FILES:
                shutil.copy2(PORTRAIT_ASSETS / name, asset_directory / name)
        copy_reff_plugin(staging_directory, game)
        copy_licenses(staging_directory, game)
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
    parser.add_argument("--version", default=None, help="Release version. Defaults to the Lua script version.")
    parser.add_argument("--game", choices=(*GAMES, "all"), default="wilds", help="Target game; defaults to wilds (legacy output names).")
    parser.add_argument("--output-dir", type=Path, default=RELEASE_ROOT, help="Output directory. Defaults to release/.")
    parser.add_argument("--overwrite", action="store_true", help="Replace an existing release with the same version.")
    args = parser.parse_args(argv)

    version = args.version or read_version()
    games = tuple(GAMES) if args.game == "all" else (args.game,)
    # 双包构建先检查所有目标，避免第二个目标已有输出时先改动第一个。
    for game in games:
        ensure_inputs(game)
        if any(path.exists() for path in release_paths(args.output_dir, version, game)) and not args.overwrite:
            raise RuntimeError("Release output already exists. Use --overwrite after reviewing the target.")
    for game in games:
        _build_release(args.output_dir, version, game)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except Exception as error:
        print(f"Release build failed: {error}", file=sys.stderr)
        raise SystemExit(1)
