-- RE4 的 REFF 帮助页内容。按 RE4 的概念(整套造型 / 状态组 / 规则)写,不复用 MH 的分组说明。
-- 内容由维护者直接编辑。
return {
    zh = {
        {
            id = "usage", title = "日常使用",
            entries = {
                { title = "角色", paragraphs = {
                    "配置按角色保存(如 Leon.json)。同一角色在场的玩家、CG 过场傀儡和模型鉴赏雕像共用这一份配置。",
                    "场上有多个角色时,在顶部切换当前编辑的角色。网页和 REF 菜单里的选择互不影响。",
                } },
                { title = "整套造型与状态组", paragraphs = {
                    "整套造型是一整套外观,同一时间只生效一份。",
                    "状态组只覆盖它点名的部位,例如「面部:正常 / 受伤 / 低血量」。每个状态组各自生效一个状态,选「(无)」时这个组不发言,显示整套造型的样子。",
                    "没有规则的状态组在「基础状态组」里手动切换;加了规则的状态组归入「高级状态组」,由条件自动驱动。",
                } },
                { title = "自动", paragraphs = {
                    "带规则的层有「自动」开关。开着时规则命中就接管;关掉后规则暂停,改用手动选择。暂停的层会在页面上标出来,避免忘了打开。",
                } },
            },
        },
        {
            id = "rules", title = "条件规则",
            entries = {
                { title = "规则与优先级", paragraphs = {
                    "每个状态最多一条规则。一条规则由若干条件组成,条件之间统一用「全部满足」或「任一满足」连接。",
                    "多条规则同时命中时,状态列表里排在上面的优先。页面上「生效」表示它正在决定外观,「被覆盖」表示条件成立但被更高优先级的规则覆盖。",
                } },
                { title = "条件结束后保持", paragraphs = {
                    "受击、掉血这类条件只亮一瞬间。给规则设置保持秒数后,命中会延续这么久;条件持续成立时会一直续期。",
                } },
                { title = "溶解过渡", paragraphs = {
                    "只对使用溶解模板(带 Dissolve_Rate 变量)的材质生效,其他材质照常瞬间切换。",
                    "溶解过渡:进入状态时按渐入时间溶解,规则结束回到手动选择时按渐出时间溶解。",
                    "按血量驱动:不看条件,在上限与下限之间按血量连续溶解。同一层的多个血量驱动状态按上限从高到低串联。",
                } },
            },
        },
        {
            id = "editing", title = "编辑与存档",
            entries = {
                { title = "编辑预设与状态", paragraphs = {
                    "在「编辑」页选择层,再选中一个预设或状态 —— 选中即生效,然后编辑它的材质。编辑非生效的预设时,改动会被生效的那个盖掉,所以两件事是一个动作。",
                    "整套造型的材质是开 / 关;新建时会抓取当前外观。状态组的材质是「不管 / 关 / 开」三态,「不管」交给整套造型;「整块纳入」让这个状态接管整个部位。",
                    "列表顺序就是优先级,用上移 / 下移调整。删除和「从当前模型重新抓取」会先自动备份。",
                    "打开「备注与定位」可以给材质起名字;「定位」会临时只显示这一个材质几秒,用来认清它是哪块。",
                } },
                { title = "存档与归属", paragraphs = {
                    "「存档」页可以保存命名存档(也能读取其他角色的存档,读取是复制,不影响来源),以及恢复到最近一次删除 / 覆写之前或本次载入时。",
                    "与其他角色共用配置时可以「创建独立预设」;独立后可以初始化。",
                    "网页和 REF 菜单改的是同一份配置,两边的改动会互相同步。",
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
                    "When several characters are on screen, switch the one you are editing at the top. The web page and the REF menu keep separate selections.",
                } },
                { title = "Full outfit and state groups", paragraphs = {
                    "A full outfit is a complete look; one is in effect at a time.",
                    "A state group covers only the parts it names, e.g. \"Face: normal / hurt / low HP\". Each group has one state in effect; \"(none)\" lets the full outfit show through.",
                    "Groups without rules are switched by hand under Basic state groups; groups with rules move to Advanced state groups and are driven by conditions.",
                } },
                { title = "Auto", paragraphs = {
                    "Layers with rules have an Auto switch. When on, a matching rule takes over; when off, rules pause and the manual choice applies. Paused layers are flagged so they are not forgotten.",
                } },
            },
        },
        {
            id = "rules", title = "Condition rules",
            entries = {
                { title = "Rules and priority", paragraphs = {
                    "Each state has at most one rule. A rule is a list of conditions joined by either \"all\" or \"any\".",
                    "When several rules match, the state higher in the list wins. \"Effective\" means the rule is deciding the look; \"Overridden\" means it matches but a higher-priority rule covers it.",
                } },
                { title = "Hold after the condition ends", paragraphs = {
                    "Hits and HP drops last a split second. A hold time keeps the rule matched for that long, and keeps extending while the condition stays true.",
                } },
                { title = "Dissolve transitions", paragraphs = {
                    "Only materials on a dissolve template (with a Dissolve_Rate variable) dissolve; the rest switch instantly.",
                    "Dissolve transition: entering a state dissolves over the fade-in time; returning to the manual choice dissolves over the fade-out time.",
                    "HP-driven: ignores conditions and dissolves continuously by HP between the upper and lower bounds. Several HP-driven states in one layer chain from the highest upper bound down.",
                } },
            },
        },
        {
            id = "editing", title = "Editing and saves",
            entries = {
                { title = "Editing presets and states", paragraphs = {
                    "On the Edit tab pick a layer, then select a preset or state - selecting puts it in effect - and edit its materials. Editing a preset that is not in effect would be overwritten by the one that is, so both happen in one step.",
                    "Full-outfit materials are on / off; a new full outfit captures the current look. State-group materials are Ignore / Off / On, where Ignore leaves the material to the full outfit; Claim all makes the state take over a whole part.",
                    "List order is priority; use move up / down. Deleting and recapturing take a backup first.",
                    "Turn on Notes & locate to name materials; Locate shows only that material for a few seconds so you can tell which piece it is.",
                } },
                { title = "Saves and ownership", paragraphs = {
                    "The Saves tab keeps named saves (you can also load another character's save; loading copies it and leaves the source alone) and restores to before the last delete / overwrite or to when the config was loaded.",
                    "While sharing a config with another character you can make it independent; once independent you can reset it.",
                    "The page and the REF menu edit the same config, and changes show up on both sides.",
                } },
            },
        },
    },
}
