cmake_minimum_required(VERSION 3.25)
project(ArmorVariantManager_Portrait)

include(LuaDependencies.cmake)
set(AVM_SDK_INCLUDE ${CMAKE_CURRENT_SOURCE_DIR}/../ArmorVariantManagerUI/upstream/reframework-d2d/deps/reframework/include)

add_library(ArmorVariantManager_Portrait SHARED Plugin.cpp PortraitPreview.cpp PortraitPose.cpp)
target_include_directories(ArmorVariantManager_Portrait PRIVATE ${AVM_SDK_INCLUDE})
target_compile_features(ArmorVariantManager_Portrait PRIVATE cxx_std_20)
target_compile_options(ArmorVariantManager_Portrait PRIVATE /utf-8)
target_link_libraries(ArmorVariantManager_Portrait PRIVATE avm_lua sol2::sol2 d3d12 dxgi d3dcompiler)

include(CTest)
if(BUILD_TESTING)
    add_subdirectory(tests)
endif()
