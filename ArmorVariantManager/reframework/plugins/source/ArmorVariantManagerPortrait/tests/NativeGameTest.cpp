#include <windows.h>
#include <cassert>
#include <cstdio>
#include <filesystem>
#include <string_view>
#include "reframework/API.h"

// 只读取本测试进程的导入槽，不移动真实光标。
extern "C" BOOL(WINAPI* __imp_SetCursorPos)(int, int);

namespace {
int callbacks{};
bool created(REFLuaStateCreatedCb) { ++callbacks; return true; }
bool destroyed(REFLuaStateDestroyedCb) { ++callbacks; return true; }
bool present(REFOnPresentCb) { ++callbacks; return true; }
bool reset(REFOnDeviceResetCb) { ++callbacks; return true; }
bool entry(const char*, REFOnPreApplicationEntryCb) { ++callbacks; return true; }
void log(const char*, ...) {}
}

int main(int argc, char** argv) {
    assert(argc == 3);
    const bool wilds = std::string_view(argv[2]) == "MHWILDS";
    const auto temporary = std::filesystem::canonical(std::filesystem::temp_directory_path());
    const auto root = temporary / ("avm-native-game-" + std::to_string(GetCurrentProcessId()));
    assert(root.parent_path() == temporary && std::filesystem::create_directory(root));
    const auto plugins = root / "reframework" / "plugins";
    std::filesystem::create_directories(plugins);
    const auto dll = plugins / std::filesystem::path(argv[1]).filename();
    std::filesystem::copy_file(argv[1], dll);
    const auto cursor = __imp_SetCursorPos;
    const auto module = LoadLibraryW(dll.c_str());
    assert(module);
    // 游戏身份尚未传入时，DllMain 不能创建输入目录或安装钩子。
    Sleep(100);
    const auto runtime = root / "reframework" / "data" / "ArmorVariantManager" / "Runtime";
    assert(!std::filesystem::exists(runtime) && __imp_SetCursorPos == cursor);

    const auto required = reinterpret_cast<REFPluginRequiredVersionFn>(GetProcAddress(module, "reframework_plugin_required_version"));
    const auto initialize = reinterpret_cast<REFPluginInitializeFn>(GetProcAddress(module, "reframework_plugin_initialize"));
    assert(required && initialize);
    REFrameworkPluginVersion version{};
    required(&version);
    assert(version.game_name == nullptr); // 通用包在崛起中静默停用，而不是报“游戏不匹配”。
    version.game_name = argv[2];
    REFrameworkPluginFunctions functions{};
    functions.on_lua_state_created = created;
    functions.on_lua_state_destroyed = destroyed;
    functions.on_present = present;
    functions.on_device_reset = reset;
    functions.on_pre_application_entry = entry;
    functions.log_info = log;
    functions.log_error = log;
    REFrameworkRendererData renderer{wilds ? REFRAMEWORK_RENDERER_D3D12 : REFRAMEWORK_RENDERER_D3D11};
    REFrameworkPluginInitializeParam param{};
    param.version = &version;
    param.functions = &functions;
    param.renderer_data = &renderer;
    assert(initialize(&param));
    if (wilds) {
        assert(callbacks == 4 && !std::filesystem::exists(runtime) && __imp_SetCursorPos == cursor);
        // 与真实宿主一致：活动回调随进程退出，不模拟运行中卸载。
    } else {
        Sleep(100);
        assert(callbacks == 0 && !std::filesystem::exists(runtime) && __imp_SetCursorPos == cursor);
        assert(FreeLibrary(module));
        std::filesystem::remove_all(root);
    }
    std::puts(wilds ? "PASS: Wilds portrait callbacks without UI/input startup" : "PASS: Rise loads native DLL without callbacks, input hooks or runtime files");
}
