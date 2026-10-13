/* 后端源文件仅在此处编译一次；SwiftPM 排除 vendor 中独立源文件。 */
#if defined(_WIN32)
#include "vendor/hidapi/windows/hid.c"
#elif defined(__APPLE__)
#include "vendor/hidapi/mac/hid.c"
#else
#error "Only Windows and macOS are supported"
#endif
