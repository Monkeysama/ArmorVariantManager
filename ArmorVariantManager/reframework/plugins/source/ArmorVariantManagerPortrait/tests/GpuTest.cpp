#include "../PortraitPreview.cpp"
#include <d3d12sdklayers.h>
#include <iostream>
#include <algorithm>
#include <cstring>
#include <string>
namespace { int log_count{}; void record_log(const char*, ...) { ++log_count; } }

// 使用独立的标准 sRGB 曲线推导像素期望值，不以渲染器输出反推测试基准。
double encode_srgb(double v) { return v<=.0031308?12.92*v:1.055*std::pow(v,1./2.4)-.055; }
double decode_srgb(double v) { return v<=.04045?v/12.92:std::pow((v+.055)/1.055,2.4); }
int byte_value(double v) { return int(std::lround(std::clamp(v,0.,1.)*255.)); }

// RTSS 会自动注入普通进程并修改交换链；仅测试子进程禁止第三方 DLL，不改 RTSS/游戏配置。
int isolated_validation() {
    wchar_t path[32768]{};if(!GetModuleFileNameW(nullptr,path,32768))return 2;
    std::wstring command=GetCommandLineW();command+=L" --isolated-validation";
    SIZE_T bytes{};InitializeProcThreadAttributeList(nullptr,1,0,&bytes);
    std::vector<unsigned char> storage(bytes);STARTUPINFOEXW startup{};startup.StartupInfo.cb=sizeof(startup);
    startup.lpAttributeList=reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(storage.data());
    if(!InitializeProcThreadAttributeList(startup.lpAttributeList,1,0,&bytes))return 2;
    DWORD64 policy=PROCESS_CREATION_MITIGATION_POLICY_BLOCK_NON_MICROSOFT_BINARIES_ALWAYS_ON;
    bool configured=UpdateProcThreadAttribute(startup.lpAttributeList,0,PROC_THREAD_ATTRIBUTE_MITIGATION_POLICY,
        &policy,sizeof(policy),nullptr,nullptr)!=FALSE;
    PROCESS_INFORMATION process{};
    bool started=configured&&CreateProcessW(path,command.data(),nullptr,nullptr,TRUE,EXTENDED_STARTUPINFO_PRESENT,
        nullptr,nullptr,&startup.StartupInfo,&process)!=FALSE;
    DeleteProcThreadAttributeList(startup.lpAttributeList);
    if(!started){std::cerr<<"Isolated validation process failed: "<<GetLastError()<<"\n";return 2;}
    WaitForSingleObject(process.hProcess,INFINITE);DWORD result{};GetExitCodeProcess(process.hProcess,&result);
    CloseHandle(process.hThread);CloseHandle(process.hProcess);return int(result);
}

