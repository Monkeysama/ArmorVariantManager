#pragma once
#include <string>
#include <string_view>

// 游戏目录下 mod 的 mdf2(natives/STM/...mdf2.<版本>)的读写。REFramework 的 Lua io 限制在 reframework/data 里,
// RE4 调色的「导出 mdf2 材质预设」「替换 mdf」要读写 mod 的 mdf2,所以由原生插件做。
// 所有路径都是相对游戏目录的:只放行 natives/ 下的 .mdf2.<版本号>,不接受绝对路径、盘符、".."、空段;大小上限 16 MB。
namespace avm_game_files {
// 路径是否允许(纯函数,便于测试)
bool allowed(std::string_view relative);
// 是否是重载副本的名字:<名字>_avmr<数字>.mdf2.<版本>
bool is_reload_copy(std::string_view relative);

// 读整个文件。成功返回 true 并填 data;失败返回 false 并填 error
bool read(std::string_view relative, std::string& data, std::string& error);
// 文件是否存在(松散文件)
bool exists(std::string_view relative);
// 覆盖已存在的文件(不新建)。第一次覆盖前把原文件拷成 <文件>.avm_bak(之后不再动它);先写临时文件再替换
bool overwrite(std::string_view relative, std::string_view data, std::string& error);
// 写重载副本(只接受 is_reload_copy 的名字,可以新建)
bool write_reload_copy(std::string_view relative, std::string_view data, std::string& error);
// 删掉 original 同目录下它的重载副本(keep 这个除外)。返回删掉的个数
int remove_reload_copies(std::string_view original, std::string_view keep);
}
