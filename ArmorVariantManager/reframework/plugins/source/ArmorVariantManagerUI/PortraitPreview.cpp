#include "PortraitGpuResolver.hpp"
#include <dxgi1_6.h>
#include <d3dcompiler.h>
#include <array>
#include <vector>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <cstdio>
#include <cmath>
#include <algorithm>
#include "reframework/API.h"
#include "PortraitPreview.hpp"

using Microsoft::WRL::ComPtr;
namespace {
const REFrameworkPluginInitializeParam* host{};
std::mutex gate;
ComPtr<ID3D12Resource> source;
ULONGLONG heartbeat{};
bool drawing{}, faulted{};
std::string last_error;
bool output_sdr_confirmed{};
// 源透明约定尚待实机对照，默认直通 alpha；可显式选择线性预乘输入作比较。
enum class AlphaMode { Straight, Premultiplied };
AlphaMode alpha_mode{AlphaMode::Straight};
float rectangle[4]{30,190,330,360};
uint64_t drawn{};
#ifdef AVM_PORTRAIT_STANDALONE
constexpr auto log_path = L"D:/Project/差分管理器/Debug/PortraitGpuProbe.native.log";
#endif

// 开发日志仅记录状态变化/故障，不能每帧写图像或文件。
void note(const char* message) {
#ifdef AVM_PORTRAIT_STANDALONE
    FILE* file{};
    if (_wfopen_s(&file, log_path, L"a") == 0 && file) {
        SYSTEMTIME time{}; GetLocalTime(&time);
        fprintf(file,"%02u:%02u:%02u.%03u %s\n",time.wHour,time.wMinute,time.wSecond,time.wMilliseconds,message);
        fclose(file);
    }
#else
    if (host) host->functions->log_info("[AVM Portrait] %s", message);
#endif
}
void check(HRESULT hr, const char* operation) {
    if (FAILED(hr)) { char text[192]{}; snprintf(text,sizeof(text),"%s HRESULT=0x%08X",operation,unsigned(hr)); throw std::runtime_error(text); }
}

// 8 位和高质量颜色的 10 位 SDR 分别适配；真正 HDR/浮点输出仍需独立验证。
DXGI_FORMAT sdr_rtv_format(DXGI_FORMAT format) {
    switch (format) {
    case DXGI_FORMAT_R8G8B8A8_UNORM:
    case DXGI_FORMAT_R8G8B8A8_UNORM_SRGB: return DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
    case DXGI_FORMAT_B8G8R8A8_UNORM:
    case DXGI_FORMAT_B8G8R8A8_UNORM_SRGB: return DXGI_FORMAT_B8G8R8A8_UNORM_SRGB;
    case DXGI_FORMAT_R10G10B10A2_UNORM: return DXGI_FORMAT_R10G10B10A2_UNORM;
    default: throw std::runtime_error("Unsupported output format: HDR/unknown requires explicit color-space validation");
    }
}

struct Frame {
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Resource> backbuffer, sampled;
    ComPtr<ID3D12Resource> background;
    UINT background_width{},background_height{};
    bool background_shader_read{};
    ComPtr<ID3D12DescriptorHeap> srv;
    UINT64 fence{};
};

// 自有命令列表和描述符，直接采样游戏已经用于 GUI 的纹理；不包装/复制/回读该纹理。
class Overlay {
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<IDXGISwapChain3> swapchain;
    ComPtr<ID3D12RootSignature> root;
    std::array<ComPtr<ID3D12PipelineState>,2> pipelines;
    ComPtr<ID3D12DescriptorHeap> rtv;
    ComPtr<ID3D12Fence> fence;
    std::vector<Frame> frames;
    UINT64 submitted{};
    UINT rtv_stride{}, width{}, height{};
    DXGI_FORMAT output_format{};
    bool software_sdr10{};
public:
    // 离线设备不绑定真实显示器，测试可跳过显示器诊断；实机入口始终使用默认检查。
    explicit Overlay(const REFrameworkRendererData& data,bool inspect_display=true) {
        device=static_cast<ID3D12Device*>(data.device);
        queue=static_cast<ID3D12CommandQueue*>(data.command_queue);
        check(static_cast<IDXGISwapChain*>(data.swapchain)->QueryInterface(IID_PPV_ARGS(&swapchain)),"swapchain3");
        DXGI_SWAP_CHAIN_DESC description{}; check(swapchain->GetDesc(&description),"swapchain desc");
        // 输出设备色彩空间仅作诊断，不能误称为交换链当前色彩空间（DXGI 没有该 getter）。
        ComPtr<IDXGIOutput> output; ComPtr<IDXGIOutput6> output6; DXGI_OUTPUT_DESC1 output_desc{};
        bool known_output=inspect_display && SUCCEEDED(swapchain->GetContainingOutput(&output)) && SUCCEEDED(output.As(&output6))
            && SUCCEEDED(output6->GetDesc1(&output_desc));
        char diagnostic[256]{};
        snprintf(diagnostic,sizeof(diagnostic),"OUTPUT buffer_format=%u display_colorspace=%u display_known=%u; engine SDR contract required, monitor HDR does not identify swapchain colorspace",
            unsigned(description.BufferDesc.Format),known_output?unsigned(output_desc.ColorSpace):~0u,unsigned(known_output));
        note(diagnostic);
        output_format=sdr_rtv_format(description.BufferDesc.Format);
        software_sdr10=output_format==DXGI_FORMAT_R10G10B10A2_UNORM;
        if (description.BufferCount < 2 || description.BufferCount > 8) throw std::runtime_error("unsupported buffer count");
        frames.resize(description.BufferCount);
        D3D12_DESCRIPTOR_HEAP_DESC heap{}; heap.NumDescriptors=description.BufferCount; heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;
        check(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&rtv)),"rtv heap");
        rtv_stride=device->GetDescriptorHandleIncrementSize(heap.Type);
        check(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)),"fence");
        for (UINT index=0;index<description.BufferCount;++index) {
            auto& f=frames[index];
            check(swapchain->GetBuffer(index,IID_PPV_ARGS(&f.backbuffer)),"backbuffer");
            auto d=f.backbuffer->GetDesc(); width=UINT(d.Width); height=d.Height;
            // sRGB RTV 在线性空间混合并负责显示编码；shader 不再额外做 gamma，避免双重转换。
            D3D12_RENDER_TARGET_VIEW_DESC target{}; target.Format=output_format; target.ViewDimension=D3D12_RTV_DIMENSION_TEXTURE2D;
            device->CreateRenderTargetView(f.backbuffer.Get(),&target,{rtv->GetCPUDescriptorHandleForHeapStart().ptr+index*rtv_stride});
            check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&f.allocator)),"allocator");
            check(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,f.allocator.Get(),nullptr,IID_PPV_ARGS(&f.commands)),"commands");
            check(f.commands->Close(),"initial close");
            heap={}; heap.NumDescriptors=2; heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV; heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
            check(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&f.srv)),"srv heap");
        }
        D3D12_DESCRIPTOR_RANGE range{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,2,0,0,0};
        D3D12_ROOT_PARAMETER parameters[3]{};
        parameters[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS; parameters[0].Constants={0,0,8}; parameters[0].ShaderVisibility=D3D12_SHADER_VISIBILITY_VERTEX;
        parameters[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE; parameters[1].DescriptorTable={1,&range}; parameters[1].ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        parameters[2].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS; parameters[2].Constants={1,0,2}; parameters[2].ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_STATIC_SAMPLER_DESC sampler{}; sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.ComparisonFunc=D3D12_COMPARISON_FUNC_ALWAYS; sampler.MaxLOD=D3D12_FLOAT32_MAX; sampler.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC signature{}; signature.NumParameters=3; signature.pParameters=parameters; signature.NumStaticSamplers=1; signature.pStaticSamplers=&sampler;
        ComPtr<ID3DBlob> blob,error;
        check(D3D12SerializeRootSignature(&signature,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&error),"root serialize");
        check(device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)),"root create");
        const char* shader=R"(
