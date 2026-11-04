#include <reff/native_preview.h>
#include <cstring>
#include <vector>

namespace {
REFFPreviewProvider active{};
std::vector<REFFPreviewProvider> retired;
bool reject_next{};
REFFPreviewHandle __cdecl attach(const REFFPreviewProvider* p) {
    if(active.user || std::strcmp(p->plugin_id,"monkeysama.avm") || std::strcmp(p->slot_id,"portrait"))return 0;
    active=*p;return 1;
}
int __cdecl update(REFFPreviewHandle handle,const REFFPreviewProvider* p) {
    if(reject_next){reject_next=false;return 0;}
    if(handle!=1 || !active.user || p->user==active.user)return 0;
    retired.push_back(active);active=*p;return 1;
}
int __cdecl detach(REFFPreviewHandle handle) {
    if(handle!=1 || !active.user)return 0;
    retired.push_back(active);active={};return 1;
}
const REFFNativePreviewAPI api{sizeof(api),REFF_PREVIEW_ABI_V1,4,
    REFF_PREVIEW_CAP_DX12_CALLBACK|REFF_PREVIEW_CAP_UNDERLAY|REFF_PREVIEW_CAP_SDR8|REFF_PREVIEW_CAP_SDR10,
    attach,update,detach};
}

// 测试宿主延迟 release，模拟 REFF 的 fence 租约；不加载或接触正在运行的 REFF。
extern "C" __declspec(dllexport) const REFFNativePreviewAPI* __cdecl reff_get_native_preview_api(uint32_t version) {
    return version==REFF_PREVIEW_ABI_V1?&api:nullptr;
}
extern "C" __declspec(dllexport) const REFFPreviewProvider* preview_fixture_active(){return active.user?&active:nullptr;}
extern "C" __declspec(dllexport) unsigned preview_fixture_retired(){return unsigned(retired.size());}
extern "C" __declspec(dllexport) void preview_fixture_release(){for(auto& p:retired)p.release(p.user);retired.clear();}
extern "C" __declspec(dllexport) void preview_fixture_reject(){reject_next=true;}
