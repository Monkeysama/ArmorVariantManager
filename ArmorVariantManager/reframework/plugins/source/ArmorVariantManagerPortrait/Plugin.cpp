#include "reframework/API.hpp"
#include "sol/sol.hpp"
#include <string_view>
#include "PortraitPreview.hpp"
#include "PortraitPose.hpp"
#include "PortraitGpuResolver.hpp"
#include "GameFiles.hpp"

namespace {
void register_portrait(sol::table table) {
    table["portrait_update"] = &portrait_gpu_update;
    table["portrait_rectangle"] = &portrait_gpu_rectangle;
    table["portrait_output"] = &portrait_gpu_set_output_contract;
    table["portrait_alpha"] = &portrait_gpu_set_alpha_mode;
    table["portrait_version"] = &portrait_gpu_color_version;
    table["portrait_ready"] = &portrait_gpu_ready;
    table["portrait_state"] = &portrait_gpu_state;
    table["portrait_error"] = [] { return std::string(portrait_gpu_error()); };
    table["portrait_drawn"] = &portrait_gpu_drawn;
    table["portrait_present_mode"] = &portrait_gpu_present_mode;
    table["portrait_reff_ready"] = &portrait_gpu_reff_ready;
    table["portrait_reff"] = &portrait_gpu_set_reff;
    table["portrait_pose_version"] = &avm_portrait_pose_version;
    table["portrait_mesh_copy"] = &avm_portrait_mesh_copy;
    using Addresses = sol::as_table_t<std::vector<uintptr_t>>;
    table["portrait_pose_bind"] = [](Addresses st, Addresses ct, Addresses sj, Addresses cj, Addresses sm, Addresses cm) {
        return avm_portrait_pose_bind(st.value(), ct.value(), sj.value(), cj.value(), sm.value(), cm.value());
    };
    table["portrait_pose_sync"] = &avm_portrait_pose_sync;
    table["portrait_pose_clear"] = &avm_portrait_pose_clear;
    table["portrait_blend_version"] = &avm_portrait_blend_version;
    table["portrait_blend_sync"] = &avm_portrait_blend_sync;
    table["portrait_pose_error"] = [] { return std::string(avm_portrait_pose_error()); };
    // 只读游戏目录 natives/ 下的 mdf2(RE4 调色导出 mdf2 材质预设用)。返回内容,或 nil + 原因
    table["read_game_file"] = [](sol::this_state state, const std::string& relative) {
        sol::state_view lua{state};
        std::string data, error;
        if (avm_game_files::read(relative, data, error)) {
            return std::make_tuple(sol::make_object(lua, data), sol::object(sol::lua_nil));
        }
        return std::make_tuple(sol::object(sol::lua_nil), sol::make_object(lua, error));
    };
    // 「替换 mdf」:松散文件判断、覆盖原文件(第一次先留 .avm_bak)、写 / 清重载副本(<名字>_avmr<数字>.mdf2.<版本>)
    table["game_file_exists"] = [](const std::string& relative) { return avm_game_files::exists(relative); };
    table["write_game_file"] = [](sol::this_state state, const std::string& relative, const std::string& data) {
        sol::state_view lua{state};
        std::string error;
        if (avm_game_files::overwrite(relative, data, error)) return std::make_tuple(true, sol::object(sol::lua_nil));
        return std::make_tuple(false, sol::make_object(lua, error));
    };
    table["write_reload_copy"] = [](sol::this_state state, const std::string& relative, const std::string& data) {
        sol::state_view lua{state};
        std::string error;
        if (avm_game_files::write_reload_copy(relative, data, error)) return std::make_tuple(true, sol::object(sol::lua_nil));
        return std::make_tuple(false, sol::make_object(lua, error));
    };
    table["remove_reload_copies"] = [](const std::string& original, sol::optional<std::string> keep) {
        return avm_game_files::remove_reload_copies(original, keep.value_or(std::string()));
    };
}

void on_lua_state_created(lua_State* state) try {
    sol::state_view lua{state};
    auto portrait = lua.create_table();
    register_portrait(portrait);
    lua["avm_portrait"] = portrait;

    // 保留公开桥接表，只补齐预览接口，不接管已有 runtime 或其他 MOD 的 d2d。
    const sol::object existing = lua["avm_bridge"];
    auto bridge = existing.valid() && existing.get_type() == sol::type::table
        ? existing.as<sol::table>() : lua.create_table();
    register_portrait(bridge);
    lua["avm_bridge"] = bridge;
} catch (const std::exception& error) {
    reframework::API::get()->log_error("[AVM Portrait] Lua registration: %s", error.what());
}

void on_lua_state_destroyed(lua_State*) {
    portrait_gpu_update(0, 0, 0, 0, 0, 0);
    portrait_gpu_set_reff(0);
    avm_portrait_pose_clear();
}
}

extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    version->major = REFRAMEWORK_PLUGIN_VERSION_MAJOR;
    version->minor = REFRAMEWORK_PLUGIN_VERSION_MINOR;
    version->patch = REFRAMEWORK_PLUGIN_VERSION_PATCH;
    version->game_name = nullptr;
}

extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    if (!param || !param->version || !param->version->game_name) return false;
    // 随通用包分发：荒野与 RE4 各用自己的纹理布局；崛起不注册预览能力和 GPU 回调。
    const auto* layout = portrait_gpu::layout_for(param->version->game_name);
    if (!layout) return true;
    portrait_gpu::active_layout().store(layout);
    if (!param->renderer_data || param->renderer_data->renderer_type != REFRAMEWORK_RENDERER_D3D12) return false;
    reframework::API::initialize(param);
    if (!avm_portrait_initialize(param)) return false;
    return param->functions->on_lua_state_created(on_lua_state_created)
        && param->functions->on_lua_state_destroyed(on_lua_state_destroyed);
}
