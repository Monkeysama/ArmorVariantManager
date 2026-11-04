# 开发与发布

本项目是同时支持《怪物猎人：荒野》《怪物猎人：崛起》和《生化危机 4 重制版》的 REFramework MOD。REF 原生菜单独立可用；REFF 是可选网页界面，荒野全身预览使用其原生预览接口。

安装与操作见 [README.md](README.md)，版本变化见 [CHANGELOG.md](CHANGELOG.md)，协作和兼容规则见 [AGENTS.md](AGENTS.md)。

## 代码分支

main：主分支
dev：开发版本
MHWS-Beta：旧版本荒野开发分支，仅作保留
MHR：旧版本崛起开发分支，仅作保留

## 项目结构

```text
ArmorVariantManager/
  reframework/
    autorun/
      ArmorVariantManager.lua          启动、游戏识别与生命周期装配
      ArmorVariantManager_Core/
        App.lua                        共享应用事务
        Config/                        存储、会话、归一化和全局设置
        Presets/                       分组、选择、合成、捕获与编辑
        Conditions/、Rules/、Runtime/  条件、规则与角色状态
        Games/Wilds/、Games/Rise/      各游戏 SDK、装备、材质和能力适配
        Games/RE4/                     RE4 独立适配：Main.start、规则、条件与 REF 面板（见目录内 AGENTS.md）
        UI/Workspace.lua              当前编辑配置与选择状态
        UI/ImGui/、UI/Reff/            REF 绘制、REFF 序列化与 RPC 适配
        Documentation.lua             游戏内中英文帮助与历史记录
    plugins/
      ArmorVariantManager_Portrait.dll  荒野预览与姿态插件
      source/
        ArmorVariantManagerPortrait/  C++ 实现与原生离线测试
        Shared/                       Lua/sol2 构建输入、SDK 头和许可
    reff/plugins/monkeysama.avm/       REFF 清单与已构建页面
  natives/STM/ArmorVariantManager/Portrait/  相机、资源与 RT 资产
web/                                  Vue 页面、构建脚本与网页测试夹具
tests/                                Lua 回归、共享测试工具与发布测试
tools/re4/                            RE4 调试脚本与探针存档，不进发布包
build_release.py                      发布目录、ZIP 与库存检查
.github/workflows/release.yml          tag 发布与同版本日志提取
```

共享业务不直接依赖游戏 SDK；游戏适配层处理托管对象和专属能力。`Game.detect` 标记为 `standalone` 的游戏（目前是 RE4）由入口直接调用 `Games/<游戏>/Main.lua` 的 `start({game, version, author})`，不装配共享 `App`、REFF 与预览；它的配置模型与 MH 的 groups 不同，迁入共享界面前先证明旧配置行为不变。界面通过 `App` 操作配置，角色活动状态不能混入界面选择状态。旧 JSON 与公开业务 `require` 转接仍有兼容用途，不按文件名批量删除。

## 开发环境

- **Lua 5.4**：运行离线回归与语法检查。
- **Python 3.10+**：运行测试入口和发布脚本，无需额外 Python 包。
- **Node.js 22.12+、npm**：网页开发及发布打包需要；依赖由 `web/package-lock.json` 锁定。
- **Windows x64、MSVC C++20、Windows SDK、CMake 3.25+**：仅修改预览原生代码时需要，GPU 测试使用 D3D12 WARP。
- **REFF 源码**：网页构建需要其 `web/sdk` 与共享 UI；运行可选预览时需要原生预览 ABI v1、网页布局协议 2。REFF 的 DLL 与宿主 EXE 必须成套更新。

原生依赖固定为 Lua 5.4.3、sol2 3.3.0，由 `Shared/LuaDependencies.cmake` 和 CPM 获取。已有下载缓存可继续复用。

## 日常检查

在仓库根目录执行。若 `lua` 不在 PATH，通过 `--lua` 或环境变量 `LUA` 指定可执行文件。

```powershell
python tests/run.py --lua lua

# 只运行本次改动影响的用例；仍编译全部运行 Lua
python tests/run.py --lua lua tests/entrypoint.lua tests/preset_editor.lua

# 发布输入、精确库存、注释处理和失败恢复
$env:LUA = "lua"
python -m unittest discover -s tests -p test_release.py
```

`tests/entrypoint.lua` 加载真实入口，覆盖两款游戏、缺少 REFF、脚本重置、保存失败及主要应用操作。其他用例直接断言配置、条件、多人角色状态与预览生命周期；不携带旧版本源码作对照。语法检查在一个 Lua 进程中完成，每个回归仍使用独立进程。离线测试不替代真实 SDK、多人时序和游戏画面；有相同候选的有效结果时复用，不反复全量运行。

### 网页

以下用相邻的 `../RE-FF` 源码目录作示例，也可设置环境变量 `REFF_ROOT`。

