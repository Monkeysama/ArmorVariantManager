local Scene = require("ArmorVariantManager_Core.Games.Rise.SceneObject")
local Editor = require("ArmorVariantManager_Core.UI.HeightEditor")
local HeightEditor = {}

-- Cog is the parent of the hunter's waist. Keep the GameObject and its collision at game height.
function HeightEditor.new(app)
    local appearance, runtime = app.appearance, app.runtime
    local applied, failed
    local status = {key="heel_disabled"}

    local function current_joint(actor)
        if not Scene.is_alive(actor) then return nil end
        local manager = sdk.get_managed_singleton("snow.player.PlayerManager")
        local master = manager and manager:call("findMasterPlayer")
        if not master or master:call("get_GameObject") ~= actor then return nil end
        local transform = actor:call("get_Transform")
        return transform and transform:call("getJointByName", "Cog")
    end

    local function restore()
        if not applied then return end
        local old = applied
        applied = nil
        -- Re-resolve on the original, still-live actor before touching a rebuilt skeleton.
        if not Scene.is_alive(old.actor) then return end
        local transform = old.actor:call("get_Transform")
        local joint = transform and transform:call("getJointByName", "Cog")
        if not joint or joint ~= old.joint then return end
        local p = joint:call("get_LocalPosition")
        if math.abs(p.y - old.written) < 0.000005 then
            joint:call("set_LocalPosition", Vector3f.new(p.x, old.base, p.z))
        end
    end

    local function apply()
        restore()
        if runtime.is_suspended() then status.key = "heel_suspended"; return end
        local actor, cm = appearance.height_actor, appearance.height_cm
        if not actor or not cm or cm == 0 then status.key = "heel_disabled"; return end
        local joint = current_joint(actor)
        if not joint then status.key = "heel_no_root"; return end
        local p = joint:call("get_LocalPosition")
        local y = p.y + cm / 100
        applied = {actor=actor, joint=joint, base=p.y, written=y}
        joint:call("set_LocalPosition", Vector3f.new(p.x, y, p.z))
        status.key = "heel_applied"
    end
    local function guarded(fn)
        return function()
            if failed then return end
            local ok, reason = pcall(fn)
            if not ok then
                pcall(restore)
                failed = true
                status.key, status.error = "heel_error", tostring(reason)
            end
        end
    end
    -- Remove our previous contribution before animation samples its local transform.
    re.on_pre_application_entry("UpdateMotion", guarded(restore))
    re.on_application_entry("LateUpdateBehavior", guarded(apply))
    re.on_script_reset(guarded(restore))
    return Editor.new(app, {
        get_status=function() return status end,
        settings_changed=function()
            failed, status.error = false, nil
            runtime.refresh()
        end,
    })
end

return HeightEditor
