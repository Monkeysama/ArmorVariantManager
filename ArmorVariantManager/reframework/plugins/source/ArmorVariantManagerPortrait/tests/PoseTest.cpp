#include "../PortraitPose.cpp"
#include <cassert>
#include <cstdio>
#include <unordered_map>

using namespace portrait_pose;
namespace {
std::unordered_map<uintptr_t, int> references;
struct Holder { int kind, resource; };
std::unordered_map<uintptr_t, Holder> holders;
uintptr_t next_holder = 100000, fail_method;
uintptr_t fail_index = UINTPTR_MAX;
bool fail_status;
std::array<int, 39> calls{};
int writes, reads, mesh_writes, equal_calls, copy_asset = 2000, copy_material = 3000;
bool valid = true, joint_valid = true, ready = true, fault, changed, material_changed, null_asset;
bool enabled = false, draw_default = true, copied_enabled = true, copied_draw_default = true;
std::vector<bool> materials{true}, copied_materials{false};
std::vector<bool> parts{false, true, false, true}, copied_parts{true, true, true, true};
uint64_t material_count = materials.size(), copy_material_count = materials.size();
uint64_t part_count = parts.size(), copy_part_count = parts.size();
uintptr_t holder(int kind, int resource) { auto id = next_holder++; holders[id] = {kind, resource}; return id; }
// 跨帧只保留显式引用；每次 getter 都构造不同地址，不能靠固定测试指针蒙混过关。
void next_frame() {
    for (auto it = holders.begin(); it != holders.end();)
        if (references[it->first] == 0) it = holders.erase(it); else ++it;
}
void add_ref(REFrameworkManagedObjectHandle object) { ++references[reinterpret_cast<uintptr_t>(object)]; }
void release(REFrameworkManagedObjectHandle object) { assert(--references[reinterpret_cast<uintptr_t>(object)] >= 0); }
bool managed(void* object) {
    auto id = reinterpret_cast<uintptr_t>(object);
    return (id >= 10 && id <= 60) || holders.contains(id);
}
REFrameworkResult fake_invoke(REFrameworkMethodHandle method, void* object, void** args, unsigned size, void* output, unsigned bytes) {
    assert(bytes == sizeof(reframework::InvokeRet));
    auto result = static_cast<reframework::InvokeRet*>(output);
    *result = {};
    auto id = reinterpret_cast<uintptr_t>(method), self = reinterpret_cast<uintptr_t>(object);
    ++calls.at(id);
    const bool injected = id == fail_method && (fail_index == UINTPTR_MAX || (size && reinterpret_cast<uintptr_t>(args[0]) == fail_index));
    if (injected && fail_status) return REFRAMEWORK_ERROR_UNKNOWN;
    result->exception_thrown = fault || injected;
    if (result->exception_thrown) return REFRAMEWORK_ERROR_NONE;
    if (id == 20) result->ptr = reinterpret_cast<void*>(self + 1000);
    else if (id == 21) result->byte = valid;
    else if (id == 22) result->byte = joint_valid;
    else if (id == 23) result->ptr = null_asset ? nullptr : reinterpret_cast<void*>(holder(1, self == 60 ? copy_asset : (changed ? 2001 : 2000)));
    else if (id == 24) result->ptr = reinterpret_cast<void*>(holder(2, self == 60 ? copy_material : (material_changed ? 3001 : 3000)));
    else if (id == 25) result->byte = ready;
    else if (id == 26) result->qword = self == 60 ? copy_material_count : material_count;
    else if (id == 27) { assert(size == sizeof(void*) && self == 50); result->byte = materials.at(reinterpret_cast<uintptr_t>(args[0])); }
    else if (id == 28) { assert(size == 2 * sizeof(void*) && self == 60); copied_materials.at(reinterpret_cast<uintptr_t>(args[0])) = args[1] != nullptr; ++writes; }
    else if (id == 32) result->qword = self == 60 ? copy_part_count : part_count;
    else if (id == 33) { assert(size == sizeof(void*) && self == 50); result->byte = parts.at(reinterpret_cast<uintptr_t>(args[0])); }
    else if (id == 34) { assert(size == 2 * sizeof(void*) && self == 60); copied_parts.at(reinterpret_cast<uintptr_t>(args[0])) = args[1] != nullptr; ++writes; }
    else if (id == 35 || id == 37) { assert(!size && self == 50); result->byte = id == 35 ? enabled : draw_default; }
    else if (id == 36 || id == 38) {
        assert(size == sizeof(void*) && self == 60);
        (id == 36 ? copied_enabled : copied_draw_default) = args[0] != nullptr; ++writes;
    }
    else if (id == 29 || id == 30) {
        assert(size == sizeof(void*) && self == 60);
        auto value = reinterpret_cast<uintptr_t>(args[0]);
        assert(references[value] > 0 && holders.contains(value));
        if (id == 29) { assert(holders[value].kind == 1); copy_asset = holders[value].resource; }
        else { assert(holders[value].kind == 2); copy_material = holders[value].resource; }
        ++mesh_writes;
    } else if (id == 31) {
        assert(!self && size == 2 * sizeof(void*));
        auto left = reinterpret_cast<uintptr_t>(args[0]), right = reinterpret_cast<uintptr_t>(args[1]);
        assert(references[left] > 0 && references[right] > 0 && left != right);
        auto a = holders.at(left), b = holders.at(right);
        result->byte = a.kind == b.kind && a.resource == b.resource; ++equal_calls;
    }
    else if (id <= 3 || (id >= 11 && id <= 13)) {
        assert(!size && (self == 10 || self == 30));
        float value[]{ 1, 2, 3, 4 }; std::memcpy(result->bytes.data(), value, sizeof(value)); ++reads;
    } else {
        assert(size == sizeof(void*) && (self == 20 || self == 40));
        auto value = static_cast<float*>(args[0]);
        if (id == 4 || id == 14) assert(value[0] == 11 && value[1] == -9998 && value[2] == 33);
        else assert(value[0] == 1 && value[1] == 2 && value[2] == 3);
        ++writes;
    }
    return REFRAMEWORK_ERROR_NONE;
}
void check_references(int expected) { int sum{}; for (auto [_, count] : references) sum += count; assert(sum == expected); }
}
int main(int argc, char** argv) {
    const bool baseline = argc == 2 && std::strcmp(argv[1], "--baseline") == 0;
    REFrameworkTDBMethod table{}; table.invoke = fake_invoke;
    REFrameworkManagedObject objects{}; objects.add_ref = add_ref; objects.release = release; objects.is_managed_object = managed;
    REFrameworkSDKData data{}; data.method = &table; data.managed_object = &objects;
    REFrameworkPluginInitializeParam param{}; param.sdk = &data; API::initialize(&param); sdk = &data;
    for (int i = 0; i < 3; ++i) {
        methods.transform_get[i] = reinterpret_cast<Method*>(uintptr_t(1 + i)); methods.transform_set[i] = reinterpret_cast<Method*>(uintptr_t(4 + i));
        methods.joint_get[i] = reinterpret_cast<Method*>(uintptr_t(11 + i)); methods.joint_set[i] = reinterpret_cast<Method*>(uintptr_t(14 + i));
    }
    methods.game_object = reinterpret_cast<Method*>(20); methods.valid = reinterpret_cast<Method*>(21);
    methods.joint_valid = reinterpret_cast<Method*>(22); methods.mesh_asset = reinterpret_cast<Method*>(23);
    methods.material = reinterpret_cast<Method*>(24); methods.ready = reinterpret_cast<Method*>(25);
    methods.material_count = reinterpret_cast<Method*>(26); methods.material_get = reinterpret_cast<Method*>(27); methods.material_set = reinterpret_cast<Method*>(28);
    methods.mesh_asset_set = reinterpret_cast<Method*>(29); methods.material_resource_set = reinterpret_cast<Method*>(30);
    methods.resource_equals = reinterpret_cast<Method*>(31);
    methods.part_count = reinterpret_cast<Method*>(32); methods.part_get = reinterpret_cast<Method*>(33); methods.part_set = reinterpret_cast<Method*>(34);
    methods.enabled_get = reinterpret_cast<Method*>(35); methods.enabled_set = reinterpret_cast<Method*>(36);
    methods.draw_get = reinterpret_cast<Method*>(37); methods.draw_set = reinterpret_cast<Method*>(38);
    assert(avm_portrait_pose_version() == 3);
    assert(avm_portrait_mesh_copy(50, 60) == 0 && mesh_writes == 2); check_references(0); next_frame();
    assert(avm_portrait_mesh_copy(50, 50) == -1 && avm_portrait_mesh_copy(0, 60) == -1);
    for (auto id : {29, 30}) {
        fail_method = id; assert(avm_portrait_mesh_copy(50, 60) == -1); check_references(0); fail_method = 0;
    }
    null_asset = true; assert(avm_portrait_mesh_copy(50, 60) == -1); check_references(0); null_asset = false;
    ready = false; assert(avm_portrait_mesh_copy(50, 60) == -1); ready = true; next_frame();
    auto bind = [] { return avm_portrait_pose_bind({10}, {20}, {30}, {40}, {50}, {60}); };
    assert(bind() == 0); check_references(8); next_frame();
    assert(avm_portrait_pose_sync(10, -10000, 30) == 0); assert(reads == 6 && writes == 13 && copied_materials[0]);
    assert(!copied_enabled && copied_parts == parts && "Hidden source meshes and parts must not reappear in the portrait");
    enabled = true; draw_default = false; parts = {true, false, true, false};
    assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
    assert(copied_enabled && !copied_draw_default && copied_parts == parts && "Source visibility changes must reach copies on the next pose sync");
    assert(enabled && !draw_default && parts == (std::vector<bool>{true, false, true, false}));
    draw_default = true;
    materials[0] = false; assert(avm_portrait_pose_sync(10, -10000, 30) == 0); assert(!copied_materials[0]);
    auto before = writes;
    valid = false; assert(avm_portrait_pose_sync(10, -10000, 30) == 1); assert(writes == before); valid = true;
    joint_valid = false; assert(avm_portrait_pose_sync(10, -10000, 30) == 1); joint_valid = true;
    changed = true; assert(avm_portrait_pose_sync(10, -10000, 30) == 1); changed = false;
    material_changed = true; assert(avm_portrait_pose_sync(10, -10000, 30) == 1); material_changed = false;
    ready = false; assert(avm_portrait_pose_sync(10, -10000, 30) == 1); ready = true;
    material_count = 2; assert(avm_portrait_pose_sync(10, -10000, 30) == 1); material_count = materials.size();
    part_count = 3; assert(avm_portrait_pose_sync(10, -10000, 30) == 1); part_count = parts.size();
    fault = true; assert(avm_portrait_pose_sync(10, -10000, 30) == -1); fault = false;
    assert(writes == before);
    assert(avm_portrait_pose_bind({10}, {10}, {30}, {40}, {50}, {60}) == -1);
    assert(avm_portrait_pose_bind({10}, {20}, {30}, {20}, {50}, {60}) == -1);
    assert(avm_portrait_pose_bind({}, {}, {}, {}, {}, {}) == -1);
    assert(avm_portrait_pose_bind(std::vector<uintptr_t>(65,10), {}, {}, {}, {}, {}) == -1);
    assert(avm_portrait_pose_bind({10}, {20}, std::vector<uintptr_t>(8193,30), std::vector<uintptr_t>(8193,40), {50}, {60}) == -1);
    check_references(8); assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
    fail_method = 24; assert(bind() == -1); fail_method = 0; check_references(8);
    null_asset = true; assert(bind() == -1); null_asset = false; check_references(8);
    copy_part_count = 3; assert(bind() == -1); copy_part_count = parts.size(); check_references(8);
    part_count = 1025; assert(bind() == -1); part_count = parts.size(); check_references(8);
    for (auto id : {27, 28, 33, 34, 35, 36, 37, 38}) {
        if (id == 28) materials[0] = !materials[0];
        if (id == 34) parts[0] = !parts[0];
        if (id == 36) enabled = !enabled;
        if (id == 38) draw_default = !draw_default;
        fail_method = id; assert(avm_portrait_pose_sync(10, -10000, 30) == -1); fail_method = 0; check_references(8);
    }
    fail_method = 31; assert(avm_portrait_pose_sync(10, -10000, 30) == -1); fail_method = 0; check_references(8);
    for (int i = 0; i < 1000; ++i) {
        next_frame(); assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
        assert(bind() == 0); check_references(8);
    }
    // 即使资源路径相同，真正的资源身份更换仍应在任何姿态写入前触发重建。
    before = writes; changed = true; assert(avm_portrait_pose_sync(10, -10000, 30) == 1 && writes == before); changed = false;
    assert(equal_calls > 2000);

    // 用实际生产源码统计 256 部件网格；静态帧也必须逐帧读取源状态与完整 preflight。
    materials.resize(8, true); copied_materials = materials;
    parts.resize(256, false); copied_parts = parts;
    material_count = copy_material_count = materials.size(); part_count = copy_part_count = parts.size();
    copied_enabled = enabled; copied_draw_default = draw_default;
    const auto visibility_setters = [](const auto& value) { return value[28] + value[34] + value[36] + value[38]; };
    assert(bind() == 0); auto initial = calls;
    assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
    assert(visibility_setters(calls) - visibility_setters(initial) == 266 && "First sync must initialize even matching copy defaults");
    const auto static_start = calls; const auto pose_start = reads; const auto equals_start = equal_calls;
    for (int frame = 0; frame < 1000; ++frame) {
        next_frame(); assert(avm_portrait_pose_sync(10, -10000, 30) == 0); check_references(8);
    }
    const auto static_setters = visibility_setters(calls) - visibility_setters(static_start);
    int static_pose_setters{};
    for (auto id : {4, 5, 6, 14, 15, 16}) {
        const auto count = calls[id] - static_start[id]; assert(count == 1000); static_pose_setters += count;
    }
    std::printf("%s: first frame visibility setters=266; 1000 static frames material=%d part=%d draw=%d enabled=%d pose=%d\n",
        baseline ? "BASELINE" : "DIFF", calls[28] - static_start[28], calls[34] - static_start[34],
        calls[38] - static_start[38], calls[36] - static_start[36], static_pose_setters);
    std::fflush(stdout);
    assert(static_setters == (baseline ? 266000 : 0) && "Static frames must skip redundant visibility setters");
    assert(reads - pose_start == 6000 && equal_calls - equals_start == 2000);
    for (auto id : {20, 21, 22}) assert(calls[id] - static_start[id] == 2000);
    for (auto id : {23, 24, 25, 26, 31, 32}) assert(calls[id] - static_start[id] == (id == 31 ? 2000 : 1000));
    assert(calls[27] - static_start[27] == 8000 && calls[33] - static_start[33] == 256000);
    assert(calls[35] - static_start[35] == 1000 && calls[37] - static_start[37] == 1000);

    if (!baseline) {
        // 只改一个材质、一个部件与两个组件值，下一帧恰好传达四项变化。
        materials[6] = !materials[6]; parts[200] = !parts[200]; enabled = !enabled; draw_default = !draw_default;
        const auto source_materials = materials, source_parts = parts;
        auto start = calls;
        assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
        for (auto id : {28, 34, 36, 38}) assert(calls[id] - start[id] == 1);
        assert(copied_materials == materials && copied_parts == parts && copied_enabled == enabled && copied_draw_default == draw_default);
        assert(materials == source_materials && parts == source_parts);
        start = calls; assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
        assert(visibility_setters(calls) == visibility_setters(start));

        // 冷缓存的中途失败不能提交失败项；已成功项不重复写，后续项和失败项下帧补齐。
        for (const auto status_error : {false, true}) for (auto id : {28, 34, 38, 36}) {
            assert(bind() == 0);
            copied_materials.assign(8, false); copied_parts.assign(256, true);
            copied_enabled = !enabled; copied_draw_default = !draw_default;
            fail_method = id; fail_index = (id == 28 || id == 34) ? 1 : UINTPTR_MAX; fail_status = status_error;
            assert(avm_portrait_pose_sync(10, -10000, 30) == -1); check_references(8);
            fail_method = 0; fail_index = UINTPTR_MAX; fail_status = false; start = calls;
            assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
            assert(calls[id] - start[id] == (id == 28 ? 7 : id == 34 ? 255 : 1));
            assert(copied_materials == materials && copied_parts == parts && copied_enabled == enabled && copied_draw_default == draw_default);
            start = calls; assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
            assert(visibility_setters(calls) == visibility_setters(start));
        }

        // 热缓存部分更新失败时，仅重试未成功的变更，不遗失第二个索引。
        for (auto id : {28, 34}) {
            auto& source = id == 28 ? materials : parts; auto& copy = id == 28 ? copied_materials : copied_parts;
            source[0] = !source[0]; source[1] = !source[1];
            fail_method = id; fail_index = 1; start = calls;
            assert(avm_portrait_pose_sync(10, -10000, 30) == -1);
            assert(calls[id] - start[id] == 2 && copy[0] == source[0] && copy[1] != source[1]);
            fail_method = 0; fail_index = UINTPTR_MAX; start = calls;
            assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
            assert(calls[id] - start[id] == 1 && copy == source);
        }

        // 布局变更先返回重建，不写任何姿态或显隐；重绑定与 clear 后必须重新完整初始化。
        before = writes; material_count = 7;
        assert(avm_portrait_pose_sync(10, -10000, 30) == 1 && writes == before); material_count = 8;
        part_count = 255; assert(avm_portrait_pose_sync(10, -10000, 30) == 1 && writes == before); part_count = 256;
        for (auto clear : {false, true}) {
            if (clear) { avm_portrait_pose_clear(); check_references(0); }
            assert(bind() == 0); start = calls;
            assert(avm_portrait_pose_sync(10, -10000, 30) == 0);
            assert(visibility_setters(calls) - visibility_setters(start) == 266); check_references(8);
        }
        std::puts("PASS: 1000 static frames skip 266000 visibility setters; four source toggles reach next frame with four setters; cold/hot failure retry, SDK status/exception, full rebind/clear initialization");
    }
    check_references(8); avm_portrait_pose_clear(); avm_portrait_pose_clear(); check_references(0); next_frame(); assert(holders.empty());
    assert(avm_portrait_pose_sync(10, -10000, 30) == -1);
    std::puts("PASS: production resource/pose batch, mesh enabled/default-draw/part/material visibility, next-frame source toggles, layout invalidation before writes, source read-only, 1000-frame ref balance, transactional rebind and stop");
}
