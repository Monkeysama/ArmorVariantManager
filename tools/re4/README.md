# 条件判断面板(已从插件里移除,存档在 `attic/`)

一个只读诊断面板:把 `chainsaw.PlayerBaseContext` 上的候选条件**全部实时读一遍**,
只显示条件名,为真的显示成绿色。用途是**在实装成正式条件之前先确认方法的真实语义** ——
在游戏里摆出想要的时机,看哪一条变绿。

**已经完成使命,所以从插件里删掉了**:该测的都测完了,结论已经落进 `Games/RE4/AGENTS.md`
(「条件 backlog」的三档分类 + 「实测出来的语义坑」那张表),留着只会一直占着面板的位置、
每帧读几十个方法。

## 存档在哪

| 文件 | 是什么 |
|---|---|
| `attic/Probe.lua.txt` | 候选清单(46 个布尔 + 9 个取值)+ 探针实现 |
| `attic/condition_probe_panel.lua.txt` | 面板绘制部分,原本在 RE4 主脚本(现 `Games/RE4/Main.lua`)里 |
| `attic/GunProbe.lua.txt` | 枪械那一批的**闩锁式**探针(2026-08-25),独立脚本 |

`.txt` 后缀是**故意的** —— 放在 `reframework/autorun` 之外、又不叫 `.lua`,
双重保证 REFramework 不会去加载它。

## 想恢复的话

1. `attic/Probe.lua.txt` → `ArmorVariantManager/reframework/autorun/ArmorVariantManager_Core/Games/RE4/Conditions/Probe.lua`(require 名同步加 `Games.RE4.`)
2. `attic/condition_probe_panel.lua.txt` 的内容贴回 `Games/RE4/Main.lua` 的 `draw_panel` 之前
3. 补回这四件事(每个文件开头也写着):
   - `require` Probe 和 Condition_HP
   - `draw_panel` 里那个 `ui_tree(T("probe_section"))` 块
   - Localization 里 `probe_*` 那一组文案(**zh 和 en 都要**)
   - `Condition_HP.set_absolute`(改血测试用的绝对值写入)
   - 条件 def 上的 `method = ...` 字段(`PlayerBools.lua` / `Condition_Vital.lua`),
     面板靠它给已实装的候选打 `*` 标记

## 那个改血输入框没跟着一起消失

面板底部原本有个"写绝对值改血"的输入框,用来扫血量等级的阈值。它已经**独立成
`tools/re4/HPDebug.lua`**(用时拷到游戏的 `reframework/autorun/`)(和差分管理器零依赖),而且比原来强:
多了 ±1 / ±10 一格一格走、满血 / 只剩 1 点 / 归零,还会列出引擎声明的全部档位。
所以恢复这个面板时**不需要**再把改血功能搬回来。

## 里面值得复用的几个做法

不只是"一份清单",这几个手法换个场景还用得上:

- **方法存在性先用反射确认,确认不到就记进 `missing` 缓存,之后再也不调。**
  直接 `pcall(obj:call(...))` 一个不存在的方法会每帧往日志里灌错误 ——
  一个几十条的探针面板足够把日志刷爆。
- **枚举名从方法的返回类型上反射,不硬编码类型名。**
  硬编码猜过一次 `SituationType` 的类型全名,查出来是空表。
  同一套做法后来正式用进了 `Condition_Vital`(血量等级的档位列表)。
- **64 位标志枚举按位拆开时不要用 `&` / `>>`**(Lua 5.3+ 才有),
  用 `math.floor(v / 2^i) % 2` —— 2^53 以内精确,够覆盖实际会出现的状态组合。
- **颜色只用各通道对称的值**(`0xFF00FF00` 绿、灰阶),这样不必赌 REFramework 的
  `imgui.text_colored` 是 ARGB 还是 ABGR;"读不到"另外附一句文字,不靠颜色区分。
- **先全部取值再画**:组标题上要显示"这组命中几条",而标题必须先画出来;
  顺便保证每个条目每帧只读一次。

## `GunProbe.lua.txt`:瞬时标志要用闩锁去测

2026-08-25 补测枪械那一批(`IsShootDryFire` / `IsPumpAction` / `IsExReload` /
`IsGunWallHit` …)时,上面这个面板的做法**不够用** —— 它只显示"当前为真",而这批标志
最长只连亮 29~50 帧,做完动作抬头看已经灭了,而且做动作时你在看准星、不在看面板。

`attic/GunProbe.lua.txt` 换了个思路:每帧采样一次,每条记三个数 ——
**亮过总帧数 / 单次最长连亮 / 上次为真是几帧前**,再加一个「清空统计」按钮。
于是流程变成"清零 → 做一个动作 → 回头看数",不需要盯着面板做动作。
另外它把**语义已知**的几条(`IsPullTrigger` / `IsShooting` / `IsReloading`)排在下面当参照,
用来判断候选和它们的时间轴对不对得上。

**「最长连亮」这个数还顺便决定了实装后的用法**:29 帧 ≈ 0.5s,说明这条必须配
「条件结束后保持 N 秒」才有意义;反过来 `IsShootEnable` 在 6988 帧里亮了 4012 帧,
一眼就能判掉——没有区分度,不值得占下拉框。

它是独立脚本(和差分管理器零依赖),恢复方式就是把 `.txt` 去掉后缀丢进
`reframework/autorun/`,面板在 REFramework 菜单里叫「枪械条件探针 (RE4)」。
想测别的方法就改文件开头那三张表(`CANDIDATES` / `REFERENCE` / `NUMBERS`)。
