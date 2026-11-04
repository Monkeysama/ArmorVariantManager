#pragma once
#include <cstdint>
#include "reframework/API.h"

// 独立预览与现有 D2D 共存；只在 Present 使用自有 GPU 资源，不接管原生 GUI。
bool avm_portrait_initialize(const REFrameworkPluginInitializeParam* param);
extern "C" {
// 0：自动 Present；1：内嵌 D2D；2：REFF 正式合成回调。
__declspec(dllexport) int portrait_gpu_present_mode();
__declspec(dllexport) void avm_portrait_present_hosted();
__declspec(dllexport) int portrait_gpu_update(uintptr_t holder, int enabled, float x, float y, float w, float h);
__declspec(dllexport) int portrait_gpu_rectangle(float x, float y, float w, float h);
__declspec(dllexport) int portrait_gpu_set_output_contract(int hdr, int color_space);
__declspec(dllexport) int portrait_gpu_set_alpha_mode(int mode);
__declspec(dllexport) int portrait_gpu_reff_ready();
__declspec(dllexport) int portrait_gpu_set_reff(int enabled);
__declspec(dllexport) int portrait_gpu_color_version();
__declspec(dllexport) int portrait_gpu_ready();
__declspec(dllexport) int portrait_gpu_state();
__declspec(dllexport) const char* portrait_gpu_error();
__declspec(dllexport) unsigned long long portrait_gpu_drawn();
}
