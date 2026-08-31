#pragma once

#include <windows.h>

#include <string>

// 启动和停止光标、原生输入桥接；由 UI Runtime 的唯一 DLL 入口调用。
void avm_bridge_initialize(HMODULE module);
void avm_bridge_shutdown();

// 注册独立 Lua 项目的运行时目录。目录相对于 reframework/data，路径会被校验并隔离。
bool avm_bridge_register_runtime(const std::string& client_id, const std::string& runtime_directory);

// 注销已停止使用桥接的项目，避免旧状态文件持续参与输入阻断与原生文本选择。
bool avm_bridge_unregister_runtime(const std::string& client_id);