cbuffer Bounds:register(b0){float4 bounds;float4 uvBounds;}
struct Pixel{float4 position:SV_POSITION;float2 uv:TEXCOORD;};
Pixel vs(uint vertex:SV_VertexID){
float2 coordinates[6]={float2(0,0),float2(1,0),float2(0,1),float2(1,0),float2(1,1),float2(0,1)};
Pixel p;float2 local=coordinates[vertex];p.uv=uvBounds.xy+local*uvBounds.zw;p.position=float4(bounds.xy+local*bounds.zw,0,1);return p;}
Texture2D image:register(t0);SamplerState linearClamp:register(s0);
Texture2D background:register(t1);cbuffer Tile:register(b1){int2 tileOrigin;}
float3 decodeSDR(float3 v){return lerp(v/12.92,pow((v+.055)/1.055,2.4),step(.04045,v));}
float3 encodeSDR(float3 v){v=max(v,0);return lerp(v*12.92,1.055*pow(v,1./2.4)-.055,step(.0031308,v));}
float4 ps(Pixel p):SV_TARGET{
float4 c=image.Sample(linearClamp,p.uv);if(c.a<=0)c.rgb=0;
#if SOFTWARE_SDR10
float4 b=background.Load(int3(int2(p.position.xy)-tileOrigin,0));
if(c.a<=0)return b;
#if PREMULTIPLIED_INPUT
float3 foreground=c.rgb;
#else
float3 foreground=c.rgb*c.a;
#endif
return float4(encodeSDR(foreground+decodeSDR(b.rgb)*(1-c.a)),c.a+b.a*(1-c.a));
#else
return c;
#endif
}
)";
        ComPtr<ID3DBlob> vs,ps;
        check(D3DCompile(shader,strlen(shader),nullptr,nullptr,nullptr,"vs","vs_5_0",0,0,&vs,&error),"vertex shader");
        D3D12_GRAPHICS_PIPELINE_STATE_DESC pso{}; pso.pRootSignature=root.Get();
        pso.VS={vs->GetBufferPointer(),vs->GetBufferSize()};
        pso.BlendState.RenderTarget[0].RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        pso.BlendState.RenderTarget[0].BlendEnable=TRUE;
        pso.BlendState.RenderTarget[0].SrcBlend=D3D12_BLEND_SRC_ALPHA;
        pso.BlendState.RenderTarget[0].SrcBlendAlpha=D3D12_BLEND_ONE;
        pso.BlendState.RenderTarget[0].DestBlend=pso.BlendState.RenderTarget[0].DestBlendAlpha=D3D12_BLEND_INV_SRC_ALPHA;
        pso.BlendState.RenderTarget[0].BlendOp=pso.BlendState.RenderTarget[0].BlendOpAlpha=D3D12_BLEND_OP_ADD;
        pso.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_ALWAYS;
        // 标准直通输入与线性预乘输入分别使用匹配的混合系数，源纹理始终只读。
        pso.SampleMask=UINT_MAX; pso.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID; pso.RasterizerState.CullMode=D3D12_CULL_MODE_NONE; pso.RasterizerState.DepthClipEnable=TRUE;
        pso.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE; pso.NumRenderTargets=1;
        pso.RTVFormats[0]=output_format; pso.SampleDesc.Count=1;
        for(unsigned mode=0;mode<2;++mode) {
            D3D_SHADER_MACRO definitions[]{{"SOFTWARE_SDR10",software_sdr10?"1":"0"},{"PREMULTIPLIED_INPUT",mode?"1":"0"},{nullptr,nullptr}};
            check(D3DCompile(shader,strlen(shader),nullptr,definitions,nullptr,"ps","ps_5_0",0,0,&ps,&error),"pixel shader");
            pso.PS={ps->GetBufferPointer(),ps->GetBufferSize()};
            pso.BlendState.RenderTarget[0].BlendEnable=software_sdr10?FALSE:TRUE;
            pso.BlendState.RenderTarget[0].SrcBlend=mode?D3D12_BLEND_ONE:D3D12_BLEND_SRC_ALPHA;
            check(device->CreateGraphicsPipelineState(&pso,IID_PPV_ARGS(&pipelines[mode])),"SDR alpha pipeline");
        }
        note("OVERLAY INITIALIZED: separate native D3D12; no PNG/readback/native GUI changes");
    }

    // 不等待未完成的帧：忙则跳过，禁止超时后重置仍在 GPU 使用的分配器/描述符。
    bool render(ID3D12Resource* image,const float* rect,AlphaMode mode=AlphaMode::Straight) {
        auto index=swapchain->GetCurrentBackBufferIndex();
        auto& f=frames.at(index);
        if (f.fence && fence->GetCompletedValue()<f.fence) return false;
        const UINT left=UINT(std::clamp(std::floor(double(rect[0])),0.,double(width)));
        const UINT top=UINT(std::clamp(std::floor(double(rect[1])),0.,double(height)));
        const UINT right=UINT(std::clamp(std::ceil(double(rect[0])+rect[2]),0.,double(width)));
        const UINT bottom=UINT(std::clamp(std::ceil(double(rect[1])+rect[3]),0.,double(height)));
        if(right<=left || bottom<=top)return false;
        ComPtr<ID3D12Device> owner; check(image->GetDevice(IID_PPV_ARGS(&owner)),"texture device");
        if (owner.Get()!=device.Get()) throw std::runtime_error("texture belongs to different device");
        check(device->GetDeviceRemovedReason(),"device health");
        f.sampled=image;
        auto d=image->GetDesc();
        D3D12_SHADER_RESOURCE_VIEW_DESC view{}; view.Format=d.Format==DXGI_FORMAT_R8G8B8A8_TYPELESS?DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:d.Format;
        view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D; view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING; view.Texture2D.MipLevels=1;
        device->CreateShaderResourceView(image,&view,f.srv->GetCPUDescriptorHandleForHeapStart());
        auto second=f.srv->GetCPUDescriptorHandleForHeapStart();
        second.ptr+=device->GetDescriptorHandleIncrementSize(D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV);
        if(software_sdr10) {
            // 10 位格式没有 sRGB RTV：仅把覆盖区底色复制到自有 GPU 纹理，在线性空间合成后编码。
            // 相机纹理仍原位直接采样；没有 CPU 回读、磁盘图像或整屏复制。
            if(!f.background || f.background_width!=right-left || f.background_height!=bottom-top) {
                D3D12_RESOURCE_DESC tile{};tile.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;
                tile.Width=right-left;tile.Height=bottom-top;tile.DepthOrArraySize=1;tile.MipLevels=1;
                tile.Format=output_format;tile.SampleDesc.Count=1;
                D3D12_HEAP_PROPERTIES memory{};memory.Type=D3D12_HEAP_TYPE_DEFAULT;
                check(device->CreateCommittedResource(&memory,D3D12_HEAP_FLAG_NONE,&tile,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(&f.background)),"SDR10 background tile");
                f.background_width=right-left;f.background_height=bottom-top;f.background_shader_read=false;
            }
            D3D12_SHADER_RESOURCE_VIEW_DESC tile_view{};tile_view.Format=output_format;
            tile_view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;tile_view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;tile_view.Texture2D.MipLevels=1;
            device->CreateShaderResourceView(f.background.Get(),&tile_view,second);
        } else device->CreateShaderResourceView(image,&view,second);
        check(f.allocator->Reset(),"allocator reset"); check(f.commands->Reset(f.allocator.Get(),pipelines.at(size_t(mode)).Get()),"commands reset");
        auto* command=f.commands.Get();
        D3D12_RESOURCE_BARRIER barrier{}; barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition={f.backbuffer.Get(),D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_PRESENT,
            software_sdr10?D3D12_RESOURCE_STATE_COPY_SOURCE:D3D12_RESOURCE_STATE_RENDER_TARGET};
        command->ResourceBarrier(1,&barrier);
        if(software_sdr10) {
            D3D12_RESOURCE_BARRIER tile_barrier{};tile_barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
            tile_barrier.Transition={f.background.Get(),D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE,D3D12_RESOURCE_STATE_COPY_DEST};
            if(f.background_shader_read)command->ResourceBarrier(1,&tile_barrier);
            D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=f.backbuffer.Get();from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            to.pResource=f.background.Get();to.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            D3D12_BOX box{left,top,0,right,bottom,1};command->CopyTextureRegion(&to,0,0,0,&from,&box);
            std::swap(tile_barrier.Transition.StateBefore,tile_barrier.Transition.StateAfter);command->ResourceBarrier(1,&tile_barrier);
            f.background_shader_read=true;
            barrier.Transition.StateBefore=D3D12_RESOURCE_STATE_COPY_SOURCE;barrier.Transition.StateAfter=D3D12_RESOURCE_STATE_RENDER_TARGET;
            command->ResourceBarrier(1,&barrier);
        }
        // 源只读，假设 Present 时已处于原生 GUI 的 shader-read 状态；需游戏实际直绘验证。
        D3D12_CPU_DESCRIPTOR_HANDLE target{rtv->GetCPUDescriptorHandleForHeapStart().ptr+index*rtv_stride};
        command->OMSetRenderTargets(1,&target,FALSE,nullptr);
        D3D12_VIEWPORT viewport{0,0,float(width),float(height),0,1}; D3D12_RECT clip{0,0,LONG(width),LONG(height)};
        command->RSSetViewports(1,&viewport); command->RSSetScissorRects(1,&clip);
        command->SetGraphicsRootSignature(root.Get());
        // 相机投影由 RT 尺寸决定；按真实源宽高比等比填充视口，只裁切溢出部分，不拉伸人物。
        const float aspect_ratio=(float(d.Width)/d.Height)/(rect[2]/rect[3]);
        const float u_span=(std::min)(1.f,1.f/aspect_ratio),v_span=(std::min)(1.f,aspect_ratio);
        float bounds[]{2*rect[0]/width-1,1-2*rect[1]/height,2*rect[2]/width,-2*rect[3]/height,
            (1-u_span)*.5f,(1-v_span)*.5f,u_span,v_span};
        command->SetGraphicsRoot32BitConstants(0,8,bounds,0);
        const UINT origin[]{left,top};command->SetGraphicsRoot32BitConstants(2,2,origin,0);
        ID3D12DescriptorHeap* heaps[]{f.srv.Get()}; command->SetDescriptorHeaps(1,heaps);
        command->SetGraphicsRootDescriptorTable(1,f.srv->GetGPUDescriptorHandleForHeapStart()); command->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);
        command->DrawInstanced(6,1,0,0);
        barrier.Transition.StateBefore=D3D12_RESOURCE_STATE_RENDER_TARGET;barrier.Transition.StateAfter=D3D12_RESOURCE_STATE_PRESENT;command->ResourceBarrier(1,&barrier);
        check(command->Close(),"commands close"); ID3D12CommandList* lists[]{command};
        // 提交后 Signal 也可能失败；先标记未知完成，禁止按上一帧 fence 回收在途纹理。
        f.fence=UINT64_MAX;
        queue->ExecuteCommandLists(1,lists);
        check(queue->Signal(fence.Get(),++submitted),"queue signal"); f.fence=submitted; return true;
    }
    // 停止/过期时回收已完成帧的采样引用，未完成帧继续持有，避免场景切换悬空。
    void reclaim() {
        auto completed=fence->GetCompletedValue();
        for (auto& f:frames) if (!f.fence || completed>=f.fence) f.sampled.Reset();
    }
    // 设备重置前必须等自有提交完成；不能直接释放飞行中的纹理/堆。
    bool drain() {
        if (!submitted || fence->GetCompletedValue()>=submitted || FAILED(device->GetDeviceRemovedReason())) return true;
        HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr); if (!event) return false;
        auto hr=fence->SetEventOnCompletion(submitted,event);
        auto waited=SUCCEEDED(hr)?WaitForSingleObject(event,2000):WAIT_FAILED; CloseHandle(event);
        return waited==WAIT_OBJECT_0;
    }
};
std::unique_ptr<Overlay> overlay;

