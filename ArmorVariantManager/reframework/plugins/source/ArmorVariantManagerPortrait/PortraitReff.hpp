#pragma once
#include <d3d12.h>
#include <cstdint>
#include <string>

// REFF 仅承接合成；相机纹理及其生产队列仍由 AVM 持有。
namespace portrait_reff {
bool available();
int update(ID3D12Resource* image, ID3D12CommandQueue* producer, bool premultiplied, bool sdr10);
void stop();
bool failed();
std::string error();
uint64_t drawn();
}
