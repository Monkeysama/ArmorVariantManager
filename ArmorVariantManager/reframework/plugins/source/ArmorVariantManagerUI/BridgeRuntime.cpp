#define NOMINMAX
#include <windows.h>
#include <imm.h>

#include "BridgeRuntime.hpp"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <cstdint>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#pragma comment(lib, "imm32.lib")

namespace {

using SetCursorPosFunction = BOOL(WINAPI*)(int, int);

HMODULE g_module = nullptr;
std::atomic<bool> g_running{true};
std::atomic<bool> g_blocked{false};
std::atomic<bool> g_iat_installed{false};
SetCursorPosFunction g_set_cursor_pos_hook = nullptr;
SetCursorPosFunction g_original_set_cursor_pos = nullptr;
void** g_set_cursor_pos_iat = nullptr;
void* g_original_iat_value = nullptr;

// 每个 Lua 项目拥有独立通信目录；DLL 统一管理多个项目的光标阻断与原生文本输入。
struct BridgeClientPaths {
    std::string client_id;
    std::filesystem::path state_path;
    std::filesystem::path text_request_path;
    std::filesystem::path text_result_path;
};

std::mutex g_clients_mutex;
std::unordered_map<std::string, BridgeClientPaths> g_clients;

HWND g_game_window = nullptr;
HWND g_text_edit = nullptr;
WNDPROC g_text_edit_proc = nullptr;
DWORD g_game_thread_id = 0;
DWORD g_proxy_thread_id = 0;
bool g_input_threads_attached = false;
std::uint64_t g_text_result_sequence = 0;
std::uint64_t g_text_session = 0;
std::string g_text_input_id;
std::string g_text_token;
std::wstring g_composition_text;

struct TextRequest {
    bool active = false;
    std::uint64_t session = 0;
    std::uint64_t focus_sequence = 0;
    std::string input_id;
    std::string token;
    std::string text;
    std::string client_id;
    std::filesystem::path result_path;
    int x = 0;
    int y = 0;
    int width = 1;
    int height = 28;
};

TextRequest g_active_text_request;

// 弹窗期间拦截游戏通过 IAT 调用的 SetCursorPos，保持成功返回值但不移动系统光标。
BOOL WINAPI blocked_set_cursor_pos(int x, int y) {
    if (g_blocked.load(std::memory_order_acquire)) return TRUE;
    if (g_original_set_cursor_pos == nullptr) return TRUE;
    return g_original_set_cursor_pos(x, y);
}

// 根据 DLL 所在位置定位 REFramework 根目录，避免依赖固定盘符。
std::filesystem::path get_reframework_directory() {
    wchar_t module_path[MAX_PATH]{};
    const DWORD length = GetModuleFileNameW(g_module, module_path, MAX_PATH);
    if (length == 0 || length >= MAX_PATH) return {};
    return std::filesystem::path(module_path).parent_path().parent_path();
}

// 运行时目录只能位于 data 下，拒绝绝对路径和父目录跳转，避免 Lua 配置越出游戏目录。
bool resolve_runtime_directory(const std::string& runtime_directory,
                               std::filesystem::path& resolved_directory) {
    if (runtime_directory.empty()) return false;
    std::filesystem::path relative;
    try {
        relative = std::filesystem::u8path(runtime_directory);
    } catch (...) {
        return false;
    }
    if (relative.empty() || relative.is_absolute() || relative.has_root_name()
        || relative.has_root_directory()) return false;
    for (const auto& part : relative) {
        if (part == L"..") return false;
    }
    const auto data_directory = get_reframework_directory() / L"data";
    resolved_directory = (data_directory / relative).lexically_normal();
    return true;
}

// 拷贝注册表快照后再做文件 IO，避免 Lua 注册新项目时阻塞后台输入线程。
std::vector<BridgeClientPaths> get_registered_clients() {
    std::lock_guard<std::mutex> lock(g_clients_mutex);
    std::vector<BridgeClientPaths> clients;
    clients.reserve(g_clients.size());
    for (const auto& [_, client] : g_clients) clients.push_back(client);
    return clients;
}

struct BridgeState {
    bool blocked = false;
};

// 读取 Lua 写入的最小状态，文件缺失或写入中途时按未拦截处理。
BridgeState read_state(const std::filesystem::path& state_path) {
    BridgeState state;
    if (state_path.empty()) return state;
    std::ifstream file(state_path, std::ios::binary);
    if (!file) return state;
    const std::string content((std::istreambuf_iterator<char>(file)),
        std::istreambuf_iterator<char>());
    const auto key = content.find("\"blocked\"");
    if (key == std::string::npos) return state;
    const auto value = content.find_first_not_of(" \t\r\n:", key + 9);
    state.blocked = value != std::string::npos && content.compare(value, 4, "true") == 0;
    return state;
}

// 定位 JSON 字段值起点，内部协议只读取本 DLL 写入或 Lua 写入的简单对象。
size_t find_json_value(const std::string& content, const char* key) {
    const auto key_pos = content.find(std::string("\"") + key + "\"");
    if (key_pos == std::string::npos) return std::string::npos;
    const auto colon = content.find(':', key_pos);
    if (colon == std::string::npos) return std::string::npos;
    auto value = colon + 1;
    while (value < content.size() && std::isspace(static_cast<unsigned char>(content[value]))) ++value;
    return value;
}

void append_utf8_codepoint(std::string& output, unsigned int codepoint) {
    if (codepoint <= 0x7F) {
        output.push_back(static_cast<char>(codepoint));
    } else if (codepoint <= 0x7FF) {
        output.push_back(static_cast<char>(0xC0 | (codepoint >> 6)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    } else {
        output.push_back(static_cast<char>(0xE0 | (codepoint >> 12)));
        output.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3F)));
        output.push_back(static_cast<char>(0x80 | (codepoint & 0x3F)));
    }
}

