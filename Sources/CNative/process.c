#include "CNative.h"
#ifdef _WIN32
#include <windows.h>
static HANDLE instance;
static volatile LONG stopped;
static BOOL WINAPI on_signal(DWORD code) {
    if (code == CTRL_C_EVENT || code == CTRL_BREAK_EVENT || code == CTRL_CLOSE_EVENT) {
        InterlockedExchange(&stopped, 1); return TRUE;
    }
    return FALSE;
}
int am_process_start(void) {
    instance = CreateMutexW(NULL, FALSE, L"Local\\AnyKeyMic-USB");
    if (!instance || GetLastError() == ERROR_ALREADY_EXISTS) return -1;
    SetConsoleCtrlHandler(on_signal, TRUE);
    return 0;
}
int am_should_stop(void) { return InterlockedCompareExchange(&stopped, 0, 0); }
#else
#include <signal.h>
#include <sys/file.h>
#include <unistd.h>
#include <stdio.h>
static int instance = -1;
static volatile sig_atomic_t stopped;
static void on_signal(int sig) { (void)sig; stopped = 1; }
int am_process_start(void) {
    char path[128];
    snprintf(path, sizeof(path), "/tmp/anykey-mic-%lu.lock", (unsigned long)getuid());
    instance = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    if (instance < 0 || flock(instance, LOCK_EX | LOCK_NB)) return -1;
    signal(SIGINT, on_signal); signal(SIGTERM, on_signal);
    return 0;
}
int am_should_stop(void) { return stopped != 0; }
#endif
