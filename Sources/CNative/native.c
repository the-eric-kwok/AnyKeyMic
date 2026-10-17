#include "CNative.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include "vendor/hidapi/hidapi/hidapi.h"
#ifdef __APPLE__
#include "vendor/hidapi/mac/hidapi_darwin.h"
#endif
#define MA_NO_DECODING
#define MA_NO_ENCODING
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MINIAUDIO_IMPLEMENTATION
#include "vendor/miniaudio/miniaudio.h"

#ifdef _WIN32
#include <windows.h>
static volatile LONG audio_alive;
static volatile LONG audio_event;
static void set_alive(int value) { InterlockedExchange(&audio_alive, value); }
static int get_alive(void) { return (int)InterlockedCompareExchange(&audio_alive, 0, 0); }
static void set_audio_event(int value) { InterlockedExchange(&audio_event, value); }
static int take_audio_event(void) { return (int)InterlockedExchange(&audio_event, 0); }
#else
#include <stdatomic.h>
static atomic_int audio_alive;
static atomic_int audio_event;
static void set_alive(int value) { atomic_store(&audio_alive, value); }
static int get_alive(void) { return atomic_load(&audio_alive); }
static void set_audio_event(int value) { atomic_store(&audio_event, value); }
static int take_audio_event(void) { return atomic_exchange(&audio_event, 0); }
#endif

static char last_error[256];
static int initialized, device_initialized, ring_initialized;
static struct hid_device_info *hid_list;
static hid_device *keyboard;
static ma_context context;
static ma_device device;
static ma_pcm_rb ring;
static ma_device_info *outputs;
static ma_uint32 output_count;
static char id_text[2048];

static int contains_case_insensitive(const char *text, const char *needle) {
    if (!text || !needle || !*needle) return 0;
    for (; *text; ++text) {
        const char *a = text;
        const char *b = needle;
        while (*a && *b && tolower((unsigned char)*a) == tolower((unsigned char)*b)) {
            ++a;
            ++b;
        }
        if (!*b) return 1;
    }
    return 0;
}

/* 供各源文件共用的错误通道；返回 -1 方便调用方直接 return。 */
int am_set_error(const char *message) {
    snprintf(last_error, sizeof(last_error), "%s", message);
    return -1;
}
static int audio_fail(const char *operation, ma_result result) {
    snprintf(last_error, sizeof(last_error), "%s: %s (%d)", operation,
             ma_result_description(result), (int)result);
    return -1;
}
const char *am_error(void) { return last_error; }

static struct hid_device_info *hid_at(int index) {
    if (index < 0) return NULL;
    for (struct hid_device_info *p = hid_list; p; p = p->next) {
        int known_vendor = p->vendor_id == 0x248a;
        int bluetooth_path = contains_case_insensitive(p->path, "pid&8243") &&
            contains_case_insensitive(p->path, "&col02");
        int bluetooth_product = p->product_id == 0x8243 || bluetooth_path;
        if ((known_vendor && p->product_id == 0x8102 && p->usage_page >= 0xff00) ||
            (bluetooth_product && (p->usage_page >= 0xff00 || bluetooth_path))) {
            if (index-- == 0) return p;
        }
    }
    return NULL;
}

int am_init(void) {
    if (initialized) return 0;
    last_error[0] = 0;
    if (hid_init() != 0) return am_set_error("HID initialization failed");
#ifdef __APPLE__
    hid_darwin_set_open_exclusive(0);
    ma_backend backend = ma_backend_coreaudio;
#elif defined(_WIN32)
    ma_backend backend = ma_backend_wasapi;
#else
#error "Only Windows and macOS are supported"
#endif
    ma_result result = ma_context_init(&backend, 1, NULL, &context);
    if (result != MA_SUCCESS) { hid_exit(); return audio_fail("Audio initialization", result); }
    initialized = 1;
    hid_list = hid_enumerate(0, 0);
    ma_device_info *found = NULL;
    result = ma_context_get_devices(&context, &found, &output_count, NULL, NULL);
    if (result != MA_SUCCESS) { am_shutdown(); return audio_fail("Output enumeration", result); }
    if (output_count) {
        outputs = calloc(output_count, sizeof(*outputs));
        if (!outputs) { am_shutdown(); return am_set_error("Output allocation failed"); }
        memcpy(outputs, found, output_count * sizeof(*outputs));
    }
    return 0;
}

