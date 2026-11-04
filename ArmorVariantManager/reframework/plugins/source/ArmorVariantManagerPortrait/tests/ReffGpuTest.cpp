#include "../PortraitReff.cpp"
#include <d3d12sdklayers.h>
#include <dxgi1_4.h>
#include <fstream>
#include <cstring>
#include <iostream>
#include <vector>

namespace {
using Microsoft::WRL::ComPtr;
void require(bool value,const char* reason){if(!value)throw std::runtime_error(reason);}
void ok(HRESULT hr,const char* reason){require(SUCCEEDED(hr),reason);}
double encode(double x){return x<=.0031308?12.92*x:1.055*std::pow(x,1./2.4)-.055;}
unsigned channel_byte(double x){return unsigned(std::lround(std::clamp(x,0.,1.)*255));}
}

// 生产 provider 直接录制借用命令列表。只有离线夹具执行、等待和回读 GPU。
int main(int argc,char** argv) {
    try {
        require(argc==3,"fixture DLL and pixel artifact path required");
        auto fixture=LoadLibraryA(argv[1]);require(fixture!=nullptr,"load isolated REFF fixture");
        auto active=reinterpret_cast<const REFFPreviewProvider*(*)()>(GetProcAddress(fixture,"preview_fixture_active"));
        auto retired=reinterpret_cast<unsigned(*)()>(GetProcAddress(fixture,"preview_fixture_retired"));
        auto release=reinterpret_cast<void(*)()>(GetProcAddress(fixture,"preview_fixture_release"));
        auto reject=reinterpret_cast<void(*)()>(GetProcAddress(fixture,"preview_fixture_reject"));
        require(active&&retired&&release&&reject&&portrait_reff::available(),"formal API discovery");
        ComPtr<ID3D12Debug> debug;if(SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug))))debug->EnableDebugLayer();
        ComPtr<IDXGIFactory4> factory;ok(CreateDXGIFactory1(IID_PPV_ARGS(&factory)),"factory");
        ComPtr<IDXGIAdapter> adapter;ok(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)),"WARP");
        ComPtr<ID3D12Device> device;ok(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)),"device");
        ComPtr<ID3D12InfoQueue> messages;device.As(&messages);
        ComPtr<ID3D12CommandQueue> queue,other_queue;D3D12_COMMAND_QUEUE_DESC q{};
        ok(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)),"queue");
        ok(device->CreateCommandQueue(&q,IID_PPV_ARGS(&other_queue)),"other queue");
        ComPtr<ID3D12CommandAllocator> allocator;ok(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)),"allocator");
        ComPtr<ID3D12GraphicsCommandList> commands;ok(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&commands)),"commands");
        ComPtr<ID3D12Fence> fence;ok(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&fence)),"fence");
        UINT64 serial=0;
        auto execute=[&] {
            ok(commands->Close(),"close");ID3D12CommandList* lists[]{commands.Get()};queue->ExecuteCommandLists(1,lists);
            ok(queue->Signal(fence.Get(),++serial),"signal");
            auto event=CreateEventW(nullptr,FALSE,FALSE,nullptr);require(event!=nullptr,"event");
            ok(fence->SetEventOnCompletion(serial,event),"completion");auto wait=WaitForSingleObject(event,10000);CloseHandle(event);
            require(wait==WAIT_OBJECT_0,"GPU timeout");release();ok(allocator->Reset(),"reset allocator");ok(commands->Reset(allocator.Get(),nullptr),"reset commands");
        };
        D3D12_HEAP_PROPERTIES gpu{};gpu.Type=D3D12_HEAP_TYPE_DEFAULT;
        unsigned cases=0;
        for(auto format:{DXGI_FORMAT_R8G8B8A8_UNORM,DXGI_FORMAT_B8G8R8A8_UNORM,DXGI_FORMAT_R10G10B10A2_UNORM}) {
            for(bool premult:{false,true}) {
                D3D12_RESOURCE_DESC input{};input.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D;input.Width=220;input.Height=240;
                input.DepthOrArraySize=1;input.MipLevels=1;input.SampleDesc.Count=1;input.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
                ComPtr<ID3D12Resource> image;ok(device->CreateCommittedResource(&gpu,D3D12_HEAP_FLAG_NONE,&input,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(&image)),"image");
                D3D12_PLACED_SUBRESOURCE_FOOTPRINT upload_layout{};UINT64 upload_size{};
                device->GetCopyableFootprints(&input,0,1,0,&upload_layout,nullptr,nullptr,&upload_size);
                auto buffer=[&](UINT64 size,D3D12_HEAP_TYPE type,D3D12_RESOURCE_STATES state) {
                    D3D12_RESOURCE_DESC desc{};desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;desc.Width=size;desc.Height=1;
                    desc.DepthOrArraySize=1;desc.MipLevels=1;desc.SampleDesc.Count=1;desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
                    D3D12_HEAP_PROPERTIES heap{};heap.Type=type;ComPtr<ID3D12Resource> result;
                    ok(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,state,nullptr,IID_PPV_ARGS(&result)),"buffer");return result;
                };
                auto upload=buffer(upload_size,D3D12_HEAP_TYPE_UPLOAD,D3D12_RESOURCE_STATE_GENERIC_READ);
                unsigned char* mapped{};ok(upload->Map(0,nullptr,reinterpret_cast<void**>(&mapped)),"upload map");
                for(unsigned y=0;y<240;++y)for(unsigned x=0;x<220;++x) {
                    const double alpha=x<73?0:x<147?.5:1;
                    const double color[]{.25,.5,.75};auto* pixel=mapped+y*upload_layout.Footprint.RowPitch+x*4;
                    for(unsigned c=0;c<3;++c)pixel[c]=static_cast<unsigned char>(channel_byte(encode(color[c]*(premult?alpha:1))));
                    pixel[3]=static_cast<unsigned char>(channel_byte(alpha));
                }
                upload->Unmap(0,nullptr);
                D3D12_TEXTURE_COPY_LOCATION src{};src.pResource=upload.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;src.PlacedFootprint=upload_layout;
                D3D12_TEXTURE_COPY_LOCATION dst{};dst.pResource=image.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                commands->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
                D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
                barrier.Transition={image.Get(),0,D3D12_RESOURCE_STATE_COPY_DEST,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE};commands->ResourceBarrier(1,&barrier);
                auto output=input;output.Width=256;output.Height=512;output.Format=format;output.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
                const float background[]{.1f,.2f,.3f,1};D3D12_CLEAR_VALUE clear{};clear.Format=format;std::copy(background,background+4,clear.Color);
                ComPtr<ID3D12Resource> target;ok(device->CreateCommittedResource(&gpu,D3D12_HEAP_FLAG_NONE,&output,D3D12_RESOURCE_STATE_RENDER_TARGET,&clear,IID_PPV_ARGS(&target)),"target");
                D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=1;
                ComPtr<ID3D12DescriptorHeap> rtv;ok(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&rtv)),"RTV");
                device->CreateRenderTargetView(target.Get(),nullptr,rtv->GetCPUDescriptorHandleForHeapStart());
                commands->ClearRenderTargetView(rtv->GetCPUDescriptorHandleForHeapStart(),background,0,nullptr);
                if(portrait_reff::update(image.Get(),queue.Get(),premult,true)!=0)throw std::runtime_error(portrait_reff::error());
                auto* first=active()->user;
                require(portrait_reff::update(image.Get(),queue.Get(),premult,true)==0 && active()->user==first && retired()==0,"same texture must renew without replacing provider");
                REFFPreviewDrawContext context{sizeof(context),REFF_PREVIEW_ABI_V1,device.Get(),queue.Get(),commands.Get(),target.Get(),fence.Get(),serial+1,42,
                    static_cast<uint32_t>(format),256,512,{12,10,220,480},{28,25,202,440}};
                active()->draw(active()->user,&context);
                require(!portrait_reff::failed(),"provider draw failed");
                require(portrait_reff::update(image.Get(),queue.Get(),!premult,true)==0 && active()->user!=first && retired()==1,"replacement did not retain in-flight provider");
                auto* replacement=active()->user;
                // 拒绝更新不能转移新 user 所有权，也不能丢掉仍可用的旧实例。
                reject();require(portrait_reff::update(image.Get(),queue.Get(),premult,true)!=0 && active()->user==replacement,"failed update replaced live provider");
                require(portrait_reff::failed() && !portrait_reff::error().empty(),"failed update reason lost");
                portrait_reff::stop();require(!active() && retired()==2 && !portrait_reff::failed(),"stop did not retire or clear fault");
                D3D12_PLACED_SUBRESOURCE_FOOTPRINT read_layout{};UINT64 read_size{};
                device->GetCopyableFootprints(&output,0,1,0,&read_layout,nullptr,nullptr,&read_size);
                auto read=buffer(read_size,D3D12_HEAP_TYPE_READBACK,D3D12_RESOURCE_STATE_COPY_DEST);
                barrier.Transition={target.Get(),0,D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_COPY_SOURCE};commands->ResourceBarrier(1,&barrier);
                src={};src.pResource=target.Get();src.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
                dst={};dst.pResource=read.Get();dst.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;dst.PlacedFootprint=read_layout;commands->CopyTextureRegion(&dst,0,0,0,&src,nullptr);
                execute();require(retired()==0,"completed GPU instances retained");
                ok(read->Map(0,nullptr,reinterpret_cast<void**>(&mapped)),"read map");
                auto pixel=[&](unsigned x,unsigned y) {
                    const auto* p=mapped+y*read_layout.Footprint.RowPitch+x*4;std::array<double,3> value{};
                    if(format==DXGI_FORMAT_R10G10B10A2_UNORM) {uint32_t v{};std::memcpy(&v,p,4);for(unsigned c=0;c<3;++c)value[c]=double((v>>(c*10))&1023)/1023;}
                    else for(unsigned c=0;c<3;++c)value[c]=double(p[format==DXGI_FORMAT_B8G8R8A8_UNORM?2-c:c])/255;
                    return value;
                };
                // 独立的标准曲线期望值；在带边界之外采样，检测裁剪而不是缩放剩余区域。
                for(auto point:{std::array<unsigned,3>{32,100,3},{100,300,1},{210,400,2},{20,100,0},{100,490,0}}) {
                    const double alpha=point[2]==1?128./255:point[2]==2?1:0;const double color[]{.25,.5,.75};const auto actual=pixel(point[0],point[1]);
                    const double studio[]{17./255,24./255,25./255};
                    for(unsigned c=0;c<3;++c)require(std::abs(actual[c]-(encode(color[c])*alpha+(point[2]?studio[c]:background[c])*(1-alpha)))<.015,"SDR/opaque background/tall clip pixel mismatch");
                }
                if(cases==0) {std::ofstream file(argv[2],std::ios::binary);file<<"P6\n256 512\n255\n";
                    for(unsigned y=0;y<512;++y)for(unsigned x=0;x<256;++x)for(double c:pixel(x,y))file.put(static_cast<char>(channel_byte(c)));}
                read->Unmap(0,nullptr);
                require(portrait_reff::update(image.Get(),queue.Get(),premult,true)==0,"restart after failure");
                context.queue=other_queue.Get();active()->draw(active()->user,&context);
                require(portrait_reff::failed() && portrait_reff::error().find("queue")!=std::string::npos,"cross-queue source was silently accepted");
                portrait_reff::stop();release();++cases;
            }
        }
        if(messages)for(UINT64 i=0;i<messages->GetNumStoredMessages();++i) {
            SIZE_T size{};messages->GetMessage(i,nullptr,&size);std::vector<unsigned char> storage(size);
            auto* message=reinterpret_cast<D3D12_MESSAGE*>(storage.data());messages->GetMessage(i,message,&size);
            require(message->Severity>D3D12_MESSAGE_SEVERITY_WARNING,message->pDescription);
        }
        std::cout<<"PASS: "<<cases<<" production REFF provider SDR/alpha/clip cases, borrowed commands, failed update, lease retirement and queue rejection\n";
        return 0;
    }catch(const std::exception& error){std::cerr<<error.what()<<'\n';return 1;}
}
