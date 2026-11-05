#include "PortraitPose.hpp"
#include <reframework/API.hpp>
#include <array>
#include <cmath>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <unordered_set>

namespace portrait_pose {
using API = reframework::API;
using Object = API::ManagedObject;
using Method = API::Method;
struct Vec3 { float x, y, z; };
const REFrameworkSDKData* sdk{};
struct Methods {
    Method *transform_get[3]{}, *transform_set[3]{}, *joint_get[3]{}, *joint_set[3]{};
    Method *game_object{}, *valid{}, *joint_valid{}, *mesh_asset{}, *mesh_asset_set{}, *material{}, *material_resource_set{}, *resource_equals{};
    Method *ready{}, *material_count{}, *material_get{}, *material_set{};
    Method *part_count{}, *part_get{}, *part_set{}, *enabled_get{}, *enabled_set{}, *draw_get{}, *draw_set{};
} methods;
thread_local std::string failure;

Method* find(const char* type, const std::string& name) {
    auto definition = API::get()->tdb()->find_type(type);
    auto method = definition ? definition->find_method(name) : nullptr;
    if (!method) throw std::runtime_error("Missing portrait pose method: " + std::string(type) + "." + name);
    return method;
}

// 使用公开 SDK 的参数与返回值契约；不调用猜测的地址，也不直接改写骨架内存。
void initialize() {
    if (sdk) return;
    Methods next{};
    const char* fields[]{ "Position", "Rotation", "Scale" };
    for (int i = 0; i < 3; ++i) {
        next.transform_get[i] = find("via.Transform", std::string("get_") + fields[i]);
        next.transform_set[i] = find("via.Transform", std::string("set_") + (i == 2 ? "LocalScale" : fields[i]));
        next.joint_get[i] = find("via.Joint", std::string("get_") + (i == 2 ? "LocalScale" : fields[i]));
        next.joint_set[i] = find("via.Joint", std::string("set_") + (i == 2 ? "LocalScale" : fields[i]));
    }
    next.game_object = find("via.Transform", "get_GameObject");
    next.valid = find("via.GameObject", "get_Valid");
    next.joint_valid = find("via.Joint", "get_Valid");
    next.mesh_asset = find("via.render.Mesh", "getMesh");
    next.mesh_asset_set = find("via.render.Mesh", "setMesh");
    next.material = find("via.render.Mesh", "get_Material");
    next.material_resource_set = find("via.render.Mesh", "set_Material");
    next.resource_equals = find("via.ResourceHolder", "equals");
    next.ready = find("via.render.Mesh", "get_ReadyToDraw");
    next.material_count = find("via.render.Mesh", "getMaterialsEnableCount");
    next.material_get = find("via.render.Mesh", "getMaterialsEnable");
    next.material_set = find("via.render.Mesh", "setMaterialsEnable");
    next.part_count = find("via.render.Mesh", "getPartsEnableCount");
    next.part_get = find("via.render.Mesh", "getPartsEnable");
    next.part_set = find("via.render.Mesh", "setPartsEnable");
    next.enabled_get = find("via.render.Mesh", "get_Enabled");
    next.enabled_set = find("via.render.Mesh", "set_Enabled");
    next.draw_get = find("via.render.Mesh", "get_DrawDefault");
    next.draw_set = find("via.render.Mesh", "set_DrawDefault");
    methods = next;
    sdk = API::get()->sdk();
}

reframework::InvokeRet invoke(Method* method, uintptr_t object, std::initializer_list<void*> args = {}) {
    reframework::InvokeRet result{};
    auto status = sdk->method->invoke(*method, reinterpret_cast<void*>(object), const_cast<void**>(args.begin()),
        static_cast<unsigned>(args.size() * sizeof(void*)), &result, sizeof(result));
    if (status != REFRAMEWORK_ERROR_NONE || result.exception_thrown) throw std::runtime_error("Portrait pose engine invocation failed");
    return result;
}
uintptr_t pointer(const reframework::InvokeRet& value) { return reinterpret_cast<uintptr_t>(value.ptr); }

// getter 返回的是局部 holder；显式引用只覆盖使用区间，不把临时地址当作资源身份。
struct ResourceRef {
    uintptr_t address;
    explicit ResourceRef(uintptr_t value) : address(value) {
        auto object = reinterpret_cast<Object*>(value);
        if (!object || !sdk->managed_object->is_managed_object(object)) throw std::runtime_error("Invalid portrait resource holder");
        object->add_ref();
    }
    ~ResourceRef() { reinterpret_cast<Object*>(address)->release(); }
    ResourceRef(const ResourceRef&) = delete;
    ResourceRef& operator=(const ResourceRef&) = delete;
};

bool same_resource(Method* getter, uintptr_t mesh, uintptr_t expected) {
    ResourceRef current(pointer(invoke(getter, mesh)));
    return invoke(methods.resource_equals, 0,
        { reinterpret_cast<void*>(expected), reinterpret_cast<void*>(current.address) }).byte != 0;
}

struct Pair { uintptr_t source, copy; };
struct Mesh {
    uintptr_t source, copy, asset, material;
    uint64_t materials, parts;
    // 2 表示尚未写入；每次绑定重新初始化，仅在副本 setter 成功后缓存 0/1。
    std::vector<uint8_t> material_visibility, part_visibility;
    uint8_t enabled{2}, draw{2};
    // 形态键权重镜像(avm_portrait_blend_sync):首次同步时确定通道数,只缓存副本 setter 成功写入的值。
    bool blend_ready{false};
    uint64_t blend_count{};
    std::vector<float> blend;
    std::vector<uint8_t> blend_written;
};

// 形态键方法单独、按需查找:不进 initialize(),姿态同步(荒野在用)不依赖它们。
struct BlendMethods { Method *count{}, *get{}, *set{}; } blend_methods;
void initialize_blend() {
    if (blend_methods.count) return;
    BlendMethods next{};
    next.count = find("via.render.Mesh", "get_BlendShapeChannelWeightCount");
    next.get = find("via.render.Mesh", "getBlendShapeChannelWeightParam");
    next.set = find("via.render.Mesh", "setBlendShapeChannelWeightParam");
    blend_methods = next;
}
// System.Single 的参数和返回值在 invoke 包装里都是 double(REFramework 源码 Method.cpp / Sdk.cpp 的注释:
// "the invoke wrappers ALWAYS expect a double");按 float 读写会读到 0、写进极小值。
void* single_arg(float value) { const double d = value; uintptr_t slot{}; std::memcpy(&slot, &d, sizeof(d)); return reinterpret_cast<void*>(slot); }
float single_ret(const reframework::InvokeRet& value) { return static_cast<float>(value.d); }
struct Binding {
    std::vector<Pair> transforms, joints;
    std::vector<Mesh> meshes;
    std::vector<Object*> retained;
    ~Binding() { for (auto object : retained) object->release(); }
    void retain(uintptr_t value) {
        auto object = reinterpret_cast<Object*>(value);
        if (!object || !sdk->managed_object->is_managed_object(object)) throw std::runtime_error("Invalid portrait pose object");
        object->add_ref();
        retained.push_back(object);
    }
};
std::unique_ptr<Binding> binding;

void append(Binding& next, std::vector<Pair>& pairs, const std::vector<uintptr_t>& source, const std::vector<uintptr_t>& copy) {
    for (size_t i = 0; i < source.size(); ++i) {
        next.retain(source[i]); next.retain(copy[i]);
        pairs.push_back({ source[i], copy[i] });
    }
}

// 引擎装备约束后的世界姿态才是最终外观；复制局部姿态会使装备副本塌缩。
void pose(const std::vector<Pair>& pairs, Method* const* get, Method* const* set, Vec3 offset) {
    for (auto pair : pairs) for (int field = 0; field < 3; ++field) {
        auto value = invoke(get[field], pair.source);
        if (field == 0) {
            Vec3 position{}; std::memcpy(&position, value.bytes.data(), sizeof(position));
            position.x += offset.x; position.y += offset.y; position.z += offset.z;
            std::memcpy(value.bytes.data(), &position, sizeof(position));
        }
        invoke(set[field], pair.copy, { value.bytes.data() });
    }
}
}

