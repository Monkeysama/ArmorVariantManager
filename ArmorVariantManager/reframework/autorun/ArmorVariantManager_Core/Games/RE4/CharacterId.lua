local Utils = require("ArmorVariantManager_Core.Games.RE4.Utils")

local CharacterId = {}

-- ============================================================
-- 按 head mesh 的名字定位角色
--
-- 为什么需要这个:现有的两个身份来源都不够用 ——
--   * `CharacterKindID` 是"角色槽位"不是"人":`ch0_a0z0`(剧情里昂)和 `ch6_i0z0`
--     (佣兵里昂)是同一个人,`ch2_a200`(剧情 NPC Ada)和 `ch3_a8z0`(DLC 主控 Ada)
--     也是同一个人。而模型鉴赏的雕像**根本没有 kind**。
--   * 材质名指纹在 mod 面前会失明:实测这套 mod 下里昂和 Ada 的 body 材质名
--     Jaccard = **1.000**(同一个模型换给了多个角色),完全分不开。
--
-- mesh 路径则不受 mod 影响 —— mod 替换的是路径上的文件内容,`get_ResourcePath()`
-- 返回的仍是原版逻辑路径。**材质名衡量的是 mod,资源路径衡量的是游戏。**
--
-- 用 head 而不是 body:body 随皮肤变(里昂 `cha000_00` → 皮肤02 `cha002_00`),
-- 而那些只换衣服的编号组**没有自己的 head**,会复用本体的 head
-- (实测雕像 Figure00_010 是 body=cha002_00 但 head=cha000_10)。
-- 所以 head 是身份、body 是皮肤。附带解释了另一个反直觉现象:同一个 `cha000_10`
-- 在傀儡上 6 个材质、在雕像上 10 个 —— **mesh 认人,mdf2 认皮肤**。
--
-- 注意**不是**一个角色一个 head 编号(一开始猜错过):Ada 有 4 组、里昂有 3 组。
-- 真正成立的性质是"**一个组不跨角色**",所以这是一张干净的多对一查找表。
-- 26 个 head 名 / 17 个组 / 7 个角色,零冲突(核对过)。
--
-- 路径前缀(`_Chainsaw` 本体 / `_Mercenaries` DLC)刻意不参与判定 —— 组名本身已经
-- 唯一,前缀是冗余的。
-- ============================================================
local HEAD_GROUP_TO_CHARACTER = {
    -- Ada:cha200 是本体里的非可控 NPC,cha800/801/803 是 DLC 主控
    cha200 = "Ada",   cha800 = "Ada",   cha801 = "Ada",  cha803 = "Ada",
    -- Ashley
    cha100 = "Ashley", cha102 = "Ashley",
    -- Leon(cha005 是实测补上的 —— 最初那份清单里没有,
    --       在模型鉴赏里显示成未命中才发现)
    cha000 = "Leon",  cha005 = "Leon",  cha006 = "Leon",  cha500 = "Leon",
    -- Krauser
    chb700 = "Krauser", chi200 = "Krauser",
    -- Luis
    cha300 = "Luis",  chi100 = "Luis",
    -- Wesker
    cha600 = "Wesker", chj000 = "Wesker",
    -- Hunk
    chi300 = "Hunk",
}
CharacterId.HEAD_GROUP_TO_CHARACTER = HEAD_GROUP_TO_CHARACTER

-- 迁移时的歧义消除:多个旧 kind 键映射到同一个角色、内容又不同时,优先用哪一份。
--
-- 只有真有歧义的角色需要填。目前只有 Ada:`ch3_a8z0` 是 DLC 的主控 Ada(正身),
-- `ch2_a200` 是本体剧情里的那个 NPC Ada,两份配置内容不一样(实测 head 槛位
-- 11 材质 vs 6 材质,后者是在傀儡身上抓的快照)。
--
-- **这条必须显式写下来** —— "两个 kind 谁是主控"是领域知识,引擎不告诉我们;
-- 而"先看到哪个就用哪个"正是这一整轮在消灭的那种顺序依赖。
local PRIMARY_KIND = {
    Ada = "ch3_a8z0",
}

function CharacterId.primary_kind(char)
    return char and PRIMARY_KIND[char] or nil
end
-- `_Chainsaw/Character/ch/cha0/cha000/10/cha000_10.mesh` → `cha000_10`
--
-- 取第一个点之前的部分,而不是只剥 `.mesh`:资源路径有时带版本后缀
-- (`.mesh.221108797` 这种),而且实测大小写不统一(`_Chainsaw` vs `_chainsaw`),
-- 按"到第一个点为止"切最省事也最稳。
function CharacterId.mesh_name_of(path)
    if type(path) ~= "string" then return nil end
    local base = path:match("([^/\\]+)$")
    if not base then return nil end
    return base:match("^([^.]+)")
end

-- `cha000_10` → `cha000`;`cha006_10_TU1` → `cha006`
function CharacterId.group_of(mesh_name)
    if type(mesh_name) ~= "string" then return nil end
    return mesh_name:match("^(ch%a%d%d%d)")
end

-- 给一份 mesh 来源,认出是谁。认不出时 character 为 nil,但 head_mesh / group
-- 仍然带出来 —— 面板上要能看见"看到了什么编号、只是表里没有",
-- 否则"未命中"和"读不到 mesh"分不开,补表时不知道该补什么。
function CharacterId.identify(source)
    local mesh = Utils.get_mesh(source, "head")
    if not mesh then return nil end
    local name = CharacterId.mesh_name_of(Utils.get_mesh_resource_path(mesh))
    local group = CharacterId.group_of(name)
    return {
        head_mesh = name,
        group     = group,
        character = group and HEAD_GROUP_TO_CHARACTER[group] or nil,
        -- 皮肤维度以后要用:mesh 认人、mdf2 认皮肤。现在只显示,不参与判定。
        head_mdf2 = CharacterId.mesh_name_of(Utils.get_material_resource_path(mesh)),
    }
end

return CharacterId
