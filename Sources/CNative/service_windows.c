#ifdef _WIN32
#define COBJMACROS
#include "CNative.h"
#include <windows.h>
#include <shlobj.h>
#include <sddl.h>
#include <io.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>

#define PATH_CAPACITY 32768
typedef struct {
    DWORD pid;
    FILETIME created;
    wchar_t executable[PATH_CAPACITY];
} ProcessIdentity;

static HANDLE instance, legacy_instance, identity_mapping, stop_event;
static volatile LONG stopped;

static int windows_error(const char *operation, DWORD code) {
    char message[256];
    snprintf(message, sizeof(message), "%s failed (Windows error %lu).", operation, (unsigned long)code);
    return am_set_error(message);
}

static wchar_t *wide_path(const char *value) {
    int count = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, NULL, 0);
    if (!count) { windows_error("Decode UTF-8 path", GetLastError()); return NULL; }
    wchar_t *result = malloc((size_t)count * sizeof(wchar_t));
    if (!result) { am_set_error("Cannot allocate path."); return NULL; }
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, value, -1, result, count)) {
        windows_error("Decode UTF-8 path", GetLastError()); free(result); return NULL;
    }
    for (int i = 0; i < count; ++i) if (result[i] == L'/') result[i] = L'\\';
    return result;
}

static int check_legacy_instance(void) {
    HANDLE legacy = OpenMutexW(SYNCHRONIZE, FALSE, L"Local\\AnyKeyMic-USB");
    if (legacy) {
        CloseHandle(legacy);
        return am_set_error("An older AnyKeyMic instance is running; exit that version first.");
    }
    DWORD error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND ? 0 : windows_error("Check legacy instance", error);
}

/* 路径别名与 MSIX 文件重定向可能产生不同字符串，按文件身份比较。 */
static int same_executable(const wchar_t *left, const wchar_t *right) {
    if (!_wcsicmp(left, right)) return 1;
    HANDLE a = CreateFileW(left, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, 0, NULL);
    if (a == INVALID_HANDLE_VALUE) return windows_error("Inspect executable", GetLastError());
    HANDLE b = CreateFileW(right, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                           NULL, OPEN_EXISTING, 0, NULL);
    DWORD error = GetLastError();
    if (b == INVALID_HANDLE_VALUE) { CloseHandle(a); return windows_error("Inspect executable", error); }
    BY_HANDLE_FILE_INFORMATION first, second;
    BOOL ok = GetFileInformationByHandle(a, &first) && GetFileInformationByHandle(b, &second);
    error = GetLastError();
    CloseHandle(a); CloseHandle(b);
    if (!ok) return windows_error("Read executable identity", error);
    return first.dwVolumeSerialNumber == second.dwVolumeSerialNumber &&
           first.nFileIndexHigh == second.nFileIndexHigh && first.nFileIndexLow == second.nFileIndexLow;
}

static int object_name(wchar_t *buffer, size_t capacity, const wchar_t *suffix) {
    HANDLE token;
    DWORD size = 0;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) return windows_error("Open process token", GetLastError());
    GetTokenInformation(token, TokenUser, NULL, 0, &size);
    TOKEN_USER *user = malloc(size);
    if (!user) { CloseHandle(token); return am_set_error("Cannot allocate user identity."); }
    BOOL found = GetTokenInformation(token, TokenUser, user, size, &size);
    DWORD error = GetLastError();
    CloseHandle(token);
    LPWSTR sid = NULL;
    if (found) { found = ConvertSidToStringSidW(user->User.Sid, &sid); error = GetLastError(); }
    free(user);
    if (!found) return windows_error("Read user identity", error);
    int count = swprintf(buffer, capacity, L"Local\\AnyKeyMic-%ls-%ls", sid, suffix);
    LocalFree(sid);
    return count > 0 && (size_t)count < capacity ? 0 : am_set_error("Process object name is too long.");
}

static int event_name(wchar_t *buffer, size_t capacity, const ProcessIdentity *identity) {
    wchar_t suffix[96];
    swprintf(suffix, 96, L"stop-%lu-%08lx%08lx", (unsigned long)identity->pid,
             (unsigned long)identity->created.dwHighDateTime, (unsigned long)identity->created.dwLowDateTime);
    return object_name(buffer, capacity, suffix);
}

