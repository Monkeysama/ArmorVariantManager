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
    // read_game_file:只放行游戏目录 natives/ 下的 .mdf2.<版本>;测试进程的目录就是"游戏目录"
    {
        wchar_t exe[MAX_PATH]{};
        GetModuleFileNameW(nullptr, exe, MAX_PATH);
        std::wstring dir(exe);
        dir = dir.substr(0, dir.find_last_of(L'\\'));
        CreateDirectoryW((dir + L"/natives").c_str(), nullptr);
        CreateDirectoryW((dir + L"/natives/STM").c_str(), nullptr);
        const std::wstring file = dir + L"/natives/STM/avm_test.mdf2.32";
        const HANDLE h = CreateFileW(file.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        assert(h != INVALID_HANDLE_VALUE);
        const char bytes[] = { 'M', 'D', 'F', 0, 32, 0, 0, 7 };
        DWORD written{};
        WriteFile(h, bytes, sizeof(bytes), &written, nullptr);
        CloseHandle(h);
        sol::state lua;
        lua.open_libraries(sol::lib::base, sol::lib::string);
        created(lua.lua_state());
        lua.script(R"(
            local data, err = avm_portrait.read_game_file('natives/STM/avm_test.mdf2.32')
            assert(err == nil and #data == 8 and data:sub(1, 3) == 'MDF' and data:byte(8) == 7, 'binary content survives')
            local _, missing = avm_portrait.read_game_file('natives/STM/none.mdf2.32')
            assert(missing == 'not found')
            for _, bad in ipairs({ 'natives/STM/../../x.mdf2.32', 'C:/natives/a.mdf2.32', '/natives/a.mdf2.32', 'natives/STM/a.mdf2',
                'natives/STM/a.tex.143221013', 'reframework/data/a.mdf2.32', 'natives//a.mdf2.32', 'natives/STM/a.mdf2.32x' }) do
                local d, e = avm_portrait.read_game_file(bad)
                assert(d == nil and e == 'path not allowed', bad)
            end
            -- 覆盖:只覆盖已有文件;第一次留 .avm_bak(之后不动);不许用重载副本的名字
            assert(avm_portrait.game_file_exists('natives/STM/avm_test.mdf2.32') == true)
            assert(avm_portrait.game_file_exists('natives/STM/none.mdf2.32') == false)
            local ok, err = avm_portrait.write_game_file('natives/STM/none.mdf2.32', 'x')
            assert(not ok and err == 'not found', 'never creates the original')
            assert(avm_portrait.write_game_file('natives/STM/avm_test.mdf2.32', 'second'))
            assert(avm_portrait.read_game_file('natives/STM/avm_test.mdf2.32') == 'second')
            assert(avm_portrait.write_game_file('natives/STM/avm_test.mdf2.32', 'third'))
            assert(avm_portrait.read_game_file('natives/STM/avm_test.mdf2.32') == 'third')
            assert(not avm_portrait.write_game_file('natives/STM/avm_test_avmr1.mdf2.32', 'x'), 'reload copies are not originals')
            assert(not avm_portrait.write_game_file('natives/../x.mdf2.32', 'x'))
            -- 重载副本:只接受 _avmr<数字> 的名字,可以新建;清理时保留指定的那个
            assert(avm_portrait.write_reload_copy('natives/STM/avm_test_avmr1.mdf2.32', 'c1'))
            assert(avm_portrait.write_reload_copy('natives/STM/avm_test_avmr2.mdf2.32', 'c2'))
            assert(not avm_portrait.write_reload_copy('natives/STM/avm_test_copy.mdf2.32', 'x'))
            assert(not avm_portrait.write_reload_copy('natives/STM/avm_test_avmr.mdf2.32', 'x'))
            assert(avm_portrait.remove_reload_copies('natives/STM/avm_test.mdf2.32', 'natives/STM/avm_test_avmr2.mdf2.32') == 1)
            assert(not avm_portrait.game_file_exists('natives/STM/avm_test_avmr1.mdf2.32'))
            assert(avm_portrait.read_game_file('natives/STM/avm_test_avmr2.mdf2.32') == 'c2')
            assert(avm_portrait.remove_reload_copies('natives/STM/avm_test.mdf2.32') == 1)
        )");
        // 备份是第一次覆盖前的原文件,之后的覆盖不动它
        {
            const std::wstring backup = file + L".avm_bak";
            const HANDLE b = CreateFileW(backup.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
            assert(b != INVALID_HANDLE_VALUE);
            char got[16]{};
            DWORD read{};
            ReadFile(b, got, sizeof(got), &read, nullptr);
            CloseHandle(b);
            assert(read == 8 && got[0] == 'M' && got[7] == 7);
            DeleteFileW(backup.c_str());
        }
        destroyed(lua.lua_state());
        DeleteFileW(file.c_str());
    }
    assert(errors == 0);
    std::puts("PASS: read_game_file reads natives/ mdf2 files only (binary safe, missing files reported, traversal / absolute / other types rejected)");
    std::puts("PASS: write_game_file only overwrites existing mdf2 files and keeps the first original as .avm_bak; reload copies use _avmr<n> names and are cleaned up");
    std::puts("PASS: standalone Lua registration, either bridge initialization order, external D2D ownership, one present/reset callback and Lua reset without the retired UI DLL");
    // 回调指针在 host 生命周期内有效；离线进程直接退出，不模拟运行中卸载插件。
}
