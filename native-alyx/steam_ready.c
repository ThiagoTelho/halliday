// Real native Steam IPC readiness. Never starts Steam or a game, creates a
// local user, or changes ownership. Steam runs in an isolated, bounded child.
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum Status { READY, LIBRARY_MISSING, PIPE_MISSING, USER_MISSING,
              EXPORT_MISSING, PROBE_FAILED, PROBE_TIMEOUT };
typedef struct { int status, online; } Result;
static volatile sig_atomic_t cancelled;
static pid_t owner_pid;
static uint64_t owner_seconds, owner_micros;
static bool owner_alive(void) {
    if (!owner_pid) return true;
    struct proc_bsdinfo info;
    return proc_pidinfo(owner_pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info) &&
        info.pbi_start_tvsec == owner_seconds && info.pbi_start_tvusec == owner_micros;
}
static void cancel(int signal_number) { cancelled = signal_number; }
static uint64_t millis(void) {
    struct timespec value;
    clock_gettime(CLOCK_MONOTONIC, &value);
    return (uint64_t)value.tv_sec * 1000 + (uint64_t)value.tv_nsec / 1000000;
}
static void pause_ms(unsigned ms) {
    struct timespec value = {(time_t)(ms / 1000), (long)(ms % 1000) * 1000000};
    while (nanosleep(&value, &value) && errno == EINTR && !cancelled) {}
}
static Result probe(const char *library) {
    Result result = {LIBRARY_MISSING, -1};
    void *module = dlopen(library, RTLD_NOW | RTLD_LOCAL);
    if (!module) return result;
    int32_t (*create)(void) = (int32_t (*)(void))dlsym(module, "Steam_CreateSteamPipe");
    int32_t (*connect_user)(int32_t) = (int32_t (*)(int32_t))dlsym(module, "Steam_ConnectToGlobalUser");
    void (*release_user)(int32_t, int32_t) = (void (*)(int32_t, int32_t))dlsym(module, "Steam_ReleaseUser");
    bool (*release_pipe)(int32_t) = (bool (*)(int32_t))dlsym(module, "Steam_BReleaseSteamPipe");
    bool (*logged_on)(int32_t, int32_t) = (bool (*)(int32_t, int32_t))dlsym(module, "Steam_BLoggedOn");
    result.status = EXPORT_MISSING;
    if (create && connect_user && release_user && release_pipe) {
        int32_t pipe = create();
        result.status = PIPE_MISSING;
        if (pipe != 0) {
            int32_t user = connect_user(pipe);
            result.status = USER_MISSING;
            if (user != 0) {
                result.status = READY;
                // Online is useful context, not a condition for local/offline play.
                if (logged_on) result.online = logged_on(user, pipe) ? 1 : 0;
                release_user(pipe, user);
            }
            release_pipe(pipe);
        }
    }
    dlclose(module);
    return result;
}
static void reap(pid_t child) {
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}
static Result bounded_probe(const char *library, uint64_t deadline, unsigned probe_ms) {
    Result result = {PROBE_FAILED, -1};
    int channel[2];
    if (pipe(channel)) return result;
    pid_t child = fork();
    if (child == 0) {
        signal(SIGTERM, SIG_DFL); signal(SIGINT, SIG_DFL);
        close(channel[0]);
        int quiet = open("/dev/null", O_WRONLY);
        if (quiet >= 0) { dup2(quiet, STDOUT_FILENO); dup2(quiet, STDERR_FILENO); close(quiet); }
        Result value = probe(library);
        ssize_t written;
        do { written = write(channel[1], &value, sizeof(value)); } while (written < 0 && errno == EINTR);
        close(channel[1]);
        _exit(written == sizeof(value) ? 0 : 1);
    }
    close(channel[1]);
    if (child < 0) { close(channel[0]); return result; }
    uint64_t limit = millis() + probe_ms;
    if (limit > deadline) limit = deadline;
    int status = 0;
    for (;;) {
        pid_t state = waitpid(child, &status, WNOHANG);
        if (state == child) break;
        if (state < 0 && errno != EINTR) { close(channel[0]); return result; }
        if (cancelled || !owner_alive() || millis() >= limit) {
            kill(child, SIGKILL); reap(child); close(channel[0]);
            result.status = PROBE_TIMEOUT;
            return result;
        }
        pause_ms(10);
    }
    if (WIFEXITED(status) && WEXITSTATUS(status) == 0) {
        ssize_t count;
        do { count = read(channel[0], &result, sizeof(result)); } while (count < 0 && errno == EINTR);
        if (count != sizeof(result) || result.status < READY || result.status > PROBE_TIMEOUT)
            result = (Result){PROBE_FAILED, -1};
    }
    close(channel[0]);
    return result;
}
static bool number(const char *text, unsigned maximum, unsigned *output) {
    char *end; errno = 0;
    unsigned long value = strtoul(text, &end, 10);
    if (errno || !*text || *end || value < 1 || value > maximum) return false;
    *output = (unsigned)value; return true;
}
int main(int argc, char **argv) {
    const char *library = NULL;
    unsigned timeout_ms = 45000, probe_ms = 2000, interval_ms = 250;
    for (int index = 1; index < argc; ++index) {
        const char *option = argv[index];
        if (++index >= argc) return 64;
        if (!strcmp(option, "--library")) library = argv[index];
        else if (!strcmp(option, "--owner-pid")) { unsigned value; if (!number(argv[index],INT_MAX,&value)) return 64; owner_pid=(pid_t)value; }
        else if (!strcmp(option, "--timeout-ms")) { if (!number(argv[index],45000,&timeout_ms)) return 64; }
        else if (!strcmp(option, "--probe-timeout-ms")) { if (!number(argv[index],2000,&probe_ms)) return 64; }
        else if (!strcmp(option, "--interval-ms")) { if (!number(argv[index],1000,&interval_ms)) return 64; }
        else return 64;
    }
    if (!library || library[0] != '/') return 64;
    if (owner_pid) {
        struct proc_bsdinfo info;
        if (proc_pidinfo(owner_pid,PROC_PIDTBSDINFO,0,&info,sizeof(info)) != sizeof(info)) return 70;
        owner_seconds=info.pbi_start_tvsec; owner_micros=info.pbi_start_tvusec;
    }
    struct sigaction action = {0}; action.sa_handler = cancel;
    sigemptyset(&action.sa_mask); sigaction(SIGTERM, &action, NULL); sigaction(SIGINT, &action, NULL);
    uint64_t start = millis(), deadline = start + timeout_ms;
    int previous = -1; unsigned attempts = 0;
    const char *names[] = {"ready", "library-unavailable", "client-starting", "user-starting",
                           "unsupported-client-library", "probe-failed", "probe-timeout"};
    puts("Waiting for native Steam's local client and user before starting Alyx..."); fflush(stdout);
    do {
        Result result = bounded_probe(library, deadline, probe_ms); ++attempts;
        if (cancelled) return 128 + cancelled;
        if (!owner_alive()) {
            fputs("Alyx was not started: the Halliday launch owner closed.\n",stderr);
            return 70;
        }
        if (result.status != previous || result.status == READY) {
            printf("Steam readiness: %s%s\n", names[result.status], result.status == READY && result.online == 0 ? " (offline client supported)" : "");
            fflush(stdout); previous = result.status;
        }
        if (result.status == READY) {
            printf("Steam IPC ready after %u attempt(s), %llu ms. Starting the owned game's normal Steam API.\n",
                attempts, (unsigned long long)(millis()-start));
            return 0;
        }
        if (result.status == EXPORT_MISSING) break;
        uint64_t now = millis();
        if (now >= deadline) break;
        unsigned rest = (unsigned)(deadline-now);
        pause_ms(interval_ms < rest ? interval_ms : rest);
    } while (!cancelled && millis() < deadline);
    if (cancelled) return 128 + cancelled;
    fputs("Alyx was not started: native Steam's local client/user is unavailable. Open Steam for Mac, sign in or enter its offline mode, then retry.\n",stderr);
    return 70;
}