static BOOL WINAPI on_signal(DWORD code) {
    if (code != CTRL_C_EVENT && code != CTRL_BREAK_EVENT && code != CTRL_CLOSE_EVENT) return FALSE;
    InterlockedExchange(&stopped, 1);
    return TRUE;
}

int am_process_start(void) {
    wchar_t name[256];
    if (object_name(name, 256, L"instance") != 0) return -1;
    instance = CreateMutexW(NULL, FALSE, name);
    if (!instance) return windows_error("Create instance mutex", GetLastError());
    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(instance); instance = NULL;
        return am_set_error("AnyKeyMic is already running in this user session.");
    }
    /* Keep the old name alive so older releases cannot start alongside this one. */
    legacy_instance = CreateMutexW(NULL, FALSE, L"Local\\AnyKeyMic-USB");
    DWORD legacy_error = GetLastError();
    if (!legacy_instance || legacy_error == ERROR_ALREADY_EXISTS) {
        if (legacy_instance) { CloseHandle(legacy_instance); legacy_instance = NULL; }
        CloseHandle(instance); instance = NULL;
        return legacy_error == ERROR_ALREADY_EXISTS
            ? am_set_error("An older AnyKeyMic instance is running; exit that version first.")
            : windows_error("Create legacy instance mutex", legacy_error);
    }
    ProcessIdentity *identity = calloc(1, sizeof(*identity));
    if (!identity) {
        CloseHandle(legacy_instance); legacy_instance = NULL;
        CloseHandle(instance); instance = NULL;
        return am_set_error("Cannot allocate process identity.");
    }
    identity->pid = GetCurrentProcessId();
    FILETIME exited, kernel, user;
    DWORD length = PATH_CAPACITY;
    BOOL found = QueryFullProcessImageNameW(GetCurrentProcess(), 0, identity->executable, &length);
    DWORD error = GetLastError();
    if (!found) goto failed;
    if (!GetProcessTimes(GetCurrentProcess(), &identity->created, &exited, &kernel, &user)) { error = GetLastError(); goto failed; }
    if (event_name(name, 256, identity) != 0) { error = ERROR_INVALID_NAME; goto failed; }
    stop_event = CreateEventW(NULL, TRUE, FALSE, name);
    if (!stop_event) { error = GetLastError(); goto failed; }
    if (object_name(name, 256, L"identity") != 0) { error = ERROR_INVALID_NAME; goto failed; }
    identity_mapping = CreateFileMappingW(INVALID_HANDLE_VALUE, NULL, PAGE_READWRITE, 0, sizeof(*identity), name);
    if (!identity_mapping) { error = GetLastError(); goto failed; }
    void *view = MapViewOfFile(identity_mapping, FILE_MAP_WRITE, 0, 0, sizeof(*identity));
    if (!view) { error = GetLastError(); goto failed; }
    memcpy(view, identity, sizeof(*identity));
    UnmapViewOfFile(view);
    free(identity);
    SetConsoleCtrlHandler(on_signal, TRUE);
    return 0;
failed:
    free(identity);
    if (identity_mapping) { CloseHandle(identity_mapping); identity_mapping = NULL; }
    if (stop_event) { CloseHandle(stop_event); stop_event = NULL; }
    CloseHandle(legacy_instance); legacy_instance = NULL;
    CloseHandle(instance); instance = NULL;
    return windows_error("Initialize process control", error);
}

int am_should_stop(void) {
    return InterlockedCompareExchange(&stopped, 0, 0) || (stop_event && WaitForSingleObject(stop_event, 0) == WAIT_OBJECT_0);
}

