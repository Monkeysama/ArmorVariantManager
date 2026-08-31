cmake_minimum_required(VERSION 3.25)
project(ArmorVariantManager_UI)

# 沿用上游 reframework-d2d 的依赖声明，并将本项目桥接模块编入同一 DLL。
include(upstream/reframework-d2d/cmake/CPM.cmake)

CPMAddPackage("gh:nemtrif/utfcpp@4.0.5")
CPMAddPackage("gh:ThePhD/sol2@3.3.0")
CPMAddPackage(NAME lua GITHUB_REPOSITORY lua/lua VERSION 5.4.3 DOWNLOAD_ONLY YES)

file(GLOB lua_sources ${lua_SOURCE_DIR}/*.c)
list(REMOVE_ITEM lua_sources "${lua_SOURCE_DIR}/lua.c" "${lua_SOURCE_DIR}/luac.c" "${lua_SOURCE_DIR}/onelua.c")
add_library(avm_lua STATIC ${lua_sources})
target_include_directories(avm_lua PUBLIC ${lua_SOURCE_DIR})

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