// 读取 JSON 字符串，兼容 Lua JSON 模块输出的常用转义形式。
bool read_json_string(const std::string& content, const char* key, std::string& output) {
    const auto start = find_json_value(content, key);
    if (start == std::string::npos || start >= content.size() || content[start] != '"') return false;
    output.clear();
    for (size_t index = start + 1; index < content.size(); ++index) {
        const char value = content[index];
        if (value == '"') return true;
        if (value != '\\' || ++index >= content.size()) {
            output.push_back(value);
            continue;
        }
        const char escaped = content[index];
        switch (escaped) {
        case '"': output.push_back('"'); break;
        case '\\': output.push_back('\\'); break;
        case '/': output.push_back('/'); break;
        case 'b': output.push_back('\b'); break;
        case 'f': output.push_back('\f'); break;
        case 'n': output.push_back('\n'); break;
        case 'r': output.push_back('\r'); break;
        case 't': output.push_back('\t'); break;
        case 'u': {
            if (index + 4 >= content.size()) return false;
            unsigned int codepoint = 0;
            for (size_t digit = 1; digit <= 4; ++digit) {
                const char hex = content[index + digit];
                codepoint <<= 4;
                if (hex >= '0' && hex <= '9') codepoint |= hex - '0';
                else if (hex >= 'a' && hex <= 'f') codepoint |= hex - 'a' + 10;
                else if (hex >= 'A' && hex <= 'F') codepoint |= hex - 'A' + 10;
                else return false;
            }
            append_utf8_codepoint(output, codepoint);
            index += 4;
            break;
        }
        default: return false;
        }
    }
    return false;
}

bool read_json_bool(const std::string& content, const char* key, bool& output) {
    const auto value = find_json_value(content, key);
    if (value == std::string::npos) return false;
    if (content.compare(value, 4, "true") == 0) { output = true; return true; }
    if (content.compare(value, 5, "false") == 0) { output = false; return true; }
    return false;
}

bool read_json_uint64(const std::string& content, const char* key, std::uint64_t& output) {
    const auto value = find_json_value(content, key);
    if (value == std::string::npos) return false;
    try {
        output = std::stoull(content.substr(value));
        return true;
    } catch (...) {
        return false;
    }
}

bool read_json_int(const std::string& content, const char* key, int& output) {
    const auto value = find_json_value(content, key);
    if (value == std::string::npos) return false;
    try {
        output = std::stoi(content.substr(value));
        return true;
    } catch (...) {
        return false;
    }
}

