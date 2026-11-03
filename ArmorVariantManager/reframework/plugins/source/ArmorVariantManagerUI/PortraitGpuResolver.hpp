#pragma once
#include <windows.h>
#include <d3d12.h>
#include <wrl.h>
#include <cstdint>
#include <cwchar>

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

// Wilds 1.42.0.2 的观察布局，不借用 RE9 偏移；每一层、尺寸、接口与设备都需要再验证。
inline HRESULT resolve(uintptr_t holder, Microsoft::WRL::ComPtr<ID3D12Resource>& result) {
    result.Reset();
    uintptr_t resource{}, texture{}, dx{}, native{};
    uint32_t width{}, height{};
    if (!read(holder + 0x10, resource) || !module_is(resource, false)
        || !read(resource + 0x70, texture) || !module_is(texture, false)
        || !read(texture + 0x38, width) || !read(texture + 0x3c, height) || !valid_size(width, height)
        || !read(texture + 0xf0, dx) || !module_is(dx, false)
        || !read(dx + 0x20, native) || !module_is(native, true)) return E_INVALIDARG;
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
