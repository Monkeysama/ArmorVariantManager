#pragma once
#include <stdint.h>

/* C ABI v1。仅原生插件使用；Web/Lua 禁止传递本头文件中的指针。 */
#ifdef __cplusplus
extern "C" {
#endif
struct ID3D12Device;
struct ID3D12CommandQueue;
struct ID3D12GraphicsCommandList;
struct ID3D12Resource;
struct ID3D12Fence;
typedef uint64_t REFFPreviewHandle;
enum { REFF_PREVIEW_ABI_V1=1, REFF_PREVIEW_SDR10_CONFIRMED=1 };
enum REFFPreviewCapabilities {
    REFF_PREVIEW_CAP_DX12_CALLBACK=1, REFF_PREVIEW_CAP_UNDERLAY=2,
    REFF_PREVIEW_CAP_SDR8=4, REFF_PREVIEW_CAP_SDR10=8
};
typedef struct REFFPreviewRect { float x, y, width, height; } REFFPreviewRect;
typedef struct REFFPreviewDrawContext {
    uint32_t size, abi_version;
    struct ID3D12Device* device;
    struct ID3D12CommandQueue* queue;
    struct ID3D12GraphicsCommandList* commands;
    struct ID3D12Resource* target;
    struct ID3D12Fence* completion_fence;
    uint64_t completion_value, viewport_generation;
    uint32_t target_format, target_width, target_height;
    REFFPreviewRect destination, clip;
} REFFPreviewDrawContext;
/* Present 线程，非阻塞：只向 commands 录制命令；不得提交/等待队列、转换 target 状态或调用本 API。
   target 已是 RENDER_TARGET；输出为 SDR sRGB 编码值、预乘 alpha。自行设置绘制状态与精确 clip。
   持有的资源最少活到 completion_fence/value；REFF 保留该注册实例直至 GPU 完成。 */
typedef void (__cdecl *REFFPreviewDraw)(void* user, const REFFPreviewDrawContext* context);
/* 注销/替换且最后一次 GPU 使用完成后调用；线程不固定，不得依赖 Lua/浏览器还存活。 */
typedef void (__cdecl *REFFPreviewRelease)(void* user);
typedef struct REFFPreviewProvider {
    uint32_t size;
    const char* plugin_id;
    const char* slot_id;
    void* user;
    REFFPreviewDraw draw;
    REFFPreviewRelease release;
    /* 仅在游戏输出已明确为 SDR10 时设 REFF_PREVIEW_SDR10_CONFIRMED；不把显示器 HDR 状态当交换链色彩空间。 */
    uint32_t flags;
} REFFPreviewProvider;
typedef struct REFFNativePreviewAPI {
    uint32_t size, abi_version, max_slots;
    /* v1: 1 = DX12 回调；2 = 网页下层；4 = SDR UNORM8；8 = 显式 SDR10。HDR 不支持。 */
    uint32_t capabilities;
    REFFPreviewHandle (__cdecl *register_provider)(const REFFPreviewProvider*);
    int (__cdecl *update_provider)(REFFPreviewHandle, const REFFPreviewProvider*);
    int (__cdecl *unregister_provider)(REFFPreviewHandle);
} REFFNativePreviewAPI;
/* GetProcAddress(GetModuleHandleW(L"REFF.dll"), "reff_get_native_preview_api")。
   缺 DLL/导出/版本不匹配时维持原网页和原生预览，不追加普通插件前置条件。 */
typedef const REFFNativePreviewAPI* (__cdecl *REFFGetNativePreviewAPI)(uint32_t abi_version);
#ifdef __cplusplus
}
#endif