// 仅在 REFramework Present 回调提交独立列表，不替换外置/内置 d2d，也不安装图形钩子。
void on_present() {
    std::scoped_lock lock(gate);
    if (overlay) overlay->reclaim();
    if (drawing && GetTickCount64()-heartbeat>500) { drawing=false; source.Reset(); }
    if (!host || !output_sdr_confirmed || faulted || !drawing || !source || GetTickCount64()-heartbeat>500) return;
    try {
        if (!overlay) overlay=std::make_unique<Overlay>(*host->renderer_data);
        if (overlay->render(source.Get(),rectangle,alpha_mode)) ++drawn;
    } catch(const std::exception& error) { faulted=true; drawing=false; source.Reset(); last_error=error.what(); note(error.what()); }
}
void on_reset() {
    std::scoped_lock lock(gate); drawing=false; source.Reset(); heartbeat=0;
    if (overlay && !overlay->drain()) { faulted=true; last_error="RESET GPU timeout; keeping resources alive, no more drawing"; note(last_error.c_str()); return; }
    overlay.reset(); faulted=false; last_error.clear(); note("DEVICE RESET: preview disabled");
}
}

// 当前游戏可热加载的只读验证入口；查询成功才返回描述，临时 COM 引用自动释放。
extern "C" __declspec(dllexport) int portrait_gpu_inspect(uintptr_t holder,char* output,unsigned capacity) {
    if (!output || capacity<2) return int(E_INVALIDARG);
    try {
        ComPtr<ID3D12Resource> image; auto hr=portrait_gpu::resolve(holder,image);
        if (FAILED(hr)) { snprintf(output,capacity,"resolve failed HRESULT=0x%08X",unsigned(hr)); return int(hr); }
        auto d=image->GetDesc(); ComPtr<ID3D12Device> device; check(image->GetDevice(IID_PPV_ARGS(&device)),"inspect device");
        snprintf(output,capacity,"VERIFIED ID3D12Resource=%p device=%p width=%llu height=%u format=%u flags=%u sample=%u",image.Get(),device.Get(),d.Width,d.Height,unsigned(d.Format),unsigned(d.Flags),d.SampleDesc.Count);
        return 0;
    } catch(const std::exception& error) { snprintf(output,capacity,"inspect exception: %s",error.what()); return int(E_FAIL); }
}

