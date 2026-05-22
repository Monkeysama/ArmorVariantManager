local ExtensionLocalization = {}

function ExtensionLocalization.inject(loc)
    if not loc then return end
    local en = loc["en"]
    local zh = loc["zh"]

    if en then
        en["condition_delay"] = "Trigger Delay (s)"
        en["action_mode"] = "Action Mode"
        en["mode_normal"] = "Normal (Single)"
        en["mode_loop"] = "Loop (Repeat)"
        en["mode_chain"] = "Chain (Multi-Node)"
        en["loop_inactive"] = "Inactive Rest (s)"
        en["loop_count"] = "Loop Count (0=inf)"
        en["chain_loop_count"] = "Chain Loop Count (0=inf)"
        en["chain_node"] = "Node"
        en["add_chain_node"] = "Add Node"
        en["delete_chain_node"] = "Del Node"
        en["duration"] = "Duration (s)"
        en["keep_state"] = "Keep until state ends"
        en["trigger_on_damage"] = "Trigger on Damage"
    end

    if zh then
        zh["condition_delay"] = "触发延迟(秒)"
        zh["action_mode"] = "执行模式"
        zh["mode_normal"] = "普通变身 (单次)"
        zh["mode_loop"] = "循环变身 (重复)"
        zh["mode_chain"] = "链式变身 (多节点)"
        zh["loop_inactive"] = "取消变身冷却(秒)"
        zh["loop_count"] = "循环次数(0=无限)"
        zh["chain_loop_count"] = "链循环次数(0=无限)"
        zh["chain_node"] = "链式节点"
        zh["add_chain_node"] = "添加新节点"
        zh["delete_chain_node"] = "删除节点"
        zh["duration"] = "持续时间(秒)"
        zh["keep_state"] = "当前状态结束前持续显示"
        zh["trigger_on_damage"] = "受击瞬间触发"
    end
end

return ExtensionLocalization
