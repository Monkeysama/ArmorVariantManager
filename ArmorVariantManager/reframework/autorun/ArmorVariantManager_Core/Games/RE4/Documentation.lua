-- RE4 的 REFF 帮助页内容(v3:整套造型 + 状态组 + 条件状态 + 预设库)。按 RE4 的概念写,不复用 MH 的分组说明。
-- 内容由维护者直接编辑。
return {
    zh = {
        {
            id = "usage", title = "日常使用",
            entries = {
                { title = "角色", paragraphs = {
                    "配置按角色保存(如 Leon.json)。同一角色在场的玩家、过场傀儡和模型鉴赏雕像共用这一份配置。",
                    "场上有多个角色时,在顶部切换当前编辑的角色。网页和 REF 菜单里的选择互不影响。",
                } },
                { title = "整套造型与状态组", paragraphs = {
                    "整套造型是一份完整快照:每个材质都有开 / 关,同一时间只生效一套。",
                    "状态组只管自己范围里的几个材质,例如「面部:干净 / 受伤 / 血迹重」。一个材质只能属于一个状态组;选「(无)」时,这部分显示整套造型的样子。",
                    "「快速切换」页用来手动选择。正被条件状态接管的整套造型或状态组会锁定,条件结束后回到手动选择。",
                } },
                { title = "左侧的游戏状态", paragraphs = {
                    "左侧只读显示 HP 和当前成立的条件;在整套造型、状态组和条件状态页还会列出最终材质。",
                } },
            },
        },
        {
            id = "states", title = "条件状态",
            entries = {
                { title = "优先级与独占", paragraphs = {
                    "条件状态从上往下就是优先级,拖动左边的 ⠿ 调整。一个条件状态可以同时切换整套造型和若干状态组。",
                    "整套造型和每个状态组,各自听命中的最高那个条件状态的;没被提到的,保持手动选择。",
                    "打开「独占」后,这个条件状态命中时,排在下面的条件状态全部被覆盖。",
                    "颜色:绿色是生效,红色是被覆盖,灰色是未命中;虚线圆圈是已停用。",
                } },
                { title = "条件", paragraphs = {
                    "第一条条件前写「当」,后面每一条前面选「并且」或「或者」,一个条件状态里统一用一种。条件当前成立时会变成绿色。",
                    "受击、掉血这类条件只亮一瞬间。设置「条件不再满足后,继续保持」几秒,命中会延续这么久。",
                } },
                { title = "过渡与按血量驱动", paragraphs = {
                    "渐入 / 渐出只对使用溶解模板(带 Dissolve_Rate 变量)的材质生效,其他材质照常瞬间切换。",
                    "勾选「按血量驱动」后不看条件,在上限与下限之间按血量连续溶解;同一层的多个血量驱动状态按上限从高到低串联。",
                } },
            },
        },
        {
            id = "presets", title = "预设",
            entries = {
                { title = "当前配置与预设库", paragraphs = {
                    "每个角色只有一份正在生效的当前配置。预设库里的预设只是套用的来源,套用是复制:当前配置会先存进「自动保存」(每个角色保留最近 5 份)。",
                    "预设记录了它适用的模型材质,按当前模型标出完全适用、部分适用或不适用。部分适用时,对不上的部位会跳过。",
                } },
                { title = "不会自动切换", paragraphs = {
                    "模型变了时,如果当前配置不再完全适用、而库里有完全适用的预设,只会在「预设」页提醒;换不换由你决定。",
                    "mod 作者随 mod 发布的预设放进 reframework/data/ArmorVariantManager/presets/ 就会出现在库里,这类预设只能套用,不能修改。",
                } },
            },
        },
        {
            id = "misc", title = "旧配置与还原",
            entries = {
                { title = "迁移旧配置", paragraphs = {
                    "旧版配置照常可用。在「杂项」页或 REF 菜单里点「迁移旧配置」转为新版:每条旧规则变成一个条件状态,外观不变;旧的命名存档转成预设。",
                    "迁移前会先写一份还原点,用「恢复到上次删除 / 覆写之前」可以退回旧配置。",
                } },
                { title = "还原点", paragraphs = {
                    "删除和重新抓取之前会自动写还原点;另外还能恢复到本次载入配置时的样子。",
                } },
            },
        },
    },
    en = {
        {
            id = "usage", title = "Everyday use",
            entries = {
                { title = "Characters", paragraphs = {
                    "Configs are saved per character (e.g. Leon.json). The player, cutscene puppets and model-viewer figures of the same character share that config.",
                    "When several characters are on screen, switch the one you are editing at the top. The page and the REF menu keep separate selections.",
                } },
                { title = "Full outfits and state groups", paragraphs = {
                    "A full outfit is a complete snapshot: every material is on or off, and one outfit is in effect at a time.",
                    "A state group covers only its own materials, e.g. \"Face: clean / hurt / bloody\". A material belongs to one group only; when a group is set to (none), that part shows the full outfit.",
                    "Use Quick switch to choose by hand. An outfit or group taken over by a condition state is locked until the condition ends.",
                } },
                { title = "Game state on the left", paragraphs = {
                    "The left column shows HP and the conditions that are true right now; on the editing tabs it also lists the final materials.",
                } },
            },
        },
        {
            id = "states", title = "Condition states",
            entries = {
                { title = "Priority and exclusive", paragraphs = {
                    "Top to bottom is priority; drag ⠿ to reorder. One condition state can switch the full outfit and several state groups at once.",
                    "The full outfit and each state group follow the highest matching condition state; anything not mentioned keeps the manual choice.",
                    "With Exclusive on, every condition state below it is overridden while it matches.",
                    "Colours: green is effective, red is overridden, grey is not matched; a dashed circle is disabled.",
                } },
                { title = "Conditions", paragraphs = {
                    "The first condition starts with \"When\"; each following one is joined with \"and\" or \"or\" (one kind per condition state). A condition that is true right now turns green.",
                    "Hits and HP drops last a split second. \"Keep it for\" extends the match by that many seconds after the condition ends.",
                } },
                { title = "Fades and HP-driven states", paragraphs = {
                    "Fade in / out only affects materials on a dissolve template (with a Dissolve_Rate variable); others switch instantly.",
                    "\"Drive by HP\" ignores conditions and dissolves continuously by HP between the bounds; several HP-driven states on one layer chain from the highest upper bound down.",
                } },
            },
        },
        {
            id = "presets", title = "Presets",
            entries = {
                { title = "Current config and the library", paragraphs = {
                    "Each character has one current config in effect. Presets are only a source to apply from; applying copies the preset, and the current config is auto-saved first (the newest 5 per character are kept).",
                    "Presets remember the materials they were made for and show whether they fit the current model fully, partly or not at all. When a preset fits partly, slots that do not match are skipped.",
                } },
                { title = "Never switched automatically", paragraphs = {
                    "When the model changes and the current config no longer fits fully while a preset does, the Presets tab only reminds you; switching is up to you.",
                    "Presets shipped with a mod go into reframework/data/ArmorVariantManager/presets/ and show up in the library; they can be applied but not changed.",
                } },
            },
        },
        {
            id = "misc", title = "Old configs and restore",
            entries = {
                { title = "Migrating an old config", paragraphs = {
                    "Old configs keep working. Use \"Migrate old config\" on the Misc tab or in the REF menu to convert one: every old rule becomes a condition state and the look stays the same; old named saves become presets.",
                    "A restore point is written first, so \"Restore to before the last delete / overwrite\" brings the old config back.",
                } },
                { title = "Restore points", paragraphs = {
                    "Deleting and recapturing write a restore point first; you can also go back to the config as it was loaded this session.",
                } },
            },
        },
    },
}