/* A process handle plus creation time prevents a recycled PID from receiving a stop request. */
static int running_process(HANDLE *process, ProcessIdentity *identity) {
    *process = NULL;
    wchar_t name[256];
    if (object_name(name, 256, L"identity") != 0) return -1;
    HANDLE mapping = OpenFileMappingW(FILE_MAP_READ, FALSE, name);
    if (!mapping) {
        DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND ? 0 : windows_error("Open process identity", error);
    }
    const void *view = MapViewOfFile(mapping, FILE_MAP_READ, 0, 0, sizeof(*identity));
    if (!view) { DWORD error = GetLastError(); CloseHandle(mapping); return windows_error("Read process identity", error); }
    memcpy(identity, view, sizeof(*identity));
    UnmapViewOfFile(view);
    CloseHandle(mapping);
    if (!identity->pid || !identity->executable[0] || identity->executable[PATH_CAPACITY - 1]) return 0;
    HANDLE candidate = OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, identity->pid);
    if (!candidate) {
        DWORD error = GetLastError();
        return error == ERROR_INVALID_PARAMETER ? 0 : windows_error("Open running process", error);
    }
    FILETIME created, exited, kernel, user;
    wchar_t path[PATH_CAPACITY];
    DWORD capacity = PATH_CAPACITY;
    BOOL valid = GetProcessTimes(candidate, &created, &exited, &kernel, &user) &&
        QueryFullProcessImageNameW(candidate, 0, path, &capacity);
    if (!valid) { DWORD error = GetLastError(); CloseHandle(candidate); return windows_error("Verify running process", error); }
    int same = same_executable(path, identity->executable);
    if (same < 0) { CloseHandle(candidate); return -1; }
    if (CompareFileTime(&created, &identity->created) || !same || WaitForSingleObject(candidate, 0) == WAIT_OBJECT_0) {
        CloseHandle(candidate); return 0;
    }
    *process = candidate;
    return 1;
}

int am_service_running(void) {
    ProcessIdentity *identity = malloc(sizeof(*identity));
    if (!identity) return am_set_error("Cannot allocate process identity.");
    HANDLE process;
    int result = running_process(&process, identity);
    if (process) CloseHandle(process);
    free(identity);
    return result == 0 ? check_legacy_instance() : result;
}

int am_service_stop(void) {
    ProcessIdentity *identity = malloc(sizeof(*identity));
    if (!identity) return am_set_error("Cannot allocate process identity.");
    HANDLE process;
    int result = running_process(&process, identity);
    if (result <= 0) { free(identity); return result == 0 ? check_legacy_instance() : result; }
    wchar_t name[256];
    result = event_name(name, 256, identity);
    free(identity);
    if (result != 0) { CloseHandle(process); return -1; }
    HANDLE event = OpenEventW(EVENT_MODIFY_STATE, FALSE, name);
    if (!event) {
        DWORD error = GetLastError();
        BOOL exited = WaitForSingleObject(process, 0) == WAIT_OBJECT_0;
        CloseHandle(process);
        return exited ? 0 : windows_error("Open stop event", error);
    }
    BOOL sent = SetEvent(event);
    DWORD error = GetLastError();
    CloseHandle(event);
    DWORD waited = sent ? WaitForSingleObject(process, 10000) : WAIT_FAILED;
    if (sent && waited == WAIT_FAILED) error = GetLastError();
    CloseHandle(process);
    if (!sent || waited == WAIT_FAILED) return windows_error("Stop process", error);
    return waited == WAIT_OBJECT_0 ? 0 : am_set_error("AnyKeyMic did not stop within 10 seconds; it was not forcibly terminated.");
}

void am_console_attach(void) {
    DWORD ids[] = { STD_INPUT_HANDLE, STD_OUTPUT_HANDLE, STD_ERROR_HANDLE };
    FILE *streams[] = { stdin, stdout, stderr };
    HANDLE handles[3] = {0};
    for (int i = 0; i < 3; ++i) {
        HANDLE inherited = GetStdHandle(ids[i]);
        if (inherited && inherited != INVALID_HANDLE_VALUE)
            DuplicateHandle(GetCurrentProcess(), inherited, GetCurrentProcess(), &handles[i], 0, FALSE, DUPLICATE_SAME_ACCESS);
    }
    AttachConsole(ATTACH_PARENT_PROCESS);
    for (int i = 0; i < 3; ++i) {
        if (!handles[i]) {
            HANDLE attached = GetStdHandle(ids[i]);
            if (attached && attached != INVALID_HANDLE_VALUE)
                DuplicateHandle(GetCurrentProcess(), attached, GetCurrentProcess(), &handles[i], 0, FALSE, DUPLICATE_SAME_ACCESS);
        }
        /* GUI executables can begin with FILE descriptors set to -2. */
        FILE *reopened;
        if (_fileno(streams[i]) < 0 && _wfreopen_s(&reopened, L"NUL", i == 0 ? L"rb" : L"wb", streams[i])) {
            if (handles[i]) CloseHandle(handles[i]);
            continue;
        }
        if (!handles[i]) continue;
        // freopen 后 FILE 可能使用 fd3 等新描述符，不能假定仍是 fd0／1／2。
        int target = _fileno(streams[i]);
        int fd = _open_osfhandle((intptr_t)handles[i], _O_BINARY | (i == 0 ? _O_RDONLY : _O_WRONLY));
        if (fd < 0) { CloseHandle(handles[i]); continue; }
        int result = _dup2(fd, target);
        // Swift print 使用 FILE，Foundation FileHandle 使用固定的 fd0／1／2。
        if (result == 0 && target != i) result = _dup2(fd, i);
        if (fd != target && fd != i) _close(fd);
        if (result != 0) continue;
        SetStdHandle(ids[i], (HANDLE)_get_osfhandle(i));
    }
}

