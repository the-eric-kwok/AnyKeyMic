#include "CNative.h"
#ifndef _WIN32
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