int avm_portrait_pose_version() { return 3; }
int avm_portrait_blend_version() { return 1; }

// 把原网格的形态键(blend shape)通道权重镜像到副本:SKS、游戏或其他 MOD 写在原网格实例上的权重,
// 副本网格是另一个实例拿不到。在 pose_sync 之后调用,只写变化了的通道。
// 两边通道数不同(或超过 4096)的网格跳过;返回 0 成功,-1 失败(错误见 avm_portrait_pose_error)。
int avm_portrait_blend_sync() {
    using namespace portrait_pose;
    try {
        if (!binding) throw std::runtime_error("Portrait pose binding unavailable");
        initialize_blend();
        for (auto& mesh : binding->meshes) {
            if (!mesh.blend_ready) {
                const auto count = invoke(blend_methods.count, mesh.source).qword;
                mesh.blend_count = count <= 4096 && count == invoke(blend_methods.count, mesh.copy).qword ? count : 0;
                mesh.blend.assign(mesh.blend_count, 0.0f);
                mesh.blend_written.assign(mesh.blend_count, 0);
                mesh.blend_ready = true;
            }
            for (uint64_t i = 0; i < mesh.blend_count; ++i) {
                const float value = single_ret(invoke(blend_methods.get, mesh.source, { reinterpret_cast<void*>(i) }));
                if (mesh.blend_written[i] && mesh.blend[i] == value) continue;
                invoke(blend_methods.set, mesh.copy, { reinterpret_cast<void*>(i), single_arg(value) });
                mesh.blend[i] = value; mesh.blend_written[i] = 1;
            }
        }
        failure.clear(); return 0;
    } catch (const std::exception& error) { failure = error.what(); return -1; }
}
const char* avm_portrait_pose_error() { return portrait_pose::failure.c_str(); }
void avm_portrait_pose_clear() { portrait_pose::binding.reset(); }

