#include <windows.h>
#include <cassert>
#include <cstdio>
#include <string_view>
#include "reframework/API.h"
#include "sol/sol.hpp"

namespace {
REFLuaStateCreatedCb created{};
REFLuaStateDestroyedCb destroyed{};
REFOnPresentCb present{};
REFOnDeviceResetCb reset{};
int errors{};
bool register_created(REFLuaStateCreatedCb fn) { assert(!created); created = fn; return true; }
bool register_destroyed(REFLuaStateDestroyedCb fn) { assert(!destroyed); destroyed = fn; return true; }
bool register_present(REFOnPresentCb fn) { assert(!present); present = fn; return true; }
bool register_reset(REFOnDeviceResetCb fn) { assert(!reset); reset = fn; return true; }
void log_info(const char*, ...) {}
void log_error(const char*, ...) { ++errors; }
}

int main(int argc, char** argv) {
    assert(argc == 3);
    const bool bridge_first = std::string_view(argv[2]) == "bridge-first";
    const auto plugin = LoadLibraryA(argv[1]);
    assert(plugin);
    const auto initialize = reinterpret_cast<REFPluginInitializeFn>(GetProcAddress(plugin, "reframework_plugin_initialize"));
    const auto mode = reinterpret_cast<int (*)()>(GetProcAddress(plugin, "portrait_gpu_present_mode"));
    assert(initialize && mode);
    REFrameworkPluginFunctions functions{};
    functions.on_lua_state_created = register_created;
    functions.on_lua_state_destroyed = register_destroyed;
    functions.on_present = register_present;
    functions.on_device_reset = register_reset;
    functions.log_info = log_info;
    functions.log_error = log_error;
    REFrameworkRendererData renderer{REFRAMEWORK_RENDERER_D3D12};
    REFrameworkPluginVersion version{};
    version.game_name = "MHWILDS";
    REFrameworkPluginInitializeParam param{};
    param.version = &version;
    param.functions = &functions;
    param.renderer_data = &renderer;
    assert(initialize(&param));
    assert(created && destroyed && present && reset);
    assert(mode() == 0);

    for (int generation = 0; generation < 2; ++generation) {
        sol::state lua;
        lua.open_libraries(sol::lib::base);
        lua.script("d2d = { owner = 'external' }; original_d2d = d2d");
        if (bridge_first) lua.script("avm_bridge = { register_runtime = function() return 42 end, retained = 17 }");
        created(lua.lua_state());
        if (!bridge_first) lua.script("avm_bridge.register_runtime = function() return 42 end; avm_bridge.retained = 17");
        lua["initial_state"] = generation == 0 ? 3 : 1;
        lua.script(R"(
            assert(avm_bridge.register_runtime() == 42 and avm_bridge.retained == 17)
            assert(avm_portrait.register_runtime == nil and d2d == original_d2d and d2d.owner == 'external')
            for _, name in ipairs({'update', 'rectangle', 'output', 'alpha', 'version', 'ready', 'state',
                'error', 'drawn', 'present_mode', 'reff_ready', 'reff', 'pose_version', 'mesh_copy', 'pose_bind', 'pose_sync', 'pose_clear', 'pose_error'}) do
                assert(type(avm_portrait['portrait_' .. name]) == 'function', name)
                assert(type(avm_bridge['portrait_' .. name]) == 'function', name)
            end
            assert(avm_portrait.portrait_version() == 4 and avm_bridge.portrait_version() == 4)
            assert(avm_portrait.portrait_ready() == 1 and avm_portrait.portrait_state() == initial_state)
            assert(avm_portrait.portrait_output(0, 1) == 0 and avm_portrait.portrait_state() == 1)
            assert(avm_portrait.portrait_update(0, 0, 0, 0, 0, 0) == 0)
            avm_portrait.portrait_pose_clear()
        )");
        // 不加载旧 UI DLL，只有独立预览拥有 Present/Reset 回调。
        present(); present();
        assert(mode() == 0);
        destroyed(lua.lua_state());
        reset();
    }
    assert(errors == 0);
    std::puts("PASS: standalone Lua registration, either bridge initialization order, external D2D ownership, one present/reset callback and Lua reset without the retired UI DLL");
    // 回调指针在 host 生命周期内有效；离线进程直接退出，不模拟运行中卸载插件。
}
