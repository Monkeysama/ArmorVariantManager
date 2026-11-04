#include "PortraitReff.hpp"
#include "reff/native_preview.h"
#include <Windows.h>
#include <wrl/client.h>
#include <d3dcompiler.h>
#include <atomic>
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <mutex>
#include <stdexcept>

namespace portrait_reff {
namespace {
using Microsoft::WRL::ComPtr;
const REFFNativePreviewAPI* api{};
REFFPreviewHandle handle{};
struct Status {
    std::atomic<ULONGLONG> expires{};
    std::atomic<uint64_t> draws{};
    std::atomic<bool> fault{};
    std::mutex gate;
    std::string message;
    void fail(const char* reason) {
        std::scoped_lock lock(gate);
        message=reason; fault=true;
    }
};
auto status=std::make_shared<Status>();
ComPtr<ID3D12Resource> current_image;
ID3D12CommandQueue* current_queue{};
bool current_premultiplied{},current_sdr10{};
uint64_t previous_draws{};

void check(HRESULT hr,const char* operation) {
    if(FAILED(hr)) throw std::runtime_error(std::string(operation)+" HRESULT="+std::to_string(unsigned(hr)));
}

// 每次纹理/设备变化都替换整个实例；REFF 在最后一次 GPU fence 后才释放旧实例。
struct Surface {
    std::shared_ptr<Status> lease;
    ComPtr<ID3D12Resource> image;
    ComPtr<ID3D12CommandQueue> producer;
    ComPtr<ID3D12Device> device;
    ComPtr<ID3D12RootSignature> root;
    ComPtr<ID3D12DescriptorHeap> srv,rtv;
    ComPtr<ID3DBlob> vertex,pixel;
    std::array<ComPtr<ID3D12PipelineState>,3> pipelines;
    bool premultiplied;

    Surface(std::shared_ptr<Status> state,ID3D12Resource* texture,ID3D12CommandQueue* queue,bool premult)
        :lease(std::move(state)),image(texture),producer(queue),premultiplied(premult) {
        check(image->GetDevice(IID_PPV_ARGS(&device)),"preview texture device");
        initialize();
        for(const auto format:{DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_R10G10B10A2_UNORM})pipeline(format);
        vertex.Reset();pixel.Reset();
    }

    void initialize() {
        D3D12_DESCRIPTOR_HEAP_DESC heap{};heap.NumDescriptors=1;
        heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_CBV_SRV_UAV;heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_SHADER_VISIBLE;
        check(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&srv)),"preview SRV heap");
        heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;heap.Flags=D3D12_DESCRIPTOR_HEAP_FLAG_NONE;
        check(device->CreateDescriptorHeap(&heap,IID_PPV_ARGS(&rtv)),"preview RTV heap");
        const auto source=image->GetDesc();
        if(source.Dimension!=D3D12_RESOURCE_DIMENSION_TEXTURE2D || source.SampleDesc.Count!=1 || source.DepthOrArraySize!=1)
            throw std::runtime_error("REFF preview requires a single-sample 2D camera texture");
        D3D12_SHADER_RESOURCE_VIEW_DESC view{};
        view.Format=source.Format==DXGI_FORMAT_R8G8B8A8_TYPELESS?DXGI_FORMAT_R8G8B8A8_UNORM_SRGB:source.Format;
        view.ViewDimension=D3D12_SRV_DIMENSION_TEXTURE2D;view.Shader4ComponentMapping=D3D12_DEFAULT_SHADER_4_COMPONENT_MAPPING;
        view.Texture2D.MipLevels=1;device->CreateShaderResourceView(image.Get(),&view,srv->GetCPUDescriptorHandleForHeapStart());
        D3D12_DESCRIPTOR_RANGE range{D3D12_DESCRIPTOR_RANGE_TYPE_SRV,1,0,0,0};
        D3D12_ROOT_PARAMETER params[2]{};
        params[0].ParameterType=D3D12_ROOT_PARAMETER_TYPE_32BIT_CONSTANTS;params[0].Constants={0,0,5};
        params[1].ParameterType=D3D12_ROOT_PARAMETER_TYPE_DESCRIPTOR_TABLE;params[1].DescriptorTable={1,&range};
        D3D12_STATIC_SAMPLER_DESC sampler{};sampler.Filter=D3D12_FILTER_MIN_MAG_MIP_LINEAR;
        sampler.AddressU=sampler.AddressV=sampler.AddressW=D3D12_TEXTURE_ADDRESS_MODE_CLAMP;
        sampler.MaxLOD=D3D12_FLOAT32_MAX;sampler.ShaderVisibility=D3D12_SHADER_VISIBILITY_PIXEL;
        D3D12_ROOT_SIGNATURE_DESC desc{2,params,1,&sampler,D3D12_ROOT_SIGNATURE_FLAG_ALLOW_INPUT_ASSEMBLER_INPUT_LAYOUT};
        ComPtr<ID3DBlob> blob,errors;
        check(D3D12SerializeRootSignature(&desc,D3D_ROOT_SIGNATURE_VERSION_1,&blob,&errors),"preview root signature");
        check(device->CreateRootSignature(0,blob->GetBufferPointer(),blob->GetBufferSize(),IID_PPV_ARGS(&root)),"preview root");
    }