// 在同一次公开 SDK 调用内取得并赋予资源，Lua 不再跨更新保存引擎局部 holder。
int avm_portrait_mesh_copy(uintptr_t source_mesh, uintptr_t copy_mesh) {
    using namespace portrait_pose;
    try {
        if (!source_mesh || !copy_mesh || source_mesh == copy_mesh) throw std::runtime_error("Invalid portrait mesh copy target");
        initialize();
        if (!invoke(methods.ready, source_mesh).byte) throw std::runtime_error("Portrait source mesh is not ready");
        ResourceRef asset(pointer(invoke(methods.mesh_asset, source_mesh)));
        invoke(methods.mesh_asset_set, copy_mesh, { reinterpret_cast<void*>(asset.address) });
        ResourceRef material(pointer(invoke(methods.material, source_mesh)));
        invoke(methods.material_resource_set, copy_mesh, { reinterpret_cast<void*>(material.address) });
        failure.clear(); return 0;
    } catch (const std::exception& error) { failure = error.what(); return -1; }
}

// 一次绑定，逐帧批量同步；所有目标都必须与原网格/骨骼分离，装备替换时重新绑定。
int avm_portrait_pose_bind(const std::vector<uintptr_t>& st, const std::vector<uintptr_t>& ct,
    const std::vector<uintptr_t>& sj, const std::vector<uintptr_t>& cj,
    const std::vector<uintptr_t>& sm, const std::vector<uintptr_t>& cm) {
    using namespace portrait_pose;
    try {
        if (st.empty() || st.size() > 64 || st.size() != ct.size() || sm.size() != st.size() || sm.size() != cm.size()
            || sj.size() > 8192 || sj.size() != cj.size()) throw std::runtime_error("Invalid portrait pose batch");
        std::unordered_set<uintptr_t> sources(st.begin(), st.end()), targets;
        sources.insert(sj.begin(), sj.end()); sources.insert(sm.begin(), sm.end());
        for (auto list : { &ct, &cj, &cm }) for (auto target : *list)
            if (!target || sources.contains(target) || !targets.insert(target).second) throw std::runtime_error("Portrait pose target aliases source or another target");
        initialize();
        auto next = std::make_unique<Binding>();
        append(*next, next->transforms, st, ct); append(*next, next->joints, sj, cj);
        for (size_t i = 0; i < sm.size(); ++i) {
            next->retain(sm[i]); next->retain(cm[i]);
            auto count = invoke(methods.material_count, sm[i]).qword;
            if (count > 1024 || count != invoke(methods.material_count, cm[i]).qword) throw std::runtime_error("Portrait material layout mismatch");
            auto parts = invoke(methods.part_count, sm[i]).qword;
            if (parts > 1024 || parts != invoke(methods.part_count, cm[i]).qword) throw std::runtime_error("Portrait part layout mismatch");
            const auto asset = pointer(invoke(methods.mesh_asset, cm[i])); next->retain(asset);
            const auto material = pointer(invoke(methods.material, cm[i])); next->retain(material);
            next->meshes.push_back({ sm[i], cm[i], asset, material, count, parts,
                std::vector<uint8_t>(count, 2), std::vector<uint8_t>(parts, 2) });
        }
        binding = std::move(next); failure.clear();
        return 0;
    } catch (const std::exception& error) { failure = error.what(); return -1; }
}

