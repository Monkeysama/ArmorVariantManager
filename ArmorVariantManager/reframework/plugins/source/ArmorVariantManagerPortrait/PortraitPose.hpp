#pragma once
#include <cstdint>
#include <vector>

// 只同步 Lua 创建的显示副本；与 GPU 采样分离，不保存玩家或预设数据。
int avm_portrait_pose_version();
int avm_portrait_mesh_copy(uintptr_t source_mesh, uintptr_t copy_mesh);
int avm_portrait_pose_bind(const std::vector<uintptr_t>& source_transforms, const std::vector<uintptr_t>& copy_transforms,
    const std::vector<uintptr_t>& source_joints, const std::vector<uintptr_t>& copy_joints,
    const std::vector<uintptr_t>& source_meshes, const std::vector<uintptr_t>& copy_meshes);
int avm_portrait_pose_sync(float dx, float dy, float dz);
int avm_portrait_blend_version();
int avm_portrait_blend_sync();
void avm_portrait_pose_clear();
const char* avm_portrait_pose_error();
