local game, game_error = require("ArmorVariantManager_Core.Game").detect(reframework:get_game_name())
if not game then
    log.error(game_error)
    re.on_draw_ui(function() imgui.text_colored(game_error, 0xFF0000FF) end)
    return
end

-- 开发中遵守
-- 版本号-开发状态-开发状态标识
local version = "4.4.0"
local author = "MK,Moon,AZUSA,Ensicht"

-- =============================================================================
-- 多语言与全局配置系统
-- =============================================================================

local global_settings = require("ArmorVariantManager_Core.Config.Global").new(
    (require(game.prefix .. "Settings")))
local global_config = global_settings.value

-- 本地化字典 (从外部模块加载)
local Localization = require(game.wilds and "ArmorVariantManager_Core.Localization" or game.prefix .. "Localization")
local TransformManager = require(game.prefix .. "Rules")
local ConfigSession = require("ArmorVariantManager_Core.Config.Session")
local GameConfig = require(game.prefix .. "Config")
if game.wilds then
local runtime_module_names = {
    "ArmorVariantManager_Core.PortraitCamera",
    "ArmorVariantManager_Core.PortraitModel",
    "ArmorVariantManager_Core.PortraitPreview",
    "ArmorVariantManager_Core.GroundClippingFix",
    "ArmorVariantManager_Core.GroundClippingTargets",

    "ArmorVariantManager_Core.Games.Wilds.PortraitCamera",
    "ArmorVariantManager_Core.Games.Wilds.PortraitModel",
    "ArmorVariantManager_Core.Games.Wilds.PortraitPreview",
    "ArmorVariantManager_Core.Games.Wilds.Portrait",
    "ArmorVariantManager_Core.Games.Wilds.GroundClippingFix",
    "ArmorVariantManager_Core.Games.Wilds.GroundClippingTargets",
    "ArmorVariantManager_Core.Documentation",
}
if package and package.loaded then
    for _, module_name in ipairs(runtime_module_names) do
        package.loaded[module_name] = nil
    end
end
end
-- 获取本地化字符串
local function T(key)
    if not key then return "nil" end
    local lang = global_config.language or "en"
    if not Localization[lang] then lang = "en" end
    return Localization[lang][key] or tostring(key)
end

-- 加载全局配置
local function load_global_settings()
    global_settings.load()
end

-- 初始化加载
load_global_settings()
-- 场景变化只清运行状态，配置及手动预设选择保持不变。
local appearance
local function reset_actor_context()
    appearance.reset()
end

local runtime, application
local config_session = ConfigSession.new(GameConfig, TransformManager.refresh_config_rules)
if game.wilds then
    runtime = require("ArmorVariantManager_Core.Games.Wilds.Runtime").new(global_config, {reset = reset_actor_context})
else
    application = require("ArmorVariantManager_Core.Games.Rise.Application").new(global_config, config_session)
    runtime, appearance = application.runtime, application.appearance
end
local actors = runtime.actors
local safe_get_game_object = game.wilds and runtime.scene_object.game_object

-- 只接受本轮 PlayerManager 提供的真实玩家。
local function can_use_transform(character)
    return actors.can_transform(character)
end
local function is_weapon_id(id)
    return id and (string.match(id, "^wp%d%d") ~= nil or string.match(id, "^it%d%d%d%d") ~= nil)
end

if game.wilds then
appearance = require("ArmorVariantManager_Core.Games.Wilds.Appearance").new({
    load = config_session.load,
    rules = TransformManager,
    can_transform = can_use_transform,
    game_object = safe_get_game_object,
    is_weapon_id = is_weapon_id,
})
application = require("ArmorVariantManager_Core.Games.Wilds.Application").new(
    runtime, appearance, config_session, TransformManager, is_weapon_id)
end

local app = require("ArmorVariantManager_Core.App").new({
    game=game, backend=application, session=config_session, schema=GameConfig, rules=TransformManager,
    global_settings=global_settings, translate=T, version=version, author=author,
})
app.height = require(game.prefix .. "HeightEditor").new(app)
if game.wilds then
    app.portrait, app.preview = require(game.prefix .. "Portrait").connect(global_config, {
        suspended=runtime.is_suspended,
    })
else
    app.game_options = require(game.prefix .. "Options").new(global_config, runtime, T, app.save_global_settings)
end
app.initialize_settings()
require("ArmorVariantManager_Core.UI.Reff.App").new(app)
local draw = require("ArmorVariantManager_Core.UI.ImGui.Main").new(app)
runtime.install_hooks()
local frame_callbacks = {
        process=application.process,
        retain=function(seen) appearance.state:retain(seen) end,
        update=app.workspace.update,
}
re.on_frame(function() runtime.tick(frame_callbacks) end)
re.on_draw_ui(draw)