// 主线程刷新已验证 holder 与短心跳；默认不开启，stop 和失活只清理本模块引用。
extern "C" __declspec(dllexport) int portrait_gpu_update(uintptr_t holder,int enabled,float x,float y,float w,float h) {
    std::scoped_lock lock(gate);
    if (!enabled) { drawing=false; source.Reset(); heartbeat=0; return 0; }
    if (!host) return int(E_PENDING);
    if (!output_sdr_confirmed) return int(E_PENDING);
    if (faulted) return int(E_FAIL);
    if (!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(w)||!std::isfinite(h)||w<1||h<1||w>4096||h>4096) return int(E_INVALIDARG);
    ComPtr<ID3D12Resource> image; auto hr=portrait_gpu::resolve(holder,image); if (FAILED(hr)) { drawing=false; source.Reset(); return int(hr); }
    source=std::move(image); heartbeat=GetTickCount64(); drawing=true; rectangle[0]=x;rectangle[1]=y;rectangle[2]=w;rectangle[3]=h; return 0;
}
// 绘制线程仅更新矩形，不解析引擎对象、不延长资源心跳；与面板同帧移动。
extern "C" __declspec(dllexport) int portrait_gpu_rectangle(float x,float y,float w,float h) {
    if (!std::isfinite(x)||!std::isfinite(y)||!std::isfinite(w)||!std::isfinite(h)||w<1||h<1||w>4096||h>4096) return int(E_INVALIDARG);
    std::scoped_lock lock(gate);
    if(drawing){rectangle[0]=x;rectangle[1]=y;rectangle[2]=w;rectangle[3]=h;}
    return 0;
}
extern "C" __declspec(dllexport) unsigned long long portrait_gpu_drawn() { std::scoped_lock lock(gate); return drawn; }
extern "C" __declspec(dllexport) int portrait_gpu_ready() { return host?1:0; }
extern "C" __declspec(dllexport) int portrait_gpu_color_version() { return 4; }
// Lua 只读取可复制的状态；错误字符串为当前线程副本，不向脚本暴露资源指针。
extern "C" __declspec(dllexport) int portrait_gpu_state() {
    std::scoped_lock lock(gate);
    return faulted?-1:!host?0:!output_sdr_confirmed?3:drawing?2:1;
}
extern "C" __declspec(dllexport) const char* portrait_gpu_error() {
    thread_local std::string copy;
    std::scoped_lock lock(gate); copy=last_error; return copy.c_str();
}