    ID3D12PipelineState* pipeline(DXGI_FORMAT format) {
        const size_t index=format==DXGI_FORMAT_R8G8B8A8_UNORM?0:format==DXGI_FORMAT_B8G8R8A8_UNORM?1:
            format==DXGI_FORMAT_R10G10B10A2_UNORM?2:3;
        if(index==3)throw std::runtime_error("REFF preview output is not supported SDR");
        auto& result=pipelines[index];if(result)return result.Get();
        constexpr char shader[]=R"(
cbuffer Settings:register(b0){float4 crop;float premult;}
Texture2D<float4> image:register(t0);SamplerState linearClamp:register(s0);
struct Vertex{float4 position:SV_Position;float2 uv:TEXCOORD0;};
Vertex vs(uint id:SV_VertexID){float2 uv=float2((id<<1)&2,id&2);Vertex v;
v.position=float4(uv.x*2-1,1-uv.y*2,0,1);v.uv=crop.xy+uv*crop.zw;return v;}
float3 encode(float3 x){x=max(x,0);return lerp(12.92*x,1.055*pow(x,1.0/2.4)-.055,step(.0031308,x));}
float4 ps(Vertex v):SV_Target{float4 c=image.Sample(linearClamp,v.uv);float a=saturate(c.a);
float3 rgb=premult>.5?(a>0?c.rgb/a:0):c.rgb;return float4(encode(rgb)*a,a);}
)";
        auto compile=[&](const char* entry,const char* target,ComPtr<ID3DBlob>& output) {
            ComPtr<ID3DBlob> errors;
            const auto hr=D3DCompile(shader,sizeof(shader),nullptr,nullptr,nullptr,entry,target,0,0,&output,&errors);
            if(FAILED(hr) && errors)throw std::runtime_error(std::string("preview shader: ")+static_cast<const char*>(errors->GetBufferPointer()));
            check(hr,"preview shader");
        };
        if(!vertex)compile("vs","vs_5_0",vertex);
        if(!pixel)compile("ps","ps_5_0",pixel);
        D3D12_GRAPHICS_PIPELINE_STATE_DESC p{};p.pRootSignature=root.Get();
        p.VS={vertex->GetBufferPointer(),vertex->GetBufferSize()};p.PS={pixel->GetBufferPointer(),pixel->GetBufferSize()};
        auto& blend=p.BlendState.RenderTarget[0];blend.BlendEnable=TRUE;
        blend.SrcBlend=D3D12_BLEND_ONE;blend.DestBlend=D3D12_BLEND_INV_SRC_ALPHA;blend.BlendOp=D3D12_BLEND_OP_ADD;
        blend.SrcBlendAlpha=D3D12_BLEND_ONE;blend.DestBlendAlpha=D3D12_BLEND_INV_SRC_ALPHA;blend.BlendOpAlpha=D3D12_BLEND_OP_ADD;
        blend.RenderTargetWriteMask=D3D12_COLOR_WRITE_ENABLE_ALL;
        p.SampleMask=UINT_MAX;p.RasterizerState.FillMode=D3D12_FILL_MODE_SOLID;p.RasterizerState.CullMode=D3D12_CULL_MODE_NONE;
        p.DepthStencilState.DepthFunc=D3D12_COMPARISON_FUNC_ALWAYS;
        p.RasterizerState.DepthClipEnable=TRUE;p.PrimitiveTopologyType=D3D12_PRIMITIVE_TOPOLOGY_TYPE_TRIANGLE;
        p.NumRenderTargets=1;p.RTVFormats[0]=format;p.SampleDesc.Count=1;
        check(device->CreateGraphicsPipelineState(&p,IID_PPV_ARGS(&result)),"preview pipeline");return result.Get();
    }

    static void __cdecl record(void* user,const REFFPreviewDrawContext* c) noexcept {
        auto& self=*static_cast<Surface*>(user);
        if(self.lease->fault || GetTickCount64()>self.lease->expires)return;
        try {
            if(c->device!=self.device.Get() || c->queue!=self.producer.Get())
                throw std::runtime_error("REFF preview device/producer queue changed; renew the camera texture");
            auto* state=self.pipeline(static_cast<DXGI_FORMAT>(c->target_format));
            const auto& r=c->destination;const auto& clip=c->clip;
            const auto source=self.image->GetDesc();
            const float aspect=(float(source.Width)/source.Height)/(r.width/r.height);
            const float u=(std::min)(1.f,1.f/aspect),v=(std::min)(1.f,aspect);
            const float constants[]{(1-u)*.5f,(1-v)*.5f,u,v,self.premultiplied?1.f:0.f};
            self.device->CreateRenderTargetView(c->target,nullptr,self.rtv->GetCPUDescriptorHandleForHeapStart());
            const auto target=self.rtv->GetCPUDescriptorHandleForHeapStart();
            c->commands->OMSetRenderTargets(1,&target,FALSE,nullptr);
            D3D12_VIEWPORT viewport{r.x,r.y,r.width,r.height,0,1};
            D3D12_RECT scissor{LONG(std::ceil(clip.x)),LONG(std::ceil(clip.y)),LONG(std::floor(clip.x+clip.width)),LONG(std::floor(clip.y+clip.height))};
            c->commands->RSSetViewports(1,&viewport);c->commands->RSSetScissorRects(1,&scissor);
            c->commands->SetPipelineState(state);c->commands->SetGraphicsRootSignature(self.root.Get());
            ID3D12DescriptorHeap* heaps[]{self.srv.Get()};c->commands->SetDescriptorHeaps(1,heaps);
            c->commands->SetGraphicsRoot32BitConstants(0,5,constants,0);
            c->commands->SetGraphicsRootDescriptorTable(1,self.srv->GetGPUDescriptorHandleForHeapStart());
            c->commands->IASetPrimitiveTopology(D3D_PRIMITIVE_TOPOLOGY_TRIANGLELIST);c->commands->DrawInstanced(3,1,0,0);
            ++self.lease->draws;
        } catch(const std::exception& e) { self.lease->fail(e.what()); }
    }
    static void __cdecl release(void* user) { delete static_cast<Surface*>(user); }
};
}

