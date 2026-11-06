#include "GameFiles.hpp"
#include <windows.h>
#include <algorithm>
#include <cctype>
#include <cstdint>
#include <filesystem>
#include <fstream>

namespace avm_game_files {
namespace {
constexpr std::uintmax_t MAX_SIZE = 16u * 1024u * 1024u;
namespace fs = std::filesystem;

std::string lower(std::string_view s) {
    std::string out(s);
    std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return out;
}

// 游戏 exe 所在目录
fs::path game_dir() {
    std::wstring buffer(MAX_PATH, L'\0');
    for (;;) {
        const DWORD n = GetModuleFileNameW(nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
        if (n == 0) return {};
        if (n < buffer.size()) { buffer.resize(n); break; }
        buffer.resize(buffer.size() * 2);
    }
    return fs::path(buffer).parent_path();
}

std::wstring widen(std::string_view utf8) {
    if (utf8.empty()) return {};
    const int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()), nullptr, 0);
    if (n <= 0) return {};
    std::wstring out(static_cast<size_t>(n), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, utf8.data(), static_cast<int>(utf8.size()), out.data(), n);
    return out;
}

std::string utf8_of(const fs::path& p) {
    const auto s = p.u8string();
    return std::string(s.begin(), s.end());
}

// 允许的相对路径 → 绝对路径;不允许时返回空
fs::path resolve(std::string_view relative) {
    if (!allowed(relative)) return {};
    const auto base = game_dir();
    const std::wstring wide = widen(relative);
    if (base.empty() || wide.empty()) return {};
    return base / fs::path(wide);
}

// 文件名拆成 <名字>、<版本>(xxx.mdf2.32 → xxx、32)
bool split_name(const std::string& file, std::string& stem, std::string& version) {
    const size_t at = file.rfind(".mdf2.");
    if (at == std::string::npos) return false;
    stem = file.substr(0, at);
    version = file.substr(at + 6);
    return true;
}

bool write_file(const fs::path& path, std::string_view data, std::string& error) {
    if (data.size() > MAX_SIZE) { error = "data too large"; return false; }
    fs::path tmp = path;
    tmp += L".avm_tmp";
    {
        std::ofstream file(tmp, std::ios::binary | std::ios::trunc);
        if (!file) { error = "cannot create file"; return false; }
        if (!data.empty() && !file.write(data.data(), static_cast<std::streamsize>(data.size()))) {
            error = "write failed";
            file.close();
            std::error_code ec;
            fs::remove(tmp, ec);
            return false;
        }
    }
    if (!MoveFileExW(tmp.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        error = "replace failed";
        std::error_code ec;
        fs::remove(tmp, ec);
        return false;
    }
    return true;
}
}

bool allowed(std::string_view relative) {
    if (relative.empty() || relative.size() > 512) return false;
    for (const char c : relative) {
        if (c == ':' || c == '\0') return false;   // 盘符、流名
    }
    if (relative.front() == '/' || relative.front() == '\\') return false;
    std::string path = lower(relative);
    std::replace(path.begin(), path.end(), '\\', '/');
    if (path.rfind("natives/", 0) != 0) return false;
    size_t start = 0;
    while (start <= path.size()) {
        const size_t end = path.find('/', start);
        const std::string_view part(path.data() + start, (end == std::string::npos ? path.size() : end) - start);
        if (part.empty() || part == "." || part == "..") return false;
        if (end == std::string::npos) break;
        start = end + 1;
    }
    const size_t at = path.rfind(".mdf2.");
    if (at == std::string::npos) return false;
    const std::string_view version(path.data() + at + 6, path.size() - at - 6);
    if (version.empty() || version.size() > 4) return false;
    return std::all_of(version.begin(), version.end(), [](unsigned char c) { return std::isdigit(c) != 0; });
}

bool is_reload_copy(std::string_view relative) {
    if (!allowed(relative)) return false;
    std::string path = lower(relative);
    std::replace(path.begin(), path.end(), '\\', '/');
    std::string stem, version;
    if (!split_name(path, stem, version)) return false;
    const size_t at = stem.rfind("_avmr");
    if (at == std::string::npos || at + 5 >= stem.size()) return false;
    return std::all_of(stem.begin() + static_cast<std::ptrdiff_t>(at + 5), stem.end(), [](unsigned char c) { return std::isdigit(c) != 0; });
}

bool read(std::string_view relative, std::string& data, std::string& error) {
    data.clear();
    const auto full = resolve(relative);
    if (full.empty()) { error = "path not allowed"; return false; }
    std::error_code ec;
    if (!fs::is_regular_file(full, ec)) { error = "not found"; return false; }
    const auto size = fs::file_size(full, ec);
    if (ec) { error = "cannot stat file"; return false; }
    if (size > MAX_SIZE) { error = "file too large"; return false; }
    std::ifstream file(full, std::ios::binary);
    if (!file) { error = "cannot open file"; return false; }
    data.resize(static_cast<size_t>(size));
    if (size > 0 && !file.read(data.data(), static_cast<std::streamsize>(size))) {
        data.clear();
        error = "read failed";
        return false;
    }
    return true;
}

bool exists(std::string_view relative) {
    const auto full = resolve(relative);
    std::error_code ec;
    return !full.empty() && fs::is_regular_file(full, ec);
}

bool overwrite(std::string_view relative, std::string_view data, std::string& error) {
    const auto full = resolve(relative);
    if (full.empty() || is_reload_copy(relative)) { error = "path not allowed"; return false; }
    std::error_code ec;
    if (!fs::is_regular_file(full, ec)) { error = "not found"; return false; }
    fs::path backup = full;
    backup += L".avm_bak";
    if (!fs::exists(backup, ec)) {
        if (!fs::copy_file(full, backup, fs::copy_options::none, ec)) { error = "backup failed"; return false; }
    }
    return write_file(full, data, error);
}

bool write_reload_copy(std::string_view relative, std::string_view data, std::string& error) {
    if (!is_reload_copy(relative)) { error = "path not allowed"; return false; }
    const auto full = resolve(relative);
    if (full.empty()) { error = "path not allowed"; return false; }
    std::error_code ec;
    if (!fs::is_directory(full.parent_path(), ec)) { error = "directory not found"; return false; }
    return write_file(full, data, error);
}

int remove_reload_copies(std::string_view original, std::string_view keep) {
    const auto full = resolve(original);
    if (full.empty() || is_reload_copy(original)) return 0;
    std::string stem, version;
    if (!split_name(lower(utf8_of(full.filename())), stem, version)) return 0;
    const std::string keep_name = keep.empty() ? std::string() : lower(utf8_of(fs::path(widen(keep)).filename()));
    int removed = 0;
    std::error_code ec;
    for (const auto& entry : fs::directory_iterator(full.parent_path(), ec)) {
        if (!entry.is_regular_file(ec)) continue;
        const std::string name = lower(utf8_of(entry.path().filename()));
        std::string s, v;
        if (!split_name(name, s, v) || v != version) continue;
        if (s.rfind(stem + "_avmr", 0) != 0) continue;
        const std::string digits = s.substr(stem.size() + 5);
        if (digits.empty() || !std::all_of(digits.begin(), digits.end(), [](unsigned char c) { return std::isdigit(c) != 0; })) continue;
        if (!keep_name.empty() && name == keep_name) continue;
        if (fs::remove(entry.path(), ec)) ++removed;
    }
    return removed;
}
}