// 读取 Lua 写入的文本输入请求。读取失败时保留上一帧状态，避免文件替换瞬间误失焦。
bool read_text_request(const BridgeClientPaths& client, TextRequest& request) {
    if (client.text_request_path.empty()) return false;
    std::ifstream file(client.text_request_path, std::ios::binary);
    if (!file) return false;
    const std::string content((std::istreambuf_iterator<char>(file)),
        std::istreambuf_iterator<char>());
    TextRequest next;
    if (!read_json_bool(content, "active", next.active)) return false;
    next.client_id = client.client_id;
    next.result_path = client.text_result_path;
    if (!next.active) { request = std::move(next); return true; }
    if (!read_json_uint64(content, "session", next.session)
        || !read_json_string(content, "id", next.input_id)
        || !read_json_string(content, "token", next.token)
        || !read_json_string(content, "text", next.text)) return false;
    // 旧版 Lua 请求不含 focus_sequence 时按 0 处理，保持单项目运行时兼容。
    read_json_uint64(content, "focus_sequence", next.focus_sequence);
    read_json_int(content, "x", next.x);
    read_json_int(content, "y", next.y);
    read_json_int(content, "width", next.width);
    read_json_int(content, "height", next.height);
    next.width = std::max(1, next.width);
    next.height = std::max(1, next.height);
    request = std::move(next);
    return true;
}

std::wstring utf8_to_wide(const std::string& value) {
    if (value.empty()) return {};
    const int length = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS,
        value.data(), static_cast<int>(value.size()), nullptr, 0);
    if (length <= 0) return {};
    std::wstring output(static_cast<size_t>(length), L'\0');
    MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value.data(),
        static_cast<int>(value.size()), output.data(), length);
    return output;
}

std::string wide_to_utf8(const std::wstring& value) {
    if (value.empty()) return {};
    const int length = WideCharToMultiByte(CP_UTF8, 0, value.data(),
        static_cast<int>(value.size()), nullptr, 0, nullptr, nullptr);
    if (length <= 0) return {};
    std::string output(static_cast<size_t>(length), '\0');
    WideCharToMultiByte(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
        output.data(), length, nullptr, nullptr);
    return output;
}

std::string json_escape(const std::string& value) {
    std::string output;
    output.reserve(value.size());
    for (const unsigned char character : value) {
        switch (character) {
        case '"': output += "\\\""; break;
        case '\\': output += "\\\\"; break;
        case '\n': output += "\\n"; break;
        case '\r': output += "\\r"; break;
        case '\t': output += "\\t"; break;
        default:
            if (character >= 0x20) output.push_back(static_cast<char>(character));
            break;
        }
    }
    return output;
}

std::wstring get_edit_text() {
    if (g_text_edit == nullptr) return {};
    const int length = GetWindowTextLengthW(g_text_edit);
    std::wstring value(static_cast<size_t>(length) + 1, L'\0');
    GetWindowTextW(g_text_edit, value.data(), length + 1);
    value.resize(static_cast<size_t>(length));
    return value;
}

// 将原生编辑控件的提交文本与当前组合文本原子写回 Lua，避免读取到半个 JSON 文件。
void publish_text_result(bool focused = true) {
    if (g_active_text_request.result_path.empty() || g_text_input_id.empty()) return;
    const auto text = json_escape(wide_to_utf8(get_edit_text()));
    const auto composition = json_escape(wide_to_utf8(g_composition_text));
    const std::string content = "{\n  \"sequence\": "
        + std::to_string(++g_text_result_sequence)
        + ",\n  \"session\": " + std::to_string(g_text_session)
        + ",\n  \"id\": \"" + json_escape(g_text_input_id)
        + "\",\n  \"token\": \"" + json_escape(g_text_token)
        + "\",\n  \"text\": \"" + text
        + "\",\n  \"composition\": \"" + composition
        + "\",\n  \"focused\": " + (focused ? "true" : "false") + "\n}\n";
    const auto temporary_path = g_active_text_request.result_path.wstring() + L".tmp";
    std::ofstream file(temporary_path, std::ios::binary | std::ios::trunc);
    if (!file) return;
    file.write(content.data(), static_cast<std::streamsize>(content.size()));
    file.close();
    MoveFileExW(temporary_path.c_str(), g_active_text_request.result_path.c_str(),
        MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH);
}