int am_executable_path(char *buffer, int capacity) {
    wchar_t path[PATH_CAPACITY];
    DWORD length = PATH_CAPACITY;
    if (!QueryFullProcessImageNameW(GetCurrentProcess(), 0, path, &length)) return windows_error("Get executable path", GetLastError());
    if (capacity <= 0 || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, path, -1, buffer, capacity, NULL, NULL))
        return windows_error("Encode executable path", GetLastError());
    return 0;
}

int am_resolve_path(const char *input, char *buffer, int capacity) {
    wchar_t *path = wide_path(input);
    if (!path) return -1;
    HANDLE file = CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                              NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
    free(path);
    if (file == INVALID_HANDLE_VALUE) return windows_error("Resolve path", GetLastError());
    wchar_t resolved[PATH_CAPACITY];
    DWORD length = GetFinalPathNameByHandleW(file, resolved, PATH_CAPACITY, FILE_NAME_NORMALIZED | VOLUME_NAME_DOS);
    DWORD error = GetLastError();
    CloseHandle(file);
    if (!length || length >= PATH_CAPACITY) return windows_error("Resolve path", error);
    const wchar_t *normal = resolved;
    if (!wcsncmp(resolved, L"\\\\?\\UNC\\", 8)) { resolved[6] = L'\\'; normal = resolved + 6; }
    else if (!wcsncmp(resolved, L"\\\\?\\", 4)) normal = resolved + 4;
    if (capacity <= 0 || !WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, normal, -1, buffer, capacity, NULL, NULL))
        return windows_error("Encode resolved path", GetLastError());
    return 0;
}

static int shortcut_path(wchar_t *path) {
    PWSTR startup = NULL;
    HRESULT result = SHGetKnownFolderPath(&FOLDERID_Startup, KF_FLAG_CREATE, NULL, &startup);
    if (FAILED(result)) return windows_error("Find Startup folder", (DWORD)result);
    int count = swprintf(path, PATH_CAPACITY, L"%ls\\AnyKeyMic.lnk", startup);
    CoTaskMemFree(startup);
    return count > 0 && count < PATH_CAPACITY ? 0 : am_set_error("Startup path is too long.");
}