```powershell
npm --prefix web ci
npm --prefix web test
node web/scripts/reff.mjs typecheck --reff-root ../RE-FF
node web/scripts/reff.mjs dev --reff-root ../RE-FF
node web/scripts/reff.mjs build --reff-root ../RE-FF
```

开发服务为 `http://127.0.0.1:5178`；统一夹具在 `/tests/fixture.html`，`?preview&controls` 可检查预览状态、设置失败、语言和字号等场景。夹具不提供游戏人物或 GPU 验收。

生产构建直接更新 `reframework/reff/plugins/monkeysama.avm/ui/dist/` 并复制 REFF 许可。修改布局或交互后检查实际页面和关键操作；消费新 SDK 时确认可选能力失败不会阻断基础界面。

### 原生预览

以下以 Visual Studio 多配置生成器为例，在 x64 开发环境执行：

```powershell
cmake -S ArmorVariantManager/reframework/plugins/source/ArmorVariantManagerPortrait -B release/build/portrait -DBUILD_TESTING=ON
cmake --build release/build/portrait --config Release
ctest --test-dir release/build/portrait -C Release --output-on-failure
Copy-Item release/build/portrait/Release/ArmorVariantManager_Portrait.dll ArmorVariantManager/reframework/plugins/
```

原生测试检查桥接加载顺序、双游戏隔离、姿态、公开独立预览及 REFF 借用命令的像素/裁剪/资源租约。只有通过相关检查的 DLL 才更新到运行源码目录；同时维护 `source/THIRD_PARTY_LICENSES.txt`。

## 生成发布包

`dev` 与 `main` 都保存完整源码，不再将去注释产物反向覆盖到 `main`。发布脚本不会替你构建 DLL 或网页；原生或网页变化时，先提交对应的已构建产物。

发布前，将 `CHANGELOG.md` 的“未发布”内容归入实际版本，例如 `## V4.4.0`。推送 `v4.4.0` tag 后，原有 Release 工作流会检出该 tag，生成通用包，并只截取对应版本标题下的正文作为发布日志；缺少或空的版本段会中止。Release 标题保持 `ArmorVariantManager v4.4.0`，附件保持 `ArmorVariantManager-v4.4.0.zip`。手动运行工作流时同样填写已存在的 tag。

本地检查同一打包路径，不会创建 tag 或发布 Release：

```powershell
npm --prefix web ci
python build_release.py --tag v4.4.0 --output-dir release/candidate --release-notes release/release-notes.md
```

上例生成：

```text
release/candidate/ArmorVariantManager_v4.4.0/
release/candidate/差分管理器_v4.4.0.zip
release/release-notes.md
```

tag 的版本会写入产物中的 Lua 入口和 REFF 清单，源码不改。省略 `--tag` 时沿用 Lua 入口版本，也可用 `--version` 指定本地候选版本；`--release-notes` 提取该版本日志到包外。

通用包同时供 RE4 使用；REFF 清单只声明 `MHWILDS` 和 `MHRISE`，RE4 只有 REF 原生面板，预览 DLL 在非荒野游戏中加载后不工作。`tools/re4/` 的调试脚本不进包。包内只有 Lua、独立预览 DLL、预览资产和 REFF 插件页面；不包含独立许可证、说明、更新日志、源码、测试、用户数据或 REFramework/REFF 本体。必要许可合并到页面的 `avm-notices` 元数据，源码许可文件继续保留。Lua、JavaScript、CSS 和 HTML 注释在打包副本中移除，字符串与游戏内帮助内容不变。

同名产物已存在时默认拒绝覆盖，确认目标后才能用 `--overwrite`。旧自动化显式使用的 `--game wilds`、`--game rise`、`--game all` 仍保留原输出含义，日常构建不需要这些参数。

交付前检查实际 ZIP 库存和内容，在同一解压树运行入口回归，而不只检查开发源码：

```powershell
lua tests/entrypoint.lua path/to/unpacked/reframework/autorun
```

游戏内帮助由 `Documentation.lua` 独立维护，不从 README 自动生成。

## 部署与回退

部署、推送和远端发布需要当前任务授权。先确认目标游戏和安装目录，退出游戏及其 REFF 宿主，再备份 AVM 程序与用户数据；替换已加载的 DLL 前必须退出游戏。

只同步发布清单中的 AVM 自有程序项，移出已退休的旧 UI、旧输入桥及 `.bak.lua`。不要清理整个 `autorun`、共享 D2D 或 REFF 核心；用户 JSON 不随程序覆盖。保留安装清单与可独立执行的恢复办法，恢复时同样先退出游戏。

实机检查针对改动记录游戏、版本、场景及结果，例如预设切换/回滚、换装与切场、REFF 开关和预览缩放。失败时先恢复可用程序，再根据日志修复，不在用户会话中自动按键或重置脚本。