void update_composition_text(HWND window) {
    const HIMC context = ImmGetContext(window);
    if (context == nullptr) return;
    const LONG byte_count = ImmGetCompositionStringW(context, GCS_COMPSTR, nullptr, 0);
    if (byte_count > 0) {
        std::vector<wchar_t> value(static_cast<size_t>(byte_count / sizeof(wchar_t)) + 1, L'\0');
        ImmGetCompositionStringW(context, GCS_COMPSTR, value.data(), byte_count);
        g_composition_text.assign(value.data(), static_cast<size_t>(byte_count / sizeof(wchar_t)));
    } else {
        g_composition_text.clear();
    }
    ImmReleaseContext(window, context);
}

void update_ime_position(const TextRequest& request);

// 编辑控件专门接收 WM_IME_* 和普通文本消息，游戏主窗口不需要处理 D2D 的组合输入。
LRESULT CALLBACK text_edit_window_proc(HWND window, UINT message, WPARAM w_param, LPARAM l_param) {
    if (g_text_edit_proc == nullptr) return DefWindowProcW(window, message, w_param, l_param);
    const auto original = g_text_edit_proc;
    if (message == WM_IME_STARTCOMPOSITION) {
        const LRESULT result = CallWindowProcW(original, window, message, w_param, l_param);
        update_ime_position(g_active_text_request);
        return result;
    }
    if (message == WM_IME_COMPOSITION) {
        const LRESULT result = CallWindowProcW(original, window, message, w_param, l_param);
        // 输入法进入组合状态后再次设置位置，避免焦点建立前的设置被微软输入法忽略。
        update_ime_position(g_active_text_request);
        if ((l_param & GCS_RESULTSTR) != 0) g_composition_text.clear();
        if ((l_param & (GCS_COMPSTR | GCS_RESULTSTR)) != 0) {
            if ((l_param & GCS_RESULTSTR) == 0) update_composition_text(window);
            publish_text_result();
        }
        return result;
    }
    if (message == WM_IME_NOTIFY
        && (w_param == IMN_OPENCANDIDATE || w_param == IMN_CHANGECANDIDATE)) {
        const LRESULT result = CallWindowProcW(original, window, message, w_param, l_param);
        // 候选框创建或切换页签后再次覆盖位置，避免输入法使用默认的屏幕左上角。
        update_ime_position(g_active_text_request);
        return result;
    }
    if (message == WM_KILLFOCUS) {
        const LRESULT result = CallWindowProcW(original, window, message, w_param, l_param);
        g_composition_text.clear();
        publish_text_result(false);
        return result;
    }
    const LRESULT result = CallWindowProcW(original, window, message, w_param, l_param);
    switch (message) {
    case WM_CHAR:
    case WM_PASTE:
    case WM_CUT:
    case WM_CLEAR:
    case WM_UNDO:
        publish_text_result();
        break;
    case WM_KEYDOWN:
        if (w_param == VK_BACK || w_param == VK_DELETE) publish_text_result();
        break;
    default:
        break;
    }
    return result;
}

struct GameWindowSearch {
    DWORD process_id = 0;
    HWND window = nullptr;
};

BOOL CALLBACK find_game_window_callback(HWND window, LPARAM parameter) {
    auto* search = reinterpret_cast<GameWindowSearch*>(parameter);
    DWORD process_id = 0;
    GetWindowThreadProcessId(window, &process_id);
    if (process_id != search->process_id || !IsWindowVisible(window)
        || GetWindow(window, GW_OWNER) != nullptr) return TRUE;
    search->window = window;
    return FALSE;
}

// 在独立输入线程创建游戏拥有的透明顶层代理窗口，并通过 AttachThreadInput 共享键盘焦点。
bool ensure_text_proxy() {
    if (g_text_edit != nullptr && IsWindow(g_text_edit)) return true;
    GameWindowSearch search{};
    search.process_id = GetCurrentProcessId();
    EnumWindows(find_game_window_callback, reinterpret_cast<LPARAM>(&search));
    if (search.window == nullptr) return false;
    g_game_window = search.window;
    g_proxy_thread_id = GetCurrentThreadId();
    g_game_thread_id = GetWindowThreadProcessId(g_game_window, nullptr);
    if (g_game_thread_id != 0 && g_game_thread_id != g_proxy_thread_id) {
        g_input_threads_attached = AttachThreadInput(g_proxy_thread_id, g_game_thread_id, TRUE) != FALSE;
    }
    g_text_edit = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TRANSPARENT | WS_EX_LAYERED, L"EDIT", L"",
        WS_POPUP | WS_VISIBLE | ES_LEFT | ES_AUTOHSCROLL,
        0, 0, 1, 1, g_game_window, nullptr, g_module, nullptr);
    if (g_text_edit == nullptr) {
        if (g_input_threads_attached) {
            AttachThreadInput(g_proxy_thread_id, g_game_thread_id, FALSE);
            g_input_threads_attached = false;
        }
        return false;
    }
    g_text_edit_proc = reinterpret_cast<WNDPROC>(SetWindowLongPtrW(g_text_edit,
        GWLP_WNDPROC, reinterpret_cast<LONG_PTR>(text_edit_window_proc)));
    // 保留真实标准 EDIT 的文本布局和插入点，但将整个代理窗口设为完全透明。
    // TSF 会使用默认 EDIT 处理的字符位置定位候选词，而 D2D 继续负责可见绘制。
    SetLayeredWindowAttributes(g_text_edit, 0, 0, LWA_ALPHA);
    ShowWindow(g_text_edit, SW_HIDE);
    return g_text_edit_proc != nullptr;
}

