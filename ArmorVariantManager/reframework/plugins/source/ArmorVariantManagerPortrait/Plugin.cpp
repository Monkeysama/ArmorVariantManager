#include "reframework/API.hpp"
#include "sol/sol.hpp"
#include <string_view>
#include "PortraitPreview.hpp"
#include "PortraitPose.hpp"

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
    table["portrait_pose_error"] = [] { return std::string(avm_portrait_pose_error()); };
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
    // 随通用包分发，崛起不注册预览能力和 GPU 回调。
    if (std::string_view{param->version->game_name} != "MHWILDS") return true;
    if (!param->renderer_data || param->renderer_data->renderer_type != REFRAMEWORK_RENDERER_D3D12) return false;
    reframework::API::initialize(param);
    if (!avm_portrait_initialize(param)) return false;
    return param->functions->on_lua_state_created(on_lua_state_created)
        && param->functions->on_lua_state_destroyed(on_lua_state_destroyed);
}
