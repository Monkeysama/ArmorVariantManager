// 形态键权重镜像(avm_portrait_blend_sync):首帧整份写入、静态帧不写、只写变化的通道、
// System.Single 参数/返回值按 double 传递、通道数不一致的网格跳过、写失败下帧补齐、没有绑定时报错。
#include "../PortraitPose.cpp"
#include <cassert>
#include <cstdio>
#include <unordered_map>

using namespace portrait_pose;
namespace {
constexpr uintptr_t COUNT = 1, GET = 2, SET = 3;
std::unordered_map<uintptr_t, std::vector<float>> weights;   // 网格地址 -> 通道权重
int gets, sets;
uintptr_t fail_set_index = UINTPTR_MAX;

REFrameworkResult fake_invoke(REFrameworkMethodHandle method, void* object, void** args, unsigned size, void* output, unsigned bytes) {
    assert(bytes == sizeof(reframework::InvokeRet));
    auto result = static_cast<reframework::InvokeRet*>(output);
    *result = {};
    auto id = reinterpret_cast<uintptr_t>(method), self = reinterpret_cast<uintptr_t>(object);
    auto& list = weights.at(self);
    if (id == COUNT) { assert(!size); result->qword = list.size(); }
    // 和真实 invoke 包装一致:System.Single 返回值按 double 放进结果
    else if (id == GET) { assert(size == sizeof(void*)); result->d = list.at(reinterpret_cast<uintptr_t>(args[0])); ++gets; }
    else if (id == SET) {
        assert(size == 2 * sizeof(void*));
        const auto index = reinterpret_cast<uintptr_t>(args[0]);
        if (index == fail_set_index) { result->exception_thrown = true; return REFRAMEWORK_ERROR_NONE; }
        double wide; const auto slot = reinterpret_cast<uintptr_t>(args[1]); std::memcpy(&wide, &slot, sizeof(wide));   // 参数也是 double
        const float value = static_cast<float>(wide);
        list.at(index) = value; ++sets;
    } else assert(false && "unexpected method");
    return REFRAMEWORK_ERROR_NONE;
}
Mesh mesh(uintptr_t source, uintptr_t copy) { return Mesh{ source, copy, 0, 0, 0, 0, {}, {} }; }
}

int main() {
    REFrameworkTDBMethod table{}; table.invoke = fake_invoke;
    REFrameworkManagedObject objects{};
    REFrameworkSDKData data{}; data.method = &table; data.managed_object = &objects;
    REFrameworkPluginInitializeParam param{}; param.sdk = &data; API::initialize(&param); sdk = &data;
    blend_methods = { reinterpret_cast<Method*>(COUNT), reinterpret_cast<Method*>(GET), reinterpret_cast<Method*>(SET) };

    assert(avm_portrait_blend_version() == 1);
    assert(avm_portrait_blend_sync() == -1 && "No binding must be reported, not ignored");

    weights[10] = { 0.0f, 0.25f, 1.0f, 0.5f };   // 头部原网格
    weights[20] = { 0.9f, 0.9f, 0.9f, 0.9f };    // 头部副本(默认值和原网格不同)
    weights[11] = { 0.3f, 0.7f };                // 通道数不一致的一对:跳过
    weights[21] = { 0.0f, 0.0f, 0.0f };
    binding = std::make_unique<Binding>();
    binding->meshes.push_back(mesh(10, 20));
    binding->meshes.push_back(mesh(11, 21));

    // 首帧:即使副本里某个值恰好相同,也要整份写一次
    assert(avm_portrait_blend_sync() == 0);
    assert(sets == 4 && weights[20] == weights[10] && "First sync writes every channel; Single values travel as double");
    assert(weights[21] == (std::vector<float>{ 0.0f, 0.0f, 0.0f }) && "Mismatched channel layouts are left alone");

    // 静态帧:只读不写
    sets = gets = 0;
    for (int frame = 0; frame < 100; ++frame) assert(avm_portrait_blend_sync() == 0);
    assert(sets == 0 && gets == 400);

    // 改一个通道,下一帧恰好写一次
    weights[10][2] = 0.125f;
    assert(avm_portrait_blend_sync() == 0 && sets == 1 && weights[20][2] == 0.125f);

    // 写失败:报错;失败项下帧补上,成功项不重复写
    weights[10][0] = 0.75f; weights[10][3] = 0.0625f; fail_set_index = 3; sets = 0;
    assert(avm_portrait_blend_sync() == -1 && sets == 1 && weights[20][0] == 0.75f);
    fail_set_index = UINTPTR_MAX; sets = 0;
    assert(avm_portrait_blend_sync() == 0 && sets == 1 && weights[20] == weights[10]);

    // 重新绑定(副本重建)后重新整份写
    binding = std::make_unique<Binding>();
    binding->meshes.push_back(mesh(10, 20));
    sets = 0; assert(avm_portrait_blend_sync() == 0 && sets == 4);
    avm_portrait_pose_clear(); assert(avm_portrait_blend_sync() == -1);
    std::puts("PASS: blend shape mirror writes all channels once, skips static frames and mismatched layouts, writes only changed channels, passes System.Single as double (invoke wrapper ABI), retries failed writes, resets on rebind");
}