// 返回 1 表示原装备已经更换，交回游戏更新阶段重建；异常返回 -1 并由控制器停止预览。
int avm_portrait_pose_sync(float dx, float dy, float dz) {
    using namespace portrait_pose;
    try {
        if (!binding || !std::isfinite(dx) || !std::isfinite(dy) || !std::isfinite(dz)) throw std::runtime_error("Portrait pose binding unavailable");
        for (auto pair : binding->transforms) {
            auto source = pointer(invoke(methods.game_object, pair.source));
            auto copy = pointer(invoke(methods.game_object, pair.copy));
            if (!source || !copy || !invoke(methods.valid, source).byte || !invoke(methods.valid, copy).byte) return 1;
        }
        for (const auto& mesh : binding->meshes)
            if (!invoke(methods.ready, mesh.source).byte || !same_resource(methods.mesh_asset, mesh.source, mesh.asset)
                || !same_resource(methods.material, mesh.source, mesh.material)
                || invoke(methods.material_count, mesh.source).qword != mesh.materials
                || invoke(methods.part_count, mesh.source).qword != mesh.parts) return 1;
        for (auto pair : binding->joints)
            if (!invoke(methods.joint_valid, pair.source).byte || !invoke(methods.joint_valid, pair.copy).byte) return 1;
        pose(binding->transforms, methods.transform_get, methods.transform_set, { dx, dy, dz });
        pose(binding->joints, methods.joint_get, methods.joint_set, { dx, dy, dz });
        for (auto& mesh : binding->meshes) for (uint64_t i = 0; i < mesh.materials; ++i) {
            const auto visible = static_cast<uint8_t>(invoke(methods.material_get, mesh.source, { reinterpret_cast<void*>(i) }).byte != 0);
            if (mesh.material_visibility[i] != visible) {
                invoke(methods.material_set, mesh.copy, { reinterpret_cast<void*>(i), reinterpret_cast<void*>(static_cast<uintptr_t>(visible)) });
                mesh.material_visibility[i] = visible;
            }
        }
        // 材质开关不能代替部件或组件开关；只同步到副本，避免隐藏道具被默认全部启用。
        for (auto& mesh : binding->meshes) {
            for (uint64_t i = 0; i < mesh.parts; ++i) {
                const auto visible = static_cast<uint8_t>(invoke(methods.part_get, mesh.source, { reinterpret_cast<void*>(i) }).byte != 0);
                if (mesh.part_visibility[i] != visible) {
                    invoke(methods.part_set, mesh.copy, { reinterpret_cast<void*>(i), reinterpret_cast<void*>(static_cast<uintptr_t>(visible)) });
                    mesh.part_visibility[i] = visible;
                }
            }
            const auto draw = static_cast<uint8_t>(invoke(methods.draw_get, mesh.source).byte != 0);
            if (mesh.draw != draw) {
                invoke(methods.draw_set, mesh.copy, { reinterpret_cast<void*>(static_cast<uintptr_t>(draw)) });
                mesh.draw = draw;
            }
            const auto enabled = static_cast<uint8_t>(invoke(methods.enabled_get, mesh.source).byte != 0);
            if (mesh.enabled != enabled) {
                invoke(methods.enabled_set, mesh.copy, { reinterpret_cast<void*>(static_cast<uintptr_t>(enabled)) });
                mesh.enabled = enabled;
            }
        }
        return 0;
    } catch (const std::exception& error) { failure = error.what(); return -1; }
}