// 将透明标准 EDIT 移动并扩展到 D2D 输入框屏幕区域。
// 不再调用 ImmSetCandidateWindow，让微软拼音使用标准 EDIT 的原生插入点布局。
void update_ime_position(const TextRequest& request) {
    if (g_text_edit == nullptr) return;
    POINT screen_point{ request.x, request.y };
    if (g_game_window != nullptr) ClientToScreen(g_game_window, &screen_point);
    SetWindowPos(g_text_edit, HWND_TOP, screen_point.x, screen_point.y,
        request.width, request.height,
        SWP_NOACTIVATE | SWP_NOOWNERZORDER | SWP_SHOWWINDOW);
}

void deactivate_text_proxy() {
    if (g_text_edit == nullptr) return;
    const HIMC context = ImmGetContext(g_text_edit);
    if (context != nullptr) {
        ImmNotifyIME(context, NI_COMPOSITIONSTR, CPS_CANCEL, 0);
        ImmReleaseContext(g_text_edit, context);
    }
    g_composition_text.clear();
    ShowWindow(g_text_edit, SW_HIDE);
    if (g_game_window != nullptr && IsWindow(g_game_window)) SetFocus(g_game_window);
    g_text_input_id.clear();
    g_text_token.clear();
    g_active_text_request = {};
}

// 应用 Lua 请求。会话号变化才覆盖编辑控件文本，避免输入过程中被轮询状态重置。
void apply_text_request(const TextRequest& request) {
    if (!request.active) {
        if (!g_text_input_id.empty()) deactivate_text_proxy();
        return;
    }
    if (!ensure_text_proxy()) return;
    const bool new_session = request.client_id != g_active_text_request.client_id
        || request.session != g_text_session || request.input_id != g_text_input_id
        || request.token != g_text_token;
    if (new_session) {
        g_text_session = request.session;
        g_text_input_id = request.input_id;
        g_text_token = request.token;
        g_composition_text.clear();
        const auto text = utf8_to_wide(request.text);
        SetWindowTextW(g_text_edit, text.c_str());
        SendMessageW(g_text_edit, EM_SETSEL, static_cast<WPARAM>(text.size()),
            static_cast<LPARAM>(text.size()));
    }
    g_active_text_request = request;
    // 只在用户聚焦新字段时设置一次焦点。失焦后不能由轮询线程抢回，
    // 否则点击弹窗其他区域会表现为需要多次点击才能退出编辑。
    if (new_session) SetFocus(g_text_edit);
    // 焦点建立后再设置位置，确保 IME 上下文已附着到代理编辑控件。
    update_ime_position(g_active_text_request);
    if (new_session) publish_text_result();
}

// 清理子控件和输入队列连接；只由创建代理的输入线程调用。
void destroy_text_proxy() {
    if (g_text_edit != nullptr && IsWindow(g_text_edit)) {
        if (g_text_edit_proc != nullptr) {
            SetWindowLongPtrW(g_text_edit, GWLP_WNDPROC,
                reinterpret_cast<LONG_PTR>(g_text_edit_proc));
        }
        DestroyWindow(g_text_edit);
    }
    g_text_edit = nullptr;
    g_text_edit_proc = nullptr;
    if (g_input_threads_attached) {
        AttachThreadInput(g_proxy_thread_id, g_game_thread_id, FALSE);
        g_input_threads_attached = false;
    }
    g_game_window = nullptr;
    g_game_thread_id = 0;
    g_text_input_id.clear();
    g_text_token.clear();
}