// 来自游戏 Renderer 的只读 getter；HDR 显示器与游戏输出模式必须分开，未知或真正 HDR 停绘。
extern "C" __declspec(dllexport) int portrait_gpu_set_output_contract(int hdr,int color_space) {
    std::scoped_lock lock(gate);
    const bool supported=hdr==0 && color_space==1;
    if(output_sdr_confirmed!=supported)note(supported?"ENGINE OUTPUT confirmed SDR sRGB":"ENGINE OUTPUT unsupported/unknown; preview disabled");
    output_sdr_confirmed=supported;
    if(!supported){drawing=false;source.Reset();heartbeat=0;return int(E_NOTIMPL);}
    return 0;
}

// 仅切换本模块混合管线，不修改游戏材质、相机、曝光或配置文件。
extern "C" __declspec(dllexport) int portrait_gpu_set_alpha_mode(int mode) {
    if (mode<0 || mode>1) return int(E_INVALIDARG);
    std::scoped_lock lock(gate);
    const auto next=static_cast<AlphaMode>(mode);
    if(alpha_mode!=next) {
        alpha_mode=next;
        note(mode==0?"ALPHA straight":"ALPHA linear-premultiplied (explicit comparison)");
    }
    return 0;
}

// 正式插件共享现有初始化入口，离线探针使用同一份实现，避免两套渲染器漂移。
bool avm_portrait_initialize(const REFrameworkPluginInitializeParam* param) {
    if (!param || !param->renderer_data || param->renderer_data->renderer_type!=REFRAMEWORK_RENDERER_D3D12) return false;
    host=param;
    if (!param->functions->on_present(on_present)||!param->functions->on_device_reset(on_reset)) { host=nullptr; return false; }
    note("PLUGIN INITIALIZED idle; explicit draw heartbeat required"); return true;
}
#ifdef AVM_PORTRAIT_STANDALONE
extern "C" __declspec(dllexport) void reframework_plugin_required_version(REFrameworkPluginVersion* version) {
    version->major=REFRAMEWORK_PLUGIN_VERSION_MAJOR;version->minor=REFRAMEWORK_PLUGIN_VERSION_MINOR;version->patch=REFRAMEWORK_PLUGIN_VERSION_PATCH;version->game_name=nullptr;
}
extern "C" __declspec(dllexport) bool reframework_plugin_initialize(const REFrameworkPluginInitializeParam* param) {
    return avm_portrait_initialize(param);
}
#endif