bool available() {
    const auto module=GetModuleHandleW(L"REFF.dll");
    const auto get=module?reinterpret_cast<REFFGetNativePreviewAPI>(GetProcAddress(module,"reff_get_native_preview_api")):nullptr;
    const auto* candidate=get?get(REFF_PREVIEW_ABI_V1):nullptr;
    constexpr unsigned required=REFF_PREVIEW_CAP_DX12_CALLBACK|REFF_PREVIEW_CAP_UNDERLAY|REFF_PREVIEW_CAP_SDR8;
    if(!candidate || candidate->size<sizeof(*candidate) || candidate->abi_version!=REFF_PREVIEW_ABI_V1 ||
        (candidate->capabilities&required)!=required)return false;
    api=candidate;return true;
}

int update(ID3D12Resource* image,ID3D12CommandQueue* producer,bool premultiplied,bool sdr10) {
    if(!available())return int(E_NOTIMPL);
    if(handle && status->fault)return int(E_FAIL);
    const auto expires=GetTickCount64()+500;
    if(handle && current_image.Get()==image && current_queue==producer && current_premultiplied==premultiplied && current_sdr10==sdr10) {
        status->expires=expires;return 0;
    }
    try {
        if(!handle){previous_draws+=status->draws;status=std::make_shared<Status>();}
        status->expires=expires;
        auto next=std::make_unique<Surface>(status,image,producer,premultiplied);
        REFFPreviewProvider provider{sizeof(provider),"monkeysama.avm","portrait",next.get(),&Surface::record,&Surface::release,
            sdr10?REFF_PREVIEW_SDR10_CONFIRMED:0u};
        if(handle) { if(!api->update_provider(handle,&provider))throw std::runtime_error("REFF rejected preview provider update"); }
        else { handle=api->register_provider(&provider);if(!handle)throw std::runtime_error("REFF rejected preview provider registration"); }
        next.release();current_image=image;current_queue=producer;current_premultiplied=premultiplied;current_sdr10=sdr10;return 0;
    } catch(const std::exception& e) { status->fail(e.what());return int(E_FAIL); }
}
void stop() {
    if(!handle && !current_image && !status->fault)return;
    status->expires=0;
    if(handle){api->unregister_provider(handle);handle=0;}
    previous_draws+=status->draws;
    status=std::make_shared<Status>();
    current_image.Reset();current_queue=nullptr;
}
bool failed(){return status->fault;}
std::string error(){std::scoped_lock lock(status->gate);return status->message;}
uint64_t drawn(){return previous_draws+status->draws;}
}