// 修改指定 IAT 槽位，不触碰 USER32.dll 的代码页。
bool write_iat_value(void** slot, void* value) {
    if (slot == nullptr) return false;
    DWORD old_protection = 0;
    if (!VirtualProtect(slot, sizeof(void*), PAGE_READWRITE, &old_protection)) return false;
    std::memcpy(slot, &value, sizeof(value));
    FlushInstructionCache(GetCurrentProcess(), slot, sizeof(void*));
    DWORD ignored = 0;
    VirtualProtect(slot, sizeof(void*), old_protection, &ignored);
    return true;
}

// 在游戏 EXE 的 USER32 导入表中定位 SetCursorPos 的 IAT 槽位。
void** find_set_cursor_pos_iat() {
    const auto module = GetModuleHandleW(nullptr);
    if (module == nullptr) return nullptr;
    const auto base = reinterpret_cast<BYTE*>(module);
    const auto dos_header = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
    if (dos_header->e_magic != IMAGE_DOS_SIGNATURE) return nullptr;
    const auto nt_header = reinterpret_cast<const IMAGE_NT_HEADERS64*>(
        base + dos_header->e_lfanew);
    if (nt_header->Signature != IMAGE_NT_SIGNATURE) return nullptr;
    const auto& import_directory = nt_header->OptionalHeader.DataDirectory[
        IMAGE_DIRECTORY_ENTRY_IMPORT];
    if (import_directory.VirtualAddress == 0) return nullptr;

    auto descriptor = reinterpret_cast<const IMAGE_IMPORT_DESCRIPTOR*>(
        base + import_directory.VirtualAddress);
    for (; descriptor->Name != 0; ++descriptor) {
        const char* module_name = reinterpret_cast<const char*>(base + descriptor->Name);
        if (_stricmp(module_name, "USER32.dll") != 0) continue;
        if (descriptor->FirstThunk == 0) return nullptr;

        auto* first_thunk = reinterpret_cast<IMAGE_THUNK_DATA64*>(
            base + descriptor->FirstThunk);
        auto* original_thunk = descriptor->OriginalFirstThunk != 0
            ? reinterpret_cast<IMAGE_THUNK_DATA64*>(base + descriptor->OriginalFirstThunk)
            : first_thunk;
        for (; original_thunk->u1.AddressOfData != 0; ++original_thunk, ++first_thunk) {
            if (IMAGE_SNAP_BY_ORDINAL64(original_thunk->u1.Ordinal)) continue;
            const auto* import_name = reinterpret_cast<const IMAGE_IMPORT_BY_NAME*>(
                base + original_thunk->u1.AddressOfData);
            if (std::strcmp(reinterpret_cast<const char*>(import_name->Name),
                "SetCursorPos") == 0) {
                return reinterpret_cast<void**>(&first_thunk->u1.Function);
            }
        }
    }
    return nullptr;
}

// 仅替换一次游戏 EXE 的 IAT 槽位，后续弹窗开关只切换原子状态。
bool install_iat_hook() {
    if (g_iat_installed.load(std::memory_order_acquire)) return true;
    g_set_cursor_pos_iat = find_set_cursor_pos_iat();
    if (g_set_cursor_pos_iat == nullptr) return false;
    void* current = *g_set_cursor_pos_iat;
    if (current == reinterpret_cast<void*>(g_set_cursor_pos_hook)) {
        g_iat_installed.store(true, std::memory_order_release);
        return true;
    }
    if (current == nullptr) return false;
    g_original_iat_value = current;
    g_original_set_cursor_pos = reinterpret_cast<SetCursorPosFunction>(current);
    if (!write_iat_value(g_set_cursor_pos_iat, reinterpret_cast<void*>(g_set_cursor_pos_hook))) {
        g_set_cursor_pos_iat = nullptr;
        g_original_iat_value = nullptr;
        g_original_set_cursor_pos = nullptr;
        return false;
    }
    g_iat_installed.store(true, std::memory_order_release);
    return true;
}