void am_hid_close(void) { if (keyboard) { hid_close(keyboard); keyboard = NULL; } }
void am_shutdown(void) {
    am_audio_close();
    am_hid_close();
    hid_free_enumeration(hid_list); hid_list = NULL;
    free(outputs); outputs = NULL; output_count = 0;
    if (initialized) { ma_context_uninit(&context); hid_exit(); initialized = 0; }
}
int am_hid_count(void) {
    if (!initialized) return am_set_error("Not initialized");
    int count = 0;
    while (hid_at(count)) ++count;
    return count;
}
int am_hid_product_id(int index) {
    struct hid_device_info *p = hid_at(index);
    if (!p) return 0;
    return p->product_id == 0 && contains_case_insensitive(p->path, "pid&8243") ? 0x8243 : (int)p->product_id;
}
int am_hid_usage_page(int index) { struct hid_device_info *p = hid_at(index); return p ? (int)p->usage_page : 0; }
const char *am_hid_path(int index) {
    struct hid_device_info *p = hid_at(index);
    return p ? p->path : NULL;
}
int am_hid_open(int index) {
    struct hid_device_info *p = hid_at(index);
    if (!p) return am_set_error("Invalid HID index");
    am_hid_close();
    keyboard = hid_open_path(p->path);
    return keyboard ? 0 : am_set_error("Cannot open selected HID interface");
}
int am_hid_read(uint8_t *data, int capacity) {
    if (!keyboard || !data || capacity <= 0) return am_set_error("Invalid HID read");
    int count = hid_read_timeout(keyboard, data, (size_t)capacity, 50);
    return count < 0 ? am_set_error("HID read failed or device disconnected") : count;
}
int am_hid_write(const uint8_t *data, int length) {
    if (!keyboard || !data || length <= 0) return am_set_error("Invalid HID write");
    int count = hid_write(keyboard, data, (size_t)length);
    return count < 0 ? am_set_error("HID write failed") : count;
}
int am_output_count(void) { return initialized ? (int)output_count : am_set_error("Not initialized"); }
const char *am_output_name(int index) {
    return index >= 0 && (ma_uint32)index < output_count ? outputs[index].name : NULL;
}
const char *am_output_id(int index) {
    if (!am_output_name(index)) return NULL;
#ifdef _WIN32
    if (!WideCharToMultiByte(CP_UTF8, 0, outputs[index].id.wasapi, -1,
                             id_text, sizeof(id_text), NULL, NULL)) return NULL;
#else
    snprintf(id_text, sizeof(id_text), "%s", outputs[index].id.coreaudio);
#endif
    return id_text;
}

static void audio_callback(ma_device *unused, void *output, const void *input, ma_uint32 frames) {
    (void)unused; (void)input;
    int16_t *dst = output;
    memset(dst, 0, frames * sizeof(*dst));
    if (!get_alive()) return;
    while (frames) {
        ma_uint32 available = frames;
        void *source = NULL;
        if (ma_pcm_rb_acquire_read(&ring, &available, &source) != MA_SUCCESS || !available) break;
        memcpy(dst, source, available * sizeof(*dst));
        ma_pcm_rb_commit_read(&ring, available);
        dst += available; frames -= available;
    }
}
static void audio_notification(const ma_device_notification *notification) {
    if (notification->type == ma_device_notification_type_stopped) {
        set_audio_event(1);
        set_alive(0);
    } else if (notification->type == ma_device_notification_type_rerouted) {
        set_audio_event(2);
        set_alive(0);
    }
}
int am_audio_open(int index) {
    if (!initialized || !am_output_name(index)) return am_set_error("Invalid output index");
    am_audio_close();
    take_audio_event();
    ma_result result = ma_pcm_rb_init(ma_format_s16, 1, 8192, NULL, NULL, &ring);
    if (result != MA_SUCCESS) return audio_fail("Audio queue", result);
    ring_initialized = 1;
    ma_device_config config = ma_device_config_init(ma_device_type_playback);
    config.playback.pDeviceID = &outputs[index].id;
    config.playback.format = ma_format_s16;
    config.playback.channels = 1;
    config.sampleRate = 16000;
    config.dataCallback = audio_callback;
    config.notificationCallback = audio_notification;
    config.wasapi.noAutoStreamRouting = MA_TRUE;
    result = ma_device_init(&context, &config, &device);
    if (result != MA_SUCCESS) { am_audio_close(); return audio_fail("Selected output initialization", result); }
    device_initialized = 1;
    set_alive(1);
    result = ma_device_start(&device);
    if (result != MA_SUCCESS) { am_audio_close(); return audio_fail("Selected output start", result); }
    return 0;
}
int am_audio_push(const int16_t *samples, int frames) {
    if (!samples || frames < 0 || !am_audio_alive()) return am_set_error("Audio output unavailable");
    int accepted = 0;
    while (accepted < frames) {
        ma_uint32 available = (ma_uint32)(frames - accepted);
        void *destination = NULL;
        if (ma_pcm_rb_acquire_write(&ring, &available, &destination) != MA_SUCCESS || !available) break;
        memcpy(destination, samples + accepted, available * sizeof(*samples));
        ma_pcm_rb_commit_write(&ring, available);
        accepted += (int)available;
    }
    return accepted;
}
int am_audio_alive(void) { return device_initialized && get_alive(); }
int am_audio_event(void) {
    return take_audio_event();
}
void am_audio_close(void) {
    set_alive(0);
    if (device_initialized) { ma_device_uninit(&device); device_initialized = 0; }
    if (ring_initialized) { ma_pcm_rb_uninit(&ring); ring_initialized = 0; }
}