static int shortcut(const char *executable, int install, char *resolved, int capacity) {
    wchar_t path[PATH_CAPACITY];
    if (shortcut_path(path) != 0) return -1;
    if (!install && GetFileAttributesW(path) == INVALID_FILE_ATTRIBUTES) {
        DWORD error = GetLastError();
        return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? 0 : windows_error("Inspect Startup shortcut", error);
    }
    wchar_t *binary = executable ? wide_path(executable) : NULL;
    if (executable && !binary) return -1;
    HRESULT initialized = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    if (FAILED(initialized) && initialized != RPC_E_CHANGED_MODE) { free(binary); return windows_error("Initialize COM", (DWORD)initialized); }
    IShellLinkW *link = NULL;
    IPersistFile *file = NULL;
    HRESULT result = CoCreateInstance(&CLSID_ShellLink, NULL, CLSCTX_INPROC_SERVER, &IID_IShellLinkW, (void **)&link);
    int registered = 0;
    if (SUCCEEDED(result)) result = IShellLinkW_QueryInterface(link, &IID_IPersistFile, (void **)&file);
    if (SUCCEEDED(result) && install) {
        result = IShellLinkW_SetPath(link, binary);
        if (SUCCEEDED(result)) result = IShellLinkW_SetArguments(link, L"run --background");
        if (SUCCEEDED(result)) result = IShellLinkW_SetDescription(link, L"AnyKeyMic microphone bridge");
        if (SUCCEEDED(result)) result = IPersistFile_Save(file, path, TRUE);
    } else if (SUCCEEDED(result)) {
        result = IPersistFile_Load(file, path, STGM_READ);
        wchar_t target[PATH_CAPACITY], arguments[128];
        if (SUCCEEDED(result)) result = IShellLinkW_GetPath(link, target, PATH_CAPACITY, NULL, SLGP_RAWPATH);
        if (SUCCEEDED(result)) result = IShellLinkW_GetArguments(link, arguments, 128);
        if (SUCCEEDED(result) && !wcscmp(arguments, L"run --background")) {
            if (binary) registered = !_wcsicmp(binary, target);
            else if (capacity > 0 && WideCharToMultiByte(CP_UTF8, WC_ERR_INVALID_CHARS, target, -1, resolved, capacity, NULL, NULL)) registered = 1;
            else result = HRESULT_FROM_WIN32(GetLastError());
        }
    }
    if (file) IPersistFile_Release(file);
    if (link) IShellLinkW_Release(link);
    if (SUCCEEDED(initialized)) CoUninitialize();
    free(binary);
    if (FAILED(result)) return windows_error(install ? "Register Startup shortcut" : "Inspect Startup shortcut", (DWORD)result);
    return install ? 0 : registered;
}

int am_service_register(const char *executable) { return shortcut(executable, 1, NULL, 0); }
int am_service_registered(const char *executable) { return shortcut(executable, 0, NULL, 0); }
int am_service_executable_path(char *buffer, int capacity) { return shortcut(NULL, 0, buffer, capacity); }
int am_service_unregister(void) {
    wchar_t path[PATH_CAPACITY];
    if (shortcut_path(path) != 0) return -1;
    if (DeleteFileW(path)) return 0;
    DWORD error = GetLastError();
    return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? 0 : windows_error("Remove Startup shortcut", error);
}

int am_service_start(const char *executable) {
    wchar_t *binary = wide_path(executable);
    if (!binary) return -1;
    ProcessIdentity identity;
    HANDLE existing;
    int running = running_process(&existing, &identity);
    if (existing) CloseHandle(existing);
    if (running != 0) {
        int same = running > 0 ? same_executable(identity.executable, binary) : -1;
        int result = same == 1 ? 0 : -1;
        if (same == 0) am_set_error("AnyKeyMic is running from another path; run stop before start.");
        free(binary);
        return result;
    }
    if (check_legacy_instance() != 0) { free(binary); return -1; }
    size_t capacity = wcslen(binary) + 32;
    wchar_t *command = malloc(capacity * sizeof(wchar_t));
    if (!command) { free(binary); return am_set_error("Cannot allocate command line."); }
    swprintf(command, capacity, L"\"%ls\" run --background", binary);
    PROCESS_INFORMATION process = {0};
    STARTUPINFOW startup = {0};
    startup.cb = sizeof(startup);
    // 后台入口自行打开日志，禁止继承调用者的管道与其他句柄。
    BOOL launched = CreateProcessW(binary, command, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &startup, &process);
    DWORD error = GetLastError();
    free(command); free(binary);
    if (!launched) return windows_error("Start background process", error);
    CloseHandle(process.hThread);
    int result = -1;
    for (int attempt = 0; attempt < 100; ++attempt) {
        DWORD waited = WaitForSingleObject(process.hProcess, 50);
        if (waited == WAIT_OBJECT_0) {
            CloseHandle(process.hProcess);
            return am_set_error("AnyKeyMic exited during startup; check run.log.");
        }
        if (waited == WAIT_FAILED) {
            DWORD error = GetLastError();
            CloseHandle(process.hProcess);
            return windows_error("Wait for background process", error);
        }
        HANDLE confirmed;
        running = running_process(&confirmed, &identity);
        if (confirmed) CloseHandle(confirmed);
        if (running > 0 && identity.pid == process.dwProcessId && attempt >= 9) { result = 0; break; }
        if (running < 0) break;
    }
    if (result < 0 && running >= 0) am_set_error("AnyKeyMic startup was not confirmed within 5 seconds; check run.log.");
    CloseHandle(process.hProcess);
    return result;
}
#endif
