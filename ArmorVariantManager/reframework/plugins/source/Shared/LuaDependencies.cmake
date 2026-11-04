include_guard(GLOBAL)

# 固定 Lua/sol2 版本并复用下载缓存，预览独立构建。
include(${CMAKE_CURRENT_LIST_DIR}/CPM.cmake)
CPMAddPackage("gh:ThePhD/sol2@3.3.0")
CPMAddPackage(NAME lua GITHUB_REPOSITORY lua/lua VERSION 5.4.3 DOWNLOAD_ONLY YES)

file(GLOB lua_sources ${lua_SOURCE_DIR}/*.c)
list(REMOVE_ITEM lua_sources "${lua_SOURCE_DIR}/lua.c" "${lua_SOURCE_DIR}/luac.c" "${lua_SOURCE_DIR}/onelua.c")
add_library(avm_lua STATIC ${lua_sources})
target_include_directories(avm_lua PUBLIC ${lua_SOURCE_DIR})
