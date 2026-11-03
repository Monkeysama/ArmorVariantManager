add_library(PortraitHostFixture SHARED HostFixture.cpp)
set_target_properties(PortraitHostFixture PROPERTIES OUTPUT_NAME ArmorVariantManager_UI
    RUNTIME_OUTPUT_DIRECTORY ${CMAKE_CURRENT_BINARY_DIR}/host)

add_executable(PortraitPluginTest PluginTest.cpp)
target_link_libraries(PortraitPluginTest PRIVATE avm_lua sol2::sol2)
target_include_directories(PortraitPluginTest PRIVATE ${AVM_SDK_INCLUDE})
target_compile_features(PortraitPluginTest PRIVATE cxx_std_20)
target_compile_options(PortraitPluginTest PRIVATE /utf-8 /UNDEBUG)
foreach(order bridge-first portrait-first)
    add_test(NAME portrait_plugin_${order} COMMAND PortraitPluginTest
        $<TARGET_FILE:ArmorVariantManager_Portrait> $<TARGET_FILE:PortraitHostFixture> ${order})
endforeach()

add_executable(PortraitGpuTest GpuTest.cpp)
target_include_directories(PortraitGpuTest PRIVATE ${AVM_SDK_INCLUDE})
target_compile_features(PortraitGpuTest PRIVATE cxx_std_20)
target_compile_options(PortraitGpuTest PRIVATE /utf-8)
target_link_libraries(PortraitGpuTest PRIVATE d3d12 dxgi d3dcompiler user32)
add_test(NAME portrait_gpu_sdr8 COMMAND PortraitGpuTest --srgb --edge --alpha-half)
add_test(NAME portrait_gpu_hd_sdr10 COMMAND PortraitGpuTest --hd-source --srgb --ten --full-height)

add_executable(PortraitPoseTest PoseTest.cpp)
target_include_directories(PortraitPoseTest PRIVATE ${AVM_SDK_INCLUDE})
target_compile_features(PortraitPoseTest PRIVATE cxx_std_20)
target_compile_options(PortraitPoseTest PRIVATE /utf-8 /UNDEBUG)
add_test(NAME portrait_pose COMMAND PortraitPoseTest)
