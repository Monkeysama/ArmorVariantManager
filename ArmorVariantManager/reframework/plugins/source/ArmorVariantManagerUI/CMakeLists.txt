cmake_minimum_required(VERSION 3.25)
project(ArmorVariantManager_UI)

# 旧 UI 保留 D2D/输入桥接；预览以独立 DLL 构建，不共享 GPU/pose 实例。
include(../ArmorVariantManagerPortrait/LuaDependencies.cmake)
CPMAddPackage("gh:nemtrif/utfcpp@4.0.5")

set(AVM_D2D_SRC upstream/reframework-d2d/src)
add_library(ArmorVariantManager_UI SHARED
    BridgeRuntime.cpp
    ${AVM_D2D_SRC}/D2DFont.cpp
    ${AVM_D2D_SRC}/D2DImage.cpp
    ${AVM_D2D_SRC}/D2DPainter.cpp
    ${AVM_D2D_SRC}/D3D12Renderer.cpp
    ${AVM_D2D_SRC}/DrawList.cpp
    ${AVM_D2D_SRC}/Plugin.cpp
    ${AVM_D2D_SRC}/D3D12CommandContext.cpp
)
target_include_directories(ArmorVariantManager_UI PRIVATE
    .
    ${AVM_D2D_SRC}
    upstream/reframework-d2d/deps/reframework/include
)
target_compile_features(ArmorVariantManager_UI PRIVATE cxx_std_20)
target_compile_options(ArmorVariantManager_UI PRIVATE /utf-8)
target_link_libraries(ArmorVariantManager_UI PRIVATE avm_lua utf8cpp sol2::sol2 d2d1 dwrite d3d11 d3d12 dxgi d3dcompiler user32 imm32)

include(CTest)
add_subdirectory(../ArmorVariantManagerPortrait Portrait)
