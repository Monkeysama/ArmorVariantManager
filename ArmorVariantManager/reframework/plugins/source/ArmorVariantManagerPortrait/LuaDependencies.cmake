include_guard(GLOBAL)

# 与旧 UI 共用 Lua/sol2 的版本与下载缓存，独立构建时不引入 D2D。
include(${CMAKE_CURRENT_LIST_DIR}/../ArmorVariantManagerUI/upstream/reframework-d2d/cmake/CPM.cmake)
CPMAddPackage("gh:ThePhD/sol2@3.3.0")
CPMAddPackage(NAME lua GITHUB_REPOSITORY lua/lua VERSION 5.4.3 DOWNLOAD_ONLY YES)

file(GLOB lua_sources ${lua_SOURCE_DIR}/*.c)
list(REMOVE_ITEM lua_sources "${lua_SOURCE_DIR}/lua.c" "${lua_SOURCE_DIR}/luac.c" "${lua_SOURCE_DIR}/onelua.c")
add_library(avm_lua STATIC ${lua_sources})
target_include_directories(avm_lua PUBLIC ${lua_SOURCE_DIR})