// 仅离线 WARP 测试回读断言；游戏只为 10 位合成复制局部 GPU 底色，无 CPU 回读或图像输出。
int main(int argc, char** argv) {
    bool srgb{},premult{},bgra{},edge{},ten{},clipped{},tall{},wide{},shape{},full_height{},isolated{},hd_source{};float alpha=1;
    for(int i=1;i<argc;++i) {
        const std::string option=argv[i];
        if(option=="--srgb")srgb=true;
        else if(option=="--hd-source")hd_source=true;
        else if(option=="--premult")premult=true;
        else if(option=="--bgra")bgra=true;
        else if(option=="--edge")edge=true;
        else if(option=="--ten")ten=true;
        else if(option=="--clipped")clipped=true;
        else if(option=="--tall")tall=true;
        else if(option=="--wide")wide=true;
        else if(option=="--shape")shape=true;
        else if(option=="--full-height")full_height=true;
        else if(option=="--isolated-validation")isolated=true;
        else if(option=="--alpha-zero")alpha=0;
        else if(option=="--alpha-half")alpha=.5f;
        else { std::cerr<<"Unknown test option: "<<option<<"\n";return 1; }
    }
    if(!isolated)return isolated_validation();
    REFrameworkPluginFunctions functions{}; functions.log_info=record_log;
    REFrameworkPluginInitializeParam param{}; param.functions=&functions; host=&param;
    HWND window{};
    try {
        // 矩形移动不触碰纹理/设备、不延长心跳，停止后也不能自行重启绘制。
        drawing=true;heartbeat=123;rectangle[0]=0;
        if(portrait_gpu_rectangle(42,61,280,700)!=0||rectangle[0]!=42||rectangle[1]!=61||heartbeat!=123||source)
            throw std::runtime_error("rectangle-only update mutated resource lifecycle");
        if(portrait_gpu_rectangle(1,2,0,700)!=int(E_INVALIDARG)||rectangle[0]!=42)
            throw std::runtime_error("invalid rectangle mutated live state");
        drawing=false;
        if(portrait_gpu_rectangle(100,100,280,700)!=0||drawing||rectangle[0]!=42)
            throw std::runtime_error("idle rectangle revived drawing");
        if(sdr_rtv_format(DXGI_FORMAT_R8G8B8A8_UNORM)!=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB
            ||sdr_rtv_format(DXGI_FORMAT_B8G8R8A8_UNORM)!=DXGI_FORMAT_B8G8R8A8_UNORM_SRGB)
            throw std::runtime_error("SDR output view mapping");
        if(sdr_rtv_format(DXGI_FORMAT_R10G10B10A2_UNORM)!=DXGI_FORMAT_R10G10B10A2_UNORM)
            throw std::runtime_error("high-quality SDR10 output mapping");
        for(auto format:{DXGI_FORMAT_R16G16B16A16_FLOAT,DXGI_FORMAT_UNKNOWN}) {
            bool rejected=false;try{sdr_rtv_format(format);}catch(const std::runtime_error&){rejected=true;}
            if(!rejected)throw std::runtime_error("HDR/unknown output silently accepted");
        }
        if(portrait_gpu_set_alpha_mode(-1)!=int(E_INVALIDARG)||portrait_gpu_set_alpha_mode(2)!=int(E_INVALIDARG))
            throw std::runtime_error("invalid alpha mode accepted");
        // 游戏控制器会重复提交同一 alpha 模式；状态不变时不应反复写日志。
        const auto before_alpha=log_count;
        for(int i=0;i<1000;++i)if(portrait_gpu_set_alpha_mode(0)!=0||alpha_mode!=AlphaMode::Straight)
            throw std::runtime_error("repeated alpha mode changed state");
        if(log_count!=before_alpha)throw std::runtime_error("unchanged alpha mode spammed the log");
        if(portrait_gpu_set_alpha_mode(1)!=0||alpha_mode!=AlphaMode::Premultiplied||portrait_gpu_set_alpha_mode(0)!=0)
            throw std::runtime_error("valid alpha mode transition failed");
        if(portrait_gpu_set_output_contract(1,1)!=int(E_NOTIMPL)||output_sdr_confirmed
            ||portrait_gpu_set_output_contract(0,3)!=int(E_NOTIMPL)||output_sdr_confirmed
            ||portrait_gpu_set_output_contract(0,1)!=0||!output_sdr_confirmed)
            throw std::runtime_error("unknown/HDR output contract accepted or SDR rejected");
        ComPtr<ID3D12Debug> debug;
        if (SUCCEEDED(D3D12GetDebugInterface(IID_PPV_ARGS(&debug)))) debug->EnableDebugLayer();
        ComPtr<IDXGIFactory4> factory; check(CreateDXGIFactory1(IID_PPV_ARGS(&factory)),"factory");
        ComPtr<IDXGIAdapter> adapter; check(factory->EnumWarpAdapter(IID_PPV_ARGS(&adapter)),"WARP");
        ComPtr<ID3D12Device> device; check(D3D12CreateDevice(adapter.Get(),D3D_FEATURE_LEVEL_11_0,IID_PPV_ARGS(&device)),"WARP device");
        ComPtr<ID3D12InfoQueue> messages; device.As(&messages);
        ComPtr<ID3D12CommandQueue> queue; D3D12_COMMAND_QUEUE_DESC q{};
        check(device->CreateCommandQueue(&q,IID_PPV_ARGS(&queue)),"queue");
        WNDCLASSW wc{}; wc.lpfnWndProc=DefWindowProcW; wc.hInstance=GetModuleHandleW(nullptr); wc.lpszClassName=L"AVM_GPU_OFFLINE_HIDDEN";
        RegisterClassW(&wc);
        window=CreateWindowExW(0,wc.lpszClassName,L"",WS_OVERLAPPEDWINDOW,0,0,256,256,nullptr,nullptr,wc.hInstance,nullptr);
        if (!window) throw std::runtime_error("hidden window");
        DXGI_SWAP_CHAIN_DESC1 sd{}; sd.Width=256; sd.Height=256; sd.Format=bgra?DXGI_FORMAT_B8G8R8A8_UNORM:DXGI_FORMAT_R8G8B8A8_UNORM; sd.SampleDesc.Count=1;
        if(full_height)sd.Width=sd.Height=1024;
        if(ten)sd.Format=DXGI_FORMAT_R10G10B10A2_UNORM;
        sd.BufferUsage=DXGI_USAGE_RENDER_TARGET_OUTPUT; sd.BufferCount=2; sd.SwapEffect=DXGI_SWAP_EFFECT_FLIP_DISCARD;
        ComPtr<IDXGISwapChain1> chain; check(factory->CreateSwapChainForHwnd(queue.Get(),window,&sd,nullptr,nullptr,&chain),"hidden swapchain");
        ComPtr<IDXGISwapChain3> swapchain; chain.As(&swapchain);
        ComPtr<ID3D12CommandAllocator> allocator; ComPtr<ID3D12GraphicsCommandList> commands;
        check(device->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT,IID_PPV_ARGS(&allocator)),"test allocator");
        check(device->CreateCommandList(0,D3D12_COMMAND_LIST_TYPE_DIRECT,allocator.Get(),nullptr,IID_PPV_ARGS(&commands)),"test commands");
        ComPtr<ID3D12Fence> done; check(device->CreateFence(0,D3D12_FENCE_FLAG_NONE,IID_PPV_ARGS(&done)),"test fence");
        UINT64 serial{};
        auto wait=[&] {
            check(queue->Signal(done.Get(),++serial),"test signal");
            HANDLE event=CreateEventW(nullptr,FALSE,FALSE,nullptr); if (!event) throw std::runtime_error("test event");
            check(done->SetEventOnCompletion(serial,event),"test event completion");
            auto status=WaitForSingleObject(event,5000); CloseHandle(event);
            if(status!=WAIT_OBJECT_0) throw std::runtime_error("offline GPU timeout");
        };
        auto execute=[&] { check(commands->Close(),"test close"); ID3D12CommandList* list[]{commands.Get()};queue->ExecuteCommandLists(1,list);wait(); };
        D3D12_RESOURCE_DESC desc{}; desc.Dimension=D3D12_RESOURCE_DIMENSION_TEXTURE2D; desc.Width=220;desc.Height=240;
        desc.DepthOrArraySize=1; desc.MipLevels=1;desc.SampleDesc.Count=1;desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM;desc.Flags=D3D12_RESOURCE_FLAG_ALLOW_RENDER_TARGET;
        if(hd_source){desc.Width=660;desc.Height=720;}
        const int source_width=int(desc.Width),source_height=int(desc.Height),density=hd_source?3:1;
        if(!portrait_gpu::valid_desc(desc)) throw std::runtime_error("valid source rejected");
        auto invalid=desc;invalid.Width=221;if(portrait_gpu::valid_desc(invalid)) throw std::runtime_error("invalid size accepted");
        invalid=desc;invalid.Flags|=D3D12_RESOURCE_FLAG_DENY_SHADER_RESOURCE;if(portrait_gpu::valid_desc(invalid)) throw std::runtime_error("deny SRV accepted");
        ComPtr<ID3D12Resource> rejected;if(SUCCEEDED(portrait_gpu::resolve(0,rejected))) throw std::runtime_error("null holder accepted");
        if(SUCCEEDED(portrait_gpu::resolve(0x10000,rejected))) throw std::runtime_error("invalid holder accepted");
        // 两款游戏的引擎对象链:用本进程里的假对象(虚表在本 exe / d3d12.dll)核对每一层偏移
        {
            static const uintptr_t engine_vtable[1]{};
            const auto d3d = reinterpret_cast<uintptr_t>(GetProcAddress(GetModuleHandleW(L"d3d12.dll"),"D3D12CreateDevice"));
            if(!d3d) throw std::runtime_error("d3d12 export");
            for (const auto* l : {&portrait_gpu::WILDS_LAYOUT,&portrait_gpu::RE4_LAYOUT}) {
                alignas(16) static unsigned char holder[0x40],resource[0x100],texture[0x200],dx[0x40],native[0x10];
                std::memset(holder,0,sizeof holder);std::memset(resource,0,sizeof resource);std::memset(texture,0,sizeof texture);std::memset(dx,0,sizeof dx);
                auto put=[](unsigned char* base,uintptr_t offset,auto value){std::memcpy(base+offset,&value,sizeof value);};
                const auto vt=reinterpret_cast<uintptr_t>(engine_vtable);
                put(resource,0,vt);put(texture,0,vt);put(dx,0,vt);put(native,0,d3d);
                put(holder,l->resource,reinterpret_cast<uintptr_t>(resource));
                put(resource,l->texture,reinterpret_cast<uintptr_t>(texture));
                put(texture,l->width,uint32_t(660));put(texture,l->height,uint32_t(720));
                put(texture,l->dx,reinterpret_cast<uintptr_t>(dx));
                put(dx,l->native,reinterpret_cast<uintptr_t>(native));
                uintptr_t found{};uint32_t w{},h{};
                if(!portrait_gpu::locate(reinterpret_cast<uintptr_t>(holder),*l,found,w,h)||found!=reinterpret_cast<uintptr_t>(native)||w!=660||h!=720)
                    throw std::runtime_error("engine layout not followed");
                const auto* other=l==&portrait_gpu::WILDS_LAYOUT?&portrait_gpu::RE4_LAYOUT:&portrait_gpu::WILDS_LAYOUT;
                if(portrait_gpu::locate(reinterpret_cast<uintptr_t>(holder),*other,found,w,h)) throw std::runtime_error("foreign layout accepted");
            }
            if(portrait_gpu::layout_for("MHWILDS")!=&portrait_gpu::WILDS_LAYOUT||portrait_gpu::layout_for("RE4")!=&portrait_gpu::RE4_LAYOUT
                ||portrait_gpu::layout_for("MHRISE")) throw std::runtime_error("layout selection");
        }
        if(srgb) desc.Format=DXGI_FORMAT_R8G8B8A8_UNORM_SRGB;
        float rgba[]{.25f,.5f,.75f,alpha};
        if(premult)for(unsigned c=0;c<3;++c)rgba[c]*=alpha;
        D3D12_HEAP_PROPERTIES heap{};heap.Type=D3D12_HEAP_TYPE_DEFAULT;
        D3D12_CLEAR_VALUE optimized{};optimized.Format=desc.Format;std::copy(rgba,rgba+4,optimized.Color);
        ComPtr<ID3D12Resource> image;check(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&desc,
            edge||shape?D3D12_RESOURCE_STATE_COPY_DEST:D3D12_RESOURCE_STATE_RENDER_TARGET,&optimized,IID_PPV_ARGS(&image)),"test image");
        D3D12_DESCRIPTOR_HEAP_DESC hd{};hd.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;hd.NumDescriptors=1;
        ComPtr<ID3D12DescriptorHeap> color;check(device->CreateDescriptorHeap(&hd,IID_PPV_ARGS(&color)),"test color heap");
        device->CreateRenderTargetView(image.Get(),nullptr,color->GetCPUDescriptorHandleForHeapStart());
        // 仅离线夹具上传三条带，避免不同 Clear 颜色触发优化提示；不放宽 debug 警告门槛。
        // 奇数分界迫使线性过滤跨越透明、半透明与实体交界，检查 alpha 约定与边缘像素。
        ComPtr<ID3D12Resource> pattern_upload;
        if(edge||shape) {
            D3D12_PLACED_SUBRESOURCE_FOOTPRINT layout{};UINT64 size{};
            device->GetCopyableFootprints(&desc,0,1,0,&layout,nullptr,nullptr,&size);
            D3D12_HEAP_PROPERTIES upload_heap{};upload_heap.Type=D3D12_HEAP_TYPE_UPLOAD;
            D3D12_RESOURCE_DESC upload_desc{};upload_desc.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;upload_desc.Width=size;
            upload_desc.Height=1;upload_desc.DepthOrArraySize=1;upload_desc.MipLevels=1;upload_desc.SampleDesc.Count=1;upload_desc.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
            check(device->CreateCommittedResource(&upload_heap,D3D12_HEAP_FLAG_NONE,&upload_desc,D3D12_RESOURCE_STATE_GENERIC_READ,nullptr,IID_PPV_ARGS(&pattern_upload)),"pattern upload");
            unsigned char* mapped{};check(pattern_upload->Map(0,nullptr,reinterpret_cast<void**>(&mapped)),"pattern map");
            for(int y=0;y<source_height;++y)for(int x=0;x<source_width;++x)for(unsigned c=0;c<4;++c) {
                const double a=shape?(x>=90*density&&x<130*density&&y>=100*density&&y<140*density?1.:0.):x<73*density?0.:x<147*density?.5:1.;const double colors[]{.25,.5,.75};
                const double linear=c==3?a:colors[c]*(premult?a:1.);
                mapped[layout.Offset+y*layout.Footprint.RowPitch+x*4+c]=static_cast<unsigned char>(byte_value(c!=3&&srgb?encode_srgb(linear):linear));
            }
            pattern_upload->Unmap(0,nullptr);
            D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=pattern_upload.Get();from.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;from.PlacedFootprint=layout;
            to.pResource=image.Get();to.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
            commands->CopyTextureRegion(&to,0,0,0,&from,nullptr);
        } else commands->ClearRenderTargetView(color->GetCPUDescriptorHandleForHeapStart(),rgba,0,nullptr);
        D3D12_RESOURCE_BARRIER barrier{};barrier.Type=D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
        barrier.Transition={image.Get(),D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,
            edge||shape?D3D12_RESOURCE_STATE_COPY_DEST:D3D12_RESOURCE_STATE_RENDER_TARGET,D3D12_RESOURCE_STATE_PIXEL_SHADER_RESOURCE};
        commands->ResourceBarrier(1,&barrier);execute();
        REFrameworkRendererData data{REFRAMEWORK_RENDERER_D3D12,device.Get(),chain.Get(),queue.Get()};
        auto renderer=std::make_unique<Overlay>(data,false);float rect[]{30,20,110,120};unsigned submitted{};UINT last{};
        if(tall){rect[0]=80;rect[1]=20;rect[2]=80;rect[3]=210;}
        if(wide){rect[0]=20;rect[1]=80;rect[2]=210;rect[3]=80;}
        if(full_height){rect[0]=30;rect[1]=30;rect[2]=280;rect[3]=940;}
        if(clipped){rect[0]=-15.25f;rect[1]=180.5f;rect[2]+=.5f;rect[3]+=.5f;}
        // 透明度对照必须预置已知底色，不能把未初始化交换链内容当成合成结果。
        ComPtr<ID3D12DescriptorHeap> background_rtv;
        {
            D3D12_DESCRIPTOR_HEAP_DESC background_heap{};background_heap.Type=D3D12_DESCRIPTOR_HEAP_TYPE_RTV;background_heap.NumDescriptors=1;
            check(device->CreateDescriptorHeap(&background_heap,IID_PPV_ARGS(&background_rtv)),"background RTV heap");
        }
        for (unsigned i=0;i<120;++i) {
            last=swapchain->GetCurrentBackBufferIndex();
            {
                ComPtr<ID3D12Resource> background;check(chain->GetBuffer(last,IID_PPV_ARGS(&background)),"background buffer");
                auto target=background_rtv->GetCPUDescriptorHandleForHeapStart();device->CreateRenderTargetView(background.Get(),nullptr,target);
                check(allocator->Reset(),"background allocator reset");check(commands->Reset(allocator.Get(),nullptr),"background command reset");
                barrier.Transition={background.Get(),D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_RENDER_TARGET};commands->ResourceBarrier(1,&barrier);
                float background_color[]{.8f,.6f,.4f,1.f};commands->ClearRenderTargetView(target,background_color,0,nullptr);
                std::swap(barrier.Transition.StateBefore,barrier.Transition.StateAfter);commands->ResourceBarrier(1,&barrier);execute();
            }
            if(renderer->render(image.Get(),rect,premult?AlphaMode::Premultiplied:AlphaMode::Straight)) ++submitted;
            wait(); renderer->reclaim();
            // FLIP_DISCARD 在 Present 后不保证内容；最后一帧须先回读，不把已丢弃缓冲当作渲染证据。
            if(i+1<120)check(chain->Present(0,0),"offline present");
        }
        if(submitted!=120||!renderer->drain()) throw std::runtime_error("offline frame completion");
        ComPtr<ID3D12Resource> backbuffer;check(chain->GetBuffer(last,IID_PPV_ARGS(&backbuffer)),"test output");
        auto output=backbuffer->GetDesc();D3D12_PLACED_SUBRESOURCE_FOOTPRINT footprint{};UINT64 total{};
        device->GetCopyableFootprints(&output,0,1,0,&footprint,nullptr,nullptr,&total);
        D3D12_RESOURCE_DESC rb{};rb.Dimension=D3D12_RESOURCE_DIMENSION_BUFFER;rb.Width=total;rb.Height=1;rb.DepthOrArraySize=1;rb.MipLevels=1;rb.SampleDesc.Count=1;rb.Layout=D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        heap.Type=D3D12_HEAP_TYPE_READBACK;ComPtr<ID3D12Resource> readback;
        check(device->CreateCommittedResource(&heap,D3D12_HEAP_FLAG_NONE,&rb,D3D12_RESOURCE_STATE_COPY_DEST,nullptr,IID_PPV_ARGS(&readback)),"test readback");
        check(allocator->Reset(),"test allocator reset");check(commands->Reset(allocator.Get(),nullptr),"test command reset");
        barrier.Transition={backbuffer.Get(),D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES,D3D12_RESOURCE_STATE_PRESENT,D3D12_RESOURCE_STATE_COPY_SOURCE};commands->ResourceBarrier(1,&barrier);
        D3D12_TEXTURE_COPY_LOCATION from{},to{};from.pResource=backbuffer.Get();from.Type=D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.pResource=readback.Get();to.Type=D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;to.PlacedFootprint=footprint;
        commands->CopyTextureRegion(&to,0,0,0,&from,nullptr);std::swap(barrier.Transition.StateBefore,barrier.Transition.StateAfter);commands->ResourceBarrier(1,&barrier);execute();
        unsigned char* bytes{};check(readback->Map(0,nullptr,reinterpret_cast<void**>(&bytes)),"test map");
        const double background[]{.8,.6,.4};const double foreground[]{.25,.5,.75};
        const int levels=ten?1023:255,alpha_levels=ten?3:255;
        auto out_value=[&](double v){return int(std::lround(std::clamp(v,0.,1.)*levels));};
        auto sample=[&](unsigned x,unsigned y,unsigned c){
            const auto offset=footprint.Offset+y*footprint.Footprint.RowPitch+x*4;
            if(ten){uint32_t value{};memcpy(&value,bytes+offset,4);return int(c==3?value>>30:(value>>(c*10))&1023);}
            return int(bytes[offset+(bgra&&c!=3?2-c:c)]);
        };
        auto inside_rect=[&](unsigned x,unsigned y){return x+.5>=rect[0]&&x+.5<rect[0]+rect[2]&&y+.5>=rect[1]&&y+.5<rect[1]+rect[3];};
        // 独立计算纹素量化、sRGB 解码、线性过滤与 alpha 混合，逐像素验证透明分界。
        auto texel=[&](int x,int y,unsigned c) {
            x=std::clamp(x,0,source_width-1);y=std::clamp(y,0,source_height-1);
            const double a=shape?(x>=90*density&&x<130*density&&y>=100*density&&y<140*density?1.:0.):edge?(x<73*density?0.:x<147*density?.5:1.):alpha;
            if(c==3)return byte_value(a)/255.;
            const double value=foreground[c]*(premult?a:1.);
            const double stored=byte_value(srgb?encode_srgb(value):value)/255.;
            return srgb?decode_srgb(stored):stored;
        };
        auto expected_at=[&](unsigned x,unsigned y,unsigned c) {
            if(!inside_rect(x,y))return c==3?alpha_levels:out_value(background[c]);
            if(c==3)return alpha_levels;
            // 按等比例放大后的源像素位置独立推导裁切，不能重复实现 shader 的 UV 公式。
            const double scale=(std::max)(rect[2]/double(source_width),rect[3]/double(source_height));
            const double sx=source_width/2.+(x+.5-rect[0]-rect[2]/2.)/scale-.5;
            const double sy=source_height/2.+(y+.5-rect[1]-rect[3]/2.)/scale-.5;
            const int ix=int(std::floor(sx)),iy=int(std::floor(sy));const double fx=sx-ix,fy=sy-iy;
            auto filtered=[&](unsigned channel){return (texel(ix,iy,channel)*(1.-fx)+texel(ix+1,iy,channel)*fx)*(1.-fy)
                +(texel(ix,iy+1,channel)*(1.-fx)+texel(ix+1,iy+1,channel)*fx)*fy;};
            const double a=filtered(3);
            const double linear=a<=0?0:filtered(c);
            const double base=decode_srgb(double(out_value(background[c]))/levels);
            return out_value(encode_srgb(linear*(premult?1.:a)+base*(1.-a)));
        };
        bool matches=true;
        std::cout<<"WARP source="<<(srgb?"sRGB":"linear UNORM")<<" alpha="<<alpha<<" mode="<<(premult?"premult":"straight")<<" output="<<(ten?"SDR10":bgra?"BGRA":"RGBA")<<" edge="<<edge<<" clipped="<<clipped<<" rgb=";
        for(unsigned c=0;c<3;++c) {
            const int expected=expected_at(85,80,c);
            const int actual=sample(85,80,c);std::cout<<actual<<(c==2?"":",");
            if(abs(actual-expected)>2){matches=false;std::cerr<<" channel="<<c<<" expected="<<expected<<" actual="<<actual<<"\n";}
        }
        matches=matches&&sample(85,80,3)==alpha_levels;
        // 矩形外底色逐字节不变；内部逐像素对比独立推导值，容许 2 个量化单位。
        for(unsigned y=0;y<sd.Height;++y)for(unsigned x=0;x<sd.Width;++x)for(unsigned c=0;c<4;++c) {
            const bool inside=inside_rect(x,y);
            if(abs(sample(x,y,c)-expected_at(x,y,c))>(inside&&c!=3?2:0)) {
                if(matches)std::cerr<<" first_mismatch="<<x<<","<<y<<" channel="<<c<<" expected="<<expected_at(x,y,c)<<" actual="<<sample(x,y,c)<<"\n";
                matches=false;
            }
        }
        std::cout<<" alpha="<<sample(85,80,3)<<" submitted="<<submitted<<"\n";
        readback->Unmap(0,nullptr);if(!matches) throw std::runtime_error("sRGB/alpha composition or rectangle containment mismatch");
        if(messages) {
            for(UINT64 index=0;index<messages->GetNumStoredMessages();++index) {
                SIZE_T size{};messages->GetMessage(index,nullptr,&size);std::vector<unsigned char> buffer(size);
                auto* message=reinterpret_cast<D3D12_MESSAGE*>(buffer.data());messages->GetMessage(index,message,&size);
                if(message->Severity<=D3D12_MESSAGE_SEVERITY_WARNING) { std::cerr<<message->pDescription<<"\n";throw std::runtime_error("D3D12 debug validation warning/error"); }
            }
        }
        // 自动 Present 仍须停止过期绘制并释放源引用。
        source=image; drawing=true; heartbeat=GetTickCount64()-501;
        present();
        if(drawing||source)throw std::runtime_error("idle frame retained expired source");
        renderer.reset();DestroyWindow(window);window=nullptr;
        std::cout<<"PASS: actual renderer, SDR8/10 color/alpha composition, rectangle containment, HDR rejection, source validation, 120 completed frames and fence-safe reclaim; debug_layer="<<(debug?1:0)<<"\n";
        return 0;
    } catch(const std::exception& error) { if(window)DestroyWindow(window);std::cerr<<error.what()<<"\n";return 1; }
}
