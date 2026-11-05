#pragma once
#include <windows.h>
#include <d3d12.h>
#include <wrl.h>
#include <atomic>
#include <cstdint>
#include <cwchar>
#include <string_view>

namespace portrait_gpu {
template<class T> bool read(uintptr_t address, T& value) {
    SIZE_T received{};
    return address >= 0x10000 && ReadProcessMemory(GetCurrentProcess(), reinterpret_cast<void*>(address),
        &value, sizeof(value), &received) && received == sizeof(value);
}

// 只接受虚表所属模块已确认的节点；不能对引擎纹理直接调用 COM 方法。
inline bool module_is(uintptr_t address, bool graphics) {
    uintptr_t table{};
    if (!read(address, table)) return false;
    HMODULE module{};
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
        reinterpret_cast<LPCWSTR>(table), &module)) return false;
    if (!graphics) return module == GetModuleHandleW(nullptr);
    wchar_t path[MAX_PATH]{};
    if (!GetModuleFileNameW(module, path, MAX_PATH)) return false;
    auto name = wcsrchr(path, L'\\'); name = name ? name + 1 : path;
    return _wcsicmp(name, L"D3D12Core.dll") == 0 || _wcsicmp(name, L"d3d12.dll") == 0;
}

// SEH 只保护小型接口查询，不作为 GPU 提交或任意未知指针调用的安全保证。
inline HRESULT query_resource(uintptr_t address, ID3D12Resource** result) {
    __try { return reinterpret_cast<IUnknown*>(address)->QueryInterface(IID_PPV_ARGS(result)); }
    __except(EXCEPTION_EXECUTE_HANDLER) { *result = nullptr; return E_POINTER; }
}

// 保留旧头像尺寸兼容，仅额外接受正式高清资源，不放宽为任意引擎纹理。
inline bool valid_size(uint64_t width, uint32_t height) {
    return (width == 220 && height == 240) || (width == 660 && height == 720);
}

inline bool valid_desc(const D3D12_RESOURCE_DESC& d) {
    return d.Dimension == D3D12_RESOURCE_DIMENSION_TEXTURE2D && valid_size(d.Width, d.Height)
        && d.DepthOrArraySize == 1 && d.MipLevels == 1 && d.SampleDesc.Count == 1
        && (d.Format == DXGI_FORMAT_R8G8B8A8_UNORM || d.Format == DXGI_FORMAT_R8G8B8A8_UNORM_SRGB
            || d.Format == DXGI_FORMAT_R8G8B8A8_TYPELESS)
        && !(d.Flags & D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE);
}

// 引擎对象链的偏移按游戏区分：holder -> 资源 -> 纹理(宽高) -> DX 包装 -> ID3D12Resource。
// 每一层、尺寸、接口与设备都需要再验证，不同游戏之间不互相借用。
struct Layout { uintptr_t resource, texture, width, height, dx, native; };
// Wilds 1.42.0.2 的观察布局。
inline constexpr Layout WILDS_LAYOUT{0x10, 0x70, 0x38, 0x3c, 0xf0, 0x20};
// RE4(chainsaw)实测:纹理在资源 +0x50,宽高在纹理 +0x30/+0x34,纹理 +0xF0 是句柄不是指针,
// DX 包装在纹理 +0xB8,ID3D12Resource 在包装 +0x18。
inline constexpr Layout RE4_LAYOUT{0x10, 0x50, 0x30, 0x34, 0xb8, 0x18};

inline const Layout* layout_for(std::string_view game) {
    if (game == "MHWILDS") return &WILDS_LAYOUT;
    if (game == "RE4") return &RE4_LAYOUT;
    return nullptr;
}
// 初始化时按游戏选定一次;未选定时保持 Wilds 布局(离线工具与旧行为)。
inline std::atomic<const Layout*>& active_layout() {
    static std::atomic<const Layout*> value{&WILDS_LAYOUT};
    return value;
}

// 只走引擎对象链并核对模块与尺寸,不调用任何 COM 方法。
inline bool locate(uintptr_t holder, const Layout& l, uintptr_t& native, uint32_t& width, uint32_t& height) {
    uintptr_t resource{}, texture{}, dx{};
    native = 0; width = height = 0;
    return read(holder + l.resource, resource) && module_is(resource, false)
        && read(resource + l.texture, texture) && module_is(texture, false)
        && read(texture + l.width, width) && read(texture + l.height, height) && valid_size(width, height)
        && read(texture + l.dx, dx) && module_is(dx, false)
        && read(dx + l.native, native) && module_is(native, true);
}

inline HRESULT resolve(uintptr_t holder, Microsoft::WRL::ComPtr<ID3D12Resource>& result) {
    result.Reset();
    uintptr_t native{};
    uint32_t width{}, height{};
    if (!locate(holder, *active_layout().load(), native, width, height)) return E_INVALIDARG;
    auto hr = query_resource(native, result.GetAddressOf());
    if (FAILED(hr)) return hr;
    const auto desc = result->GetDesc();
    if (!valid_desc(desc) || desc.Width != width || desc.Height != height) { result.Reset(); return E_INVALIDARG; }
    Microsoft::WRL::ComPtr<ID3D12Device> device;
    hr = result->GetDevice(IID_PPV_ARGS(&device));
    if (FAILED(hr)) result.Reset();
    return hr;
}
}