// DLL 卸载时恢复 IAT 槽位；运行期间不恢复 USER32 入口。
void restore_iat_hook() {
    if (!g_iat_installed.load(std::memory_order_acquire) || g_set_cursor_pos_iat == nullptr) return;
    if (*g_set_cursor_pos_iat == reinterpret_cast<void*>(g_set_cursor_pos_hook)) {
        write_iat_value(g_set_cursor_pos_iat, g_original_iat_value);
    }
    g_iat_installed.store(false, std::memory_order_release);
    g_set_cursor_pos_iat = nullptr;
    g_original_iat_value = nullptr;
    g_original_set_cursor_pos = nullptr;
}

// 弹窗开关只改变桥接函数的阻断状态，不再修改 USER32 代码页或 IAT 槽位。
void apply_blocked_state(bool blocked) {
    g_blocked.store(blocked, std::memory_order_release);
}

// 后台轮询弹窗与文本代理状态，并派发代理编辑控件的 IME 消息。
void state_worker() {
    while (g_running.load(std::memory_order_acquire)) {
        bool blocked = false;
        bool has_valid_request = false;
        bool has_active_request = false;
        TextRequest selected_request;
        for (const auto& client : get_registered_clients()) {
            blocked = blocked || read_state(client.state_path).blocked;
            TextRequest request;
            if (!read_text_request(client, request)) continue;
            has_valid_request = true;
            if (!request.active) continue;
            // 焦点序号由 Lua 在实际激活输入框时递增，避免其他项目同步位置时抢走输入法焦点。
            const bool is_current_owner = request.client_id == g_active_text_request.client_id;
            if (!has_active_request || request.focus_sequence > selected_request.focus_sequence
                || (request.focus_sequence == selected_request.focus_sequence && is_current_owner)) {
                selected_request = std::move(request);
                has_active_request = true;
            }
        }
        apply_blocked_state(blocked);
        if (has_active_request) {
            apply_text_request(selected_request);
        } else if (has_valid_request) {
            // 所有注册项目均明确失焦时才关闭代理；文件写入瞬间失败时保留当前焦点。
            apply_text_request(TextRequest{});
        }
        MSG message{};
        while (PeekMessageW(&message, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&message);
            DispatchMessageW(&message);
        }
        Sleep(5);
    }
    destroy_text_proxy();
    restore_iat_hook();
    g_blocked.store(false, std::memory_order_release);
}

void initialize_bridge() {
    // 保留差分管理器旧目录作为默认注册项，历史 Lua 组件无需修改即可继续工作。
    avm_bridge_register_runtime("ArmorVariantManager", "ArmorVariantManager/Runtime");
    g_set_cursor_pos_hook = blocked_set_cursor_pos;
    install_iat_hook();
    HANDLE thread = CreateThread(nullptr, 0, [](void*) -> DWORD {
        state_worker();
        return 0;
    }, nullptr, 0, nullptr);
    if (thread != nullptr) CloseHandle(thread);
}

} // namespace

bool avm_bridge_register_runtime(const std::string& client_id, const std::string& runtime_directory) {
    if (client_id.empty() || client_id.size() > 128) return false;
    if (client_id.find_first_of("\\/:*?\"<>|") != std::string::npos) return false;

    std::filesystem::path directory;
    if (!resolve_runtime_directory(runtime_directory, directory)) return false;
    std::error_code create_directory_error;
    std::filesystem::create_directories(directory, create_directory_error);
    if (create_directory_error) return false;

    BridgeClientPaths client;
    client.client_id = client_id;
    client.state_path = directory / L"D2DInputState.json";
    client.text_request_path = directory / L"D2DTextInputRequest.json";
    client.text_result_path = directory / L"D2DTextInputResult.json";
    std::lock_guard<std::mutex> lock(g_clients_mutex);
    g_clients[client_id] = std::move(client);
    return true;
}

bool avm_bridge_unregister_runtime(const std::string& client_id) {
    if (client_id.empty()) return false;
    std::lock_guard<std::mutex> lock(g_clients_mutex);
    return g_clients.erase(client_id) > 0;
}

void avm_bridge_initialize(HMODULE module) {
    g_module = module;
    HANDLE thread = CreateThread(nullptr, 0, [](void*) -> DWORD {
        initialize_bridge();
        return 0;
    }, nullptr, 0, nullptr);
    if (thread != nullptr) CloseHandle(thread);
}

void avm_bridge_shutdown() {
    g_running.store(false, std::memory_order_release);
    restore_iat_hook();
}
