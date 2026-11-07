/* 将桌面输入 API 替换为桩；运行本测试不会查询或注入真实按键。 */
#include <windows.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static INPUT sent;
static int send_calls, key_to_capture, map_calls;
static UINT send_result = 1;
static DWORD last_error, send_error;
static ULONGLONG clock_ms;
static char reported_error[256];

#define CHECK(condition) do { \
    if (!(condition)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #condition); exit(1); } \
} while (0)

static UINT fake_send_input(UINT count, LPINPUT inputs, int size) {
    CHECK(count == 1 && size == sizeof(INPUT));
    sent = inputs[0];
    send_calls++;
    last_error = send_error;
    return send_result;
}

static UINT fake_map_virtual_key(UINT key, UINT mode) {
    CHECK(mode == MAPVK_VK_TO_VSC_EX);
    map_calls++;
    switch (key) {
    case VK_LCONTROL: return 0x1d;
    case VK_RCONTROL: return 0xe01d;
    case VK_LMENU: return 0x38;
    case VK_RMENU: return 0xe038;
    case VK_LSHIFT: return 0x2a;
    case VK_RSHIFT: return 0x36;
    case VK_RWIN: return 0xe05c;
    case VK_LEFT: return 0xe04b;
    case VK_PAUSE: return 0xe11d;
    default: return 0;
    }
}

static SHORT fake_key_state(int key) {
    if (clock_ms == 0 || key_to_capture == 0) return 0;
    if (key == key_to_capture) return (SHORT)0x8000;
    if (key == VK_CONTROL && (key_to_capture == VK_LCONTROL || key_to_capture == VK_RCONTROL)) return (SHORT)0x8000;
    if (key == VK_MENU && (key_to_capture == VK_LMENU || key_to_capture == VK_RMENU)) return (SHORT)0x8000;
    if (key == VK_SHIFT && (key_to_capture == VK_LSHIFT || key_to_capture == VK_RSHIFT)) return (SHORT)0x8000;
    return 0;
}

static void fake_sleep(DWORD duration) { clock_ms += duration; }
static ULONGLONG fake_clock(void) { return clock_ms; }
static void fake_set_error(DWORD value) { last_error = value; }
static DWORD fake_get_error(void) { return last_error; }

int am_set_error(const char *message) {
    snprintf(reported_error, sizeof(reported_error), "%s", message);
    return -1;
}

#define SendInput fake_send_input
#define MapVirtualKeyW fake_map_virtual_key
#define GetAsyncKeyState fake_key_state
#define Sleep fake_sleep
#define GetTickCount64 fake_clock
#define SetLastError fake_set_error
#define GetLastError fake_get_error
#include "../../Sources/CNative/keyinject.c"

static void check_injection(int key, WORD scan, DWORD flags) {
    for (int pressed = 0; pressed <= 1; ++pressed) {
        int before = send_calls;
        CHECK(am_key_inject(key, pressed) == 0);
        CHECK(send_calls == before + 1);
        CHECK(sent.type == INPUT_KEYBOARD);
        CHECK(sent.ki.wVk == key && sent.ki.wScan == scan);
        CHECK(sent.ki.dwFlags == (flags | (pressed ? 0 : KEYEVENTF_KEYUP)));
    }
}

int main(void) {
    check_injection(VK_LCONTROL, 0x1d, 0);
    check_injection(VK_RCONTROL, 0x1d, KEYEVENTF_EXTENDEDKEY);
    check_injection(VK_LMENU, 0x38, 0);
    check_injection(VK_RMENU, 0x38, KEYEVENTF_EXTENDEDKEY);
    check_injection(VK_LSHIFT, 0x2a, 0);
    check_injection(VK_RSHIFT, 0x36, 0);
    check_injection(VK_RWIN, 0x5c, KEYEVENTF_EXTENDEDKEY);
    check_injection(VK_LEFT, 0x4b, KEYEVENTF_EXTENDEDKEY);
    check_injection(VK_PAUSE, 0x1d, 0);
    check_injection(VK_VOLUME_UP, 0, 0); /* 无扫描码的有效 VK 仍可注入。 */

    const int modifiers[] = { VK_RCONTROL, VK_LCONTROL, VK_RMENU, VK_LMENU, VK_RSHIFT, VK_LSHIFT };
    for (unsigned i = 0; i < sizeof(modifiers) / sizeof(modifiers[0]); ++i) {
        clock_ms = 0;
        key_to_capture = modifiers[i];
        int captured = 0;
        CHECK(am_key_capture(&captured, 100) == 0);
        CHECK(captured == modifiers[i]);
    }

    const int invalid[] = { -1, 0, 0xff, 0x100, 0x10000 };
    int sends_before = send_calls, maps_before = map_calls;
    for (unsigned i = 0; i < sizeof(invalid) / sizeof(invalid[0]); ++i) CHECK(am_key_inject(invalid[i], 1) == -1);
    CHECK(send_calls == sends_before && map_calls == maps_before);
    int captured = 0;
    CHECK(am_key_capture(NULL, 100) == -1);
    CHECK(am_key_capture(&captured, 0) == -1);
    CHECK(am_key_capture(&captured, -1) == -1);
    clock_ms = 0;
    key_to_capture = 0;
    CHECK(am_key_capture(&captured, 20) == -1);
    CHECK(clock_ms == 20);

    send_result = 0;
    send_error = ERROR_ACCESS_DENIED;
    CHECK(am_key_inject(VK_RCONTROL, 1) == -1);
    CHECK(strstr(reported_error, "Windows error 5") != NULL);
    send_error = 0;
    CHECK(am_key_inject(VK_RCONTROL, 1) == -1);
    CHECK(strstr(reported_error, "Windows error 0") != NULL);
    puts("Windows key capture/injection tests passed; desktop input APIs were stubbed.");
    return 0;
}
