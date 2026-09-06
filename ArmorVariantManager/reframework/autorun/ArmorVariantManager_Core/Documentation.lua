return {
    {
        title = "如何配置",
        entries = {
            {
                title = "1. 当前防具/武器部件",
                paragraphs = {
                    "可以查看当前装备的材质列表，左侧的勾选框可操控当前装备的材质对应网格的显示/隐藏。"
                }
            },
            {
                title = "2. 预设",
                paragraphs = {
                    "在材质列表中勾选好想要显示的效果，在创建新预设处输入名称，点击保存为新预设即可创建一个预设。"
                }
            },
            {
                title = "3. 默认分组",
                paragraphs = {
                    "所有的材质在最开始时都会进入默认分组，默认分组不可删除。",
                    "适用于整套装备只有少量材质变化，或者所有材质都是统一切换的场景：比如整套防具只有一个简单的显示/隐藏披风需求。"
                }
            },
            {
                title = "4. 分组",
                paragraphs = {
                    "点击新增分组，此时会进入材质选择状态，在防具列表里勾选想进行分组的材质，输入名称点击确认即可创建一个新的分组。",
                    "分组会将选中的材质从默认分组里抽离出来，这部分材质控制权交给对应的分组。",
                    "在默认分组中，能够看到材质被哪个分组占用。",
                    "适用于同一套装备有多个独立部位需要分别管理，且它们之间互不影响：比如腰部装饰有长裙/短裙/无三种，腿部有长靴/短靴两种，分别建组，互相独立切换。"
                }
            },
            {
                title = "5. 全局分组",
                paragraphs = {
                    "点击新增分组时，在下方勾选全局分组，即可进入新增全局分组模式，操作与分组一样。",
                    "全局分组不会将选中的材质从默认分组里抽离出来，其他分组仍然能选择和控制全局分组里的材质。",
                    "全局分组具有最高的隐藏优先级，即被全局分组隐藏的，在任何状态下始终保持隐藏。",
                    "被全局分组隐藏的材质在其他分组下仍可被勾选，但仅记录状态，不会进行显示/隐藏替换。",
                    "适用于跨越多个分组的统一控制：比如分组里的例子上加上红黄蓝三种配色，那使用普通分组则需要分 3×3+2×3 种预设，这时则可以将换色这个功能放进全局分组内。"
                }
            },
            {
                title = "6. 变身管理",
                paragraphs = {
                    "基础预设管理基础上的功能，可以根据游戏内的不同条件动态操控预设变化。",
                    "变身管理具有回退功能，以血量触发为例，当血量低于 80 时从 A 变为 B，那当血量高于 80 时自动回退到 A。",
                    "多状态并行时，优先级数字越小则表示优先级越高。",
                }
            },
            {
                title = "7. 预设文件",
                paragraphs = {
                    "保存的预设会在 reframework\\data\\ArmorVariantManager 文件夹内。",
                    "装备以当前身体（Body）部位为准，以当前身体部位 ID 命名，例如 ch03_060_0002.json。",
                    "武器直接记录当前武器 ID，例如 it0300_0020。"
                }
            }
        },
        en = {
            title = "How to Configure",
            entries = {
                {
                    title = "1. Current Armor/Weapon Parts",
                    paragraphs = {
                        "View the material list of the currently equipped item. Use the checkboxes on the left to show or hide the mesh corresponding to each material."
                    }
                },
                {
                    title = "2. Presets",
                    paragraphs = {
                        "Select the materials you want to show in the material list, enter a name in Create New Preset, and click Save to create a preset."
                    }
                },
                {
                    title = "3. Default Group",
                    paragraphs = {
                        "All materials are initially placed in the default group, which cannot be deleted.",
                        "Use it when only a small number of materials need to change, or when all materials should switch together. For example, hiding or showing a cloak on an entire armor set."
                    }
                },
                {
                    title = "4. Groups",
                    paragraphs = {
                        "Click Add Group to enter material selection mode. Select the materials to manage separately, enter a name, and click Confirm to create a group.",
                        "A group removes the selected materials from the default group and gives control of them to the new group.",
                        "The default group shows which group currently owns each material.",
                        "Use groups when several independent parts of the same equipment need separate presets, such as long/short/no skirt and long/short boots."
                    }
                },
                {
                    title = "5. Global Groups",
                    paragraphs = {
                        "When creating a group, enable Global Group below the name field to create a global group. The remaining steps are the same as for a normal group.",
                        "A global group does not remove its materials from the default group. Other groups can still select and control those materials.",
                        "Global groups have the highest hide priority. A material hidden by a global group remains hidden in every state.",
                        "A material hidden by a global group can still be checked in other groups; those checks are recorded but do not make the material visible.",
                        "Use global groups for shared controls across multiple groups, such as a common color option that would otherwise require many combinations of presets."
                    }
                },
                {
                    title = "6. Transform Manager",
                    paragraphs = {
                        "This feature builds on preset management and can switch presets dynamically according to in-game conditions.",
                        "The Transform Manager supports fallback behavior. For example, if health below 80 switches from A to B, health above 80 automatically falls back to A.",
                        "In parallel mode, a smaller priority number means a higher priority."
                    }
                },
                {
                    title = "7. Preset Files",
                    paragraphs = {
                        "Presets are saved in the reframework\\data\\ArmorVariantManager folder.",
                        "Armor files use the current Body part ID as the file name, for example ch03_060_0002.json.",
                        "Weapon files use the current Weapon ID, for example it0300_0020."
                    }
                }
            }
        }
    },
    {
        title = "如何使用",
        entries = {
            {
                title = "使用",
                paragraphs = {
                    "选择分组，再选择想要调整的预设，点击设为默认即可将选中的预设永久保存。",
                    "当前版本默认启用自动保存，不再需要手动保存，你也可以关掉它。"
                }
            },
            {
                title = "预设丢失",
                paragraphs = {
                    "使用盒子等工具更改套装会导致当前预设失效。当前套装无预设时会出现自动查找预设按钮，点击即可重新匹配预设。",
                }
            },
            {
                title = "预设被覆盖掉",
                paragraphs = {
                    "盒子等 MOD 管理工具在启用/禁用 MOD 时会把所有 MOD 重新安装一遍。如自行创建了预设，可以手动备份 reframework\\data\\ArmorVariantManager 文件夹。",
                    "差分管理器会创建备份文件，如果检测到备份文件冲突，会提示还原备份，点击即可还原你自己的预设。"
                }
            },
            {
                title = "掉帧/卡顿",
                paragraphs = {
                    "经测试对帧数的影响不到 2 FPS，如需要调整，可在性能设置里将选项往右拉。"
                }
            }
        },
        en = {
            title = "How to Use",
            entries = {
                {
                    title = "Using Presets",
                    paragraphs = {
                        "Select a group, then select the preset you want to use. Click Set as Default to save the selected preset permanently.",
                        "Auto-save is enabled by default in the current version, so manual saving is not required. You can disable it if needed."
                    }
                },
                {
                    title = "Preset Missing",
                    paragraphs = {
                        "Changing an outfit with tools such as an equipment box can invalidate the current preset. When the current equipment has no preset, click Auto Find Preset to match a preset again."
                    }
                },
                {
                    title = "Preset Overwritten",
                    paragraphs = {
                        "MOD management tools may reinstall all MODs when enabling or disabling a MOD. If you created custom presets, manually back up the reframework\\data\\ArmorVariantManager folder.",
                        "Armor Variant Manager creates backup files. If a backup conflict is detected, click Restore Backup to restore your presets."
                    }
                },
                {
                    title = "Frame Drops/Stuttering",
                    paragraphs = {
                        "Testing shows that the performance impact is less than 2 FPS. If adjustment is needed, move the options to the right in Performance settings."
                    }
                }
            }
        }
    },
    {
        title = "更新日志",
        entries = {
            {
                title = "V4.1.1",
                paragraphs = {
                    "修复新的全局分组无法生效的问题。"
                }
            },
            {
                title = "V4.1.0",
                paragraphs = {
                    "修复新UI的一些问题。为说明文档新增了英文翻译。"
                }
            },
            {
                title = "V4.0.0",
                paragraphs = {
                    "1. 新增独立 UI 面板，默认使用 Home 键打开。",
                    "2. 新增支持自定义名字的装备。",
                    "3. 新增自动保存预设功能，默认启用。",
                    "4. 修复亿点 bug。"
                }
            },
            {
                title = "V3.3.0",
                paragraphs = {
                    "新增备份与恢复功能，修复全局分组在变身管理中使用的 BUG。"
                }
            },
            {
                title = "V3.2.0",
                paragraphs = {
                    "1. 新增全局分组功能，创建分组时可以将当前分组勾选为全局分组。",
                    "2. 优化 UI 界面的操作性：材质列表支持全选/反选，按输入筛选，可以覆盖保存当前预设，分组和预设支持排序。",
                    "3. 修复一些 bug。"
                }
            },
            {
                title = "V3.1.0",
                paragraphs = {
                    "更新支持武器差分，修复一些 bug。"
                }
            },
            {
                title = "V3.0.0",
                paragraphs = {
                    "引入全新的变身管理系统，支持基于条件（生命值、受击、武器拔刀/收刀，太刀气刃等级，大剑蓄力状态等武器）的动态外观切换。"
                }
            },
            {
                title = "V2.1.1",
                paragraphs = {
                    "修复了多人模式下的一些 bug。"
                }
            },
            {
                title = "V2.0.0",
                paragraphs = {
                    "1. 新增分组功能，可以将选中的选项抽离出一个分组，可以为新的分组单独配置预设。",
                    "2. 去掉了加载按钮，现在选中即加载。",
                    "3. 开放性能配置选项，可按照说明结合实际 CPU 性能调整，该选项直接关联着切换装备后加载预设的速度。"
                }
            },
            {
                title = "V1.2.1",
                paragraphs = {
                    "修复潜在的 bug，优化性能。"
                }
            },
            {
                title = "V1.2.0",
                paragraphs = {
                    "增加自动查找预设按钮，可以从 json 列表里查找匹配的预设，用于盒子等工具修改套装后恢复预设功能。"
                }
            },
            {
                title = "V1.1.0",
                paragraphs = {
                    "修复主菜单/存档界面不生效的问题。"
                }
            },
            {
                title = "V1.0.0",
                paragraphs = {
                    "发布。"
                }
            }
        },
        en = {
            title = "Changelog",
            entries = {
                {
                    title = "V4.1.1",
                    paragraphs = {
                        "Fixed a bug where new global groups wouldn't work."
                    }
                },
                {
                    title = "V4.1.0",
                    paragraphs = {
                        "Fixed several new UI issues and added English documentation."
                    }
                },
                {
                    title = "V4.0.0",
                    paragraphs = {
                        "1. Added an independent UI panel, opened with the Home key by default.",
                        "2. Added support for equipment with custom names.",
                        "3. Added automatic preset saving, enabled by default.",
                        "4. Fixed many bugs."
                    }
                },
                {
                    title = "V3.3.0",
                    paragraphs = {
                        "Added backup and restore support, and fixed a bug affecting global groups in the Transform Manager."
                    }
                },
                {
                    title = "V3.2.0",
                    paragraphs = {
                        "1. Added global groups, which can be enabled while creating a group.",
                        "2. Improved the UI: material lists support select all, invert selection, filtering, preset overwrite, and group/preset sorting.",
                        "3. Fixed several bugs."
                    }
                },
                {
                    title = "V3.1.0",
                    paragraphs = {
                        "Added weapon variant support and fixed several bugs."
                    }
                },
                {
                    title = "V3.0.0",
                    paragraphs = {
                        "Introduced the Transform Manager, which supports dynamic appearance changes based on conditions such as health, damage, weapon draw state, longsword spirit level, and greatsword charge state."
                    }
                },
                {
                    title = "V2.1.1",
                    paragraphs = {
                        "Fixed several bugs in multiplayer mode."
                    }
                },
                {
                    title = "V2.0.0",
                    paragraphs = {
                        "1. Added groups, allowing selected materials to be managed separately with their own presets.",
                        "2. Removed the Load button; selecting a preset now loads it immediately.",
                        "3. Added performance settings. Adjust them according to the instructions and your CPU; they directly affect how quickly presets load after equipment changes."
                    }
                },
                {
                    title = "V1.2.1",
                    paragraphs = {
                        "Fixed potential bugs and improved performance."
                    }
                },
                {
                    title = "V1.2.0",
                    paragraphs = {
                        "Added Auto Find Preset, which searches JSON files for a matching preset after tools such as equipment boxes modify an outfit."
                    }
                },
                {
                    title = "V1.1.0",
                    paragraphs = {
                        "Fixed an issue where the mod did not work in the main menu or save screen."
                    }
                },
                {
                    title = "V1.0.0",
                    paragraphs = {
                        "Initial release."
                    }
                }
            }
        }
    }
}
