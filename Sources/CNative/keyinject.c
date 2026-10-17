#include "CNative.h"
#include <stdio.h>
#include <string.h>

#ifdef _WIN32
#include <windows.h>

int am_key_ready(void) { return 0; }

int am_key_inject(int keycode, int pressed) {
    INPUT input;
    memset(&input, 0, sizeof(input));
    input.type = INPUT_KEYBOARD;
    input.ki.wVk = (WORD)keycode;
    if (!pressed) input.ki.dwFlags = KEYEVENTF_KEYUP;
    return SendInput(1, &input, sizeof(input)) == 1 ? 0 : am_set_error("SendInput failed");
}

int am_key_capture(int *keycode, int timeout_ms) {
    if (!keycode) return am_set_error("Invalid capture target");
    SHORT previous[256];
    for (int vk = 0; vk < 256; ++vk) previous[vk] = GetAsyncKeyState((int)vk);
    ULONGLONG deadline = GetTickCount64() + (ULONGLONG)timeout_ms;
    for (;;) {
        Sleep(10);
        for (int vk = 7; vk < 256; ++vk) {
            SHORT state = GetAsyncKeyState(vk);
            if ((state & 0x8000) && !(previous[vk] & 0x8000)) {
                *keycode = vk;
                return 0;
            }
            previous[vk] = state;
        }
        if (GetTickCount64() >= deadline) return am_set_error("捕获超时，未检测到按键。");
    }
}

#elif defined(__APPLE__)
#include <ApplicationServices/ApplicationServices.h>

/* 修饰键到聚合 flags 掩码的映射；fn 与左右修饰键各自成对。 */
static CGEventFlags modifier_mask(CGKeyCode code) {
    switch (code) {
        case 56: case 60: return kCGEventFlagMaskShift;      /* 左/右 Shift */
        case 59: case 62: return kCGEventFlagMaskControl;    /* 左/右 Ctrl */
        case 58: case 61: return kCGEventFlagMaskAlternate;  /* 左/右 Option */
        case 55: case 54: return kCGEventFlagMaskCommand;    /* 左/右 Command */
        case 63: return kCGEventFlagMaskSecondaryFn;         /* fn */
        default: return 0;
    }
}

int am_key_ready(void) {
    if (AXIsProcessTrusted()) return 0;
    return am_set_error("注入按键需要在「系统设置 › 隐私与安全性 › 辅助功能」中允许本程序。");
}

int am_key_inject(int keycode, int pressed) {
    if (am_key_ready() != 0) return -1;
    /* 空 source 的修饰键事件不会更新全局修饰键状态，必须用 HID 系统态 source。 */
    static CGEventSourceRef source;
    if (!source) {
        source = CGEventSourceCreate(kCGEventSourceStateHIDSystemState);
        if (!source) return am_set_error("Cannot create event source");
    }
    CGKeyCode code = (CGKeyCode)keycode;
    CGEventRef event = CGEventCreateKeyboardEvent(source, code, pressed != 0);
    if (!event) return am_set_error("Cannot create keyboard event");
    /* 归零来源进程，伪装成硬件事件；输入法普遍过滤带进程来源的合成事件。 */
    CGEventSetIntegerValueField(event, kCGEventSourceUnixProcessID, 0);
    CGEventFlags mask = modifier_mask(code);
    if (mask) {
        CGEventFlags flags = CGEventGetFlags(event);
        CGEventSetFlags(event, pressed ? (flags | mask) : (flags & ~mask));
    }
    CGEventPost(kCGHIDEventTap, event);
    CFRelease(event);
    return 0;
}

struct capture_state {
    int code;
    int done;
};

static CGEventRef on_capture_event(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    (void)proxy;
    struct capture_state *state = info;
    CGKeyCode code = (CGKeyCode)CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
    int pressed;
    if (type == kCGEventKeyDown) {
        pressed = 1;
    } else {
        /* 合成事件在分发中查询 HID 状态可能仍为松开，回退用事件 flags 的聚合掩码判断方向。 */
        CGEventFlags mask = modifier_mask(code);
        pressed = CGEventSourceKeyState(kCGEventSourceStateHIDSystemState, code) ||
                  (mask && (CGEventGetFlags(event) & mask));
    }
    if (pressed) {
        state->code = (int)code;
        state->done = 1;
    }
    return event;
}

int am_key_capture(int *keycode, int timeout_ms) {
    if (!keycode) return am_set_error("Invalid capture target");
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventFlagsChanged);
    struct capture_state state = {0, 0};
    CFMachPortRef tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap,
                                         kCGEventTapOptionListenOnly, mask, on_capture_event, &state);
    if (!tap) return am_set_error("无法监听按键，请在「系统设置 › 隐私与安全性 › 输入监控」中允许本程序。");
    CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, tap, 0);
    CFRunLoopRef loop = CFRunLoopGetCurrent();
    CFRunLoopAddSource(loop, source, kCFRunLoopDefaultMode);
    CGEventTapEnable(tap, true);
    CFAbsoluteTime deadline = CFAbsoluteTimeGetCurrent() + timeout_ms / 1000.0;
    while (!state.done) {
        CFAbsoluteTime left = deadline - CFAbsoluteTimeGetCurrent();
        if (left <= 0) break;
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, left, true);
    }
    CGEventTapEnable(tap, false);
    CFRunLoopRemoveSource(loop, source, kCFRunLoopDefaultMode);
    CFRelease(source);
    CFRelease(tap);
    if (!state.done) return am_set_error("捕获超时，未检测到按键。");
    *keycode = state.code;
    return 0;
}

#else
#error "Only Windows and macOS are supported"
#endif
