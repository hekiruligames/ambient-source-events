#include <fcntl.h>
#include <signal.h>
#include <unistd.h>

static int crash_fd = -1;

static void crash_handler(int signum) {
    static const char marker[] = "FAIL: native crash\n";
    if (crash_fd >= 0) {
        (void)write(crash_fd, marker, sizeof(marker) - 1);
    }
    _exit(128 + signum);
}

int native_guard_install(const char *marker_path) {
    struct sigaction action = {0};
    int fd = open(marker_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
    if (fd < 0) return 0;
    crash_fd = fd;
    action.sa_handler = crash_handler;
    sigemptyset(&action.sa_mask);
    action.sa_flags = 0;
    if (sigaction(SIGSEGV, &action, NULL) != 0 ||
        sigaction(SIGBUS, &action, NULL) != 0 ||
        sigaction(SIGABRT, &action, NULL) != 0) {
        close(fd);
        crash_fd = -1;
        return 0;
    }
    return 1;
}
