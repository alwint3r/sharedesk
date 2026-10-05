#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <ifaddrs.h>
#include <limits.h>
#include <net/if.h>
#include <poll.h>
#include <pwd.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/resource.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <systemd/sd-login.h>
#include <time.h>
#include <unistd.h>

#define HOST_BINARY "/usr/local/libexec/sharedesk/sharedesk-host"
#define PASSWORD_FILE "/etc/sharedesk/vnc-password"

/* This root process never opens an X display or a VNC socket. It selects one
 * active GDM X11 session on seat0 and runs the existing host as that session's
 * user. No user-session environment, shell command, or Xauthority cookie is
 * imported into the privileged process. */
typedef struct {
    char session[128], display[32], authority[128], address[INET_ADDRSTRLEN];
    char user[256], home[PATH_MAX];
    uid_t uid;
    gid_t gid;
    pid_t xserver;
    dev_t socket_device;
    ino_t socket_inode;
    dev_t authority_device;
    ino_t authority_inode;
    struct timespec authority_modified;
    bool greeter;
} Target;

static volatile sig_atomic_t stopping;
static void stop_service(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

static int64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) abort();
    return (int64_t)now.tv_sec * 1000 + now.tv_nsec / 1000000;
}

static int number(const char *text, int low, int high) {
    char *end;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno || end == text || *end || value < low || value > high) return -1;
    return (int)value;
}

static bool tailscale_address(char address[INET_ADDRSTRLEN]) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return false;
    uint32_t selected = 0;
    bool ambiguous = false;
    for (struct ifaddrs *entry = interfaces; entry; entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET ||
            strcmp(entry->ifa_name, "tailscale0") || !(entry->ifa_flags & IFF_UP)) continue;
        uint32_t candidate = ((struct sockaddr_in *)entry->ifa_addr)->sin_addr.s_addr;
        if ((ntohl(candidate) & 0xffc00000U) != 0x64400000U) continue;
        if (selected && selected != candidate) ambiguous = true;
        selected = candidate;
    }
    freeifaddrs(interfaces);
    return selected && !ambiguous && inet_ntop(AF_INET, &selected, address, INET_ADDRSTRLEN);
}

/* GDM starts Xorg with -displayfd: logind can have an empty DISPLAY and
 * Xorg creates no .Xn-lock file. Identify the local listener using Linux
 * SO_PEERCRED instead: the kernel's peer PID must belong to the exact active
 * logind session. Match Ubuntu libxcb's abstract-first Unix socket selection,
 * falling back to the filesystem socket only when that alias is absent. The
 * nonblocking socket is closed without sending X11 setup, cookies or data.
 * Never guess :0 or read a user's environment.
 *
 * While a worker is running, retain that verified binding only while the
 * socket inode and PID's session still match. This avoids repeatedly opening
 * local connections during ordinary capture. A new binding must be unique. */
static bool session_display(const char *session, uid_t uid, const Target *current, Target *target) {
    if (current && current->uid == uid && !strcmp(current->session, session)) {
        char path[64];
        snprintf(path, sizeof path, "/tmp/.X11-unix/X%s", current->display + 1);
        struct stat socket_info;
        char *owner_session = NULL;
        bool valid = lstat(path, &socket_info) == 0 && S_ISSOCK(socket_info.st_mode) &&
            socket_info.st_dev == current->socket_device && socket_info.st_ino == current->socket_inode &&
            (socket_info.st_uid == uid || socket_info.st_uid == 0) &&
            sd_pid_get_session(current->xserver, &owner_session) >= 0 &&
            owner_session && !strcmp(owner_session, session);
        free(owner_session);
        if (valid) {
            strcpy(target->display, current->display);
            target->xserver = current->xserver;
            target->socket_device = current->socket_device;
            target->socket_inode = current->socket_inode;
            return true;
        }
    }
    bool found = false;
    for (int display_number = 0; display_number < 64; ++display_number) {
        struct sockaddr_un address = {.sun_family = AF_UNIX};
        snprintf(address.sun_path, sizeof address.sun_path, "/tmp/.X11-unix/X%d", display_number);
        struct stat socket_info;
        if (lstat(address.sun_path, &socket_info) != 0 || !S_ISSOCK(socket_info.st_mode) ||
            (socket_info.st_uid != uid && socket_info.st_uid != 0)) continue;
        struct sockaddr_un abstract = {.sun_family = AF_UNIX};
        size_t path_length = strlen(address.sun_path);
        memcpy(abstract.sun_path + 1, address.sun_path, path_length);
        socklen_t abstract_size = (socklen_t)(offsetof(struct sockaddr_un, sun_path) + 1 + path_length);
        int fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
        if (fd < 0) return false;
        int connected = connect(fd, (struct sockaddr *)&abstract, abstract_size);
        if (connected != 0 && (errno == ENOENT || errno == ECONNREFUSED)) {
            close(fd);
            fd = socket(AF_UNIX, SOCK_STREAM | SOCK_CLOEXEC | SOCK_NONBLOCK, 0);
            if (fd < 0) return false;
            connected = connect(fd, (struct sockaddr *)&address, sizeof address);
        }
        struct ucred peer = {0};
        socklen_t peer_size = sizeof peer;
        bool valid = connected == 0 &&
            getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &peer, &peer_size) == 0 &&
            peer_size == sizeof peer && peer.pid > 1 && (peer.uid == uid || peer.uid == 0);
        close(fd);
        if (!valid) continue;
        char *owner_session = NULL;
        valid = sd_pid_get_session(peer.pid, &owner_session) >= 0 &&
            owner_session && !strcmp(owner_session, session);
        free(owner_session);
        if (!valid) continue;
        if (found) return false;
        snprintf(target->display, sizeof target->display, ":%d", display_number);
        target->xserver = peer.pid;
        target->socket_device = socket_info.st_dev;
        target->socket_inode = socket_info.st_ino;
        found = true;
    }
    return found;
}

/* A NULL result means ready. Otherwise the returned static message explains
 * why nothing may be shared. The caller logs only changes of this state. */
static const char *select_target(const char *desktop_user, uid_t desktop_uid, uid_t greeter_uid,
                                 const Target *current, Target *target) {
    char *session = NULL, *type = NULL, *class = NULL, *service = NULL, *seat = NULL, *state = NULL;
    uid_t seat_uid = 0, session_uid = 0;
    const char *reason = "Waiting for an active graphical session on seat0.";
    if (sd_seat_get_active("seat0", &session, &seat_uid) < 0 || !session ||
        sd_session_is_active(session) <= 0 || sd_session_is_remote(session) != 0 ||
        sd_session_get_uid(session, &session_uid) < 0 || session_uid != seat_uid ||
        sd_session_get_seat(session, &seat) < 0 || strcmp(seat, "seat0") ||
        sd_session_get_state(session, &state) < 0 || strcmp(state, "active")) goto done;
    reason = "Active session is not a supported GDM session; no desktop is shared.";
    if (sd_session_get_class(session, &class) < 0 ||
        sd_session_get_service(session, &service) < 0) goto done;
    target->greeter = !strcmp(class, "greeter") && seat_uid == greeter_uid &&
        !strcmp(service, "gdm-launch-environment");
    bool desktop = !strcmp(class, "user") && seat_uid == desktop_uid &&
        !strncmp(service, "gdm-", 4);
    if (!target->greeter && !desktop) goto done;
    reason = "Active GDM session is not X11. An Xorg login screen and desktop are required.";
    if (sd_session_get_type(session, &type) < 0 || strcmp(type, "x11")) goto done;
    struct passwd *account = getpwuid(seat_uid);
    reason = "Cannot resolve the active session account safely.";
    if (!account || account->pw_uid == 0 ||
        (desktop && strcmp(account->pw_name, desktop_user)) ||
        (target->greeter && strcmp(account->pw_name, "gdm")) ||
        strlen(session) >= sizeof target->session ||
        strlen(account->pw_name) >= sizeof target->user ||
        strlen(account->pw_dir) >= sizeof target->home) goto done;
    strcpy(target->session, session);
    strcpy(target->user, account->pw_name);
    strcpy(target->home, account->pw_dir);
    target->uid = account->pw_uid;
    target->gid = account->pw_gid;
    snprintf(target->authority, sizeof target->authority, "/run/user/%lu/gdm/Xauthority", (unsigned long)seat_uid);
    struct stat authority;
    reason = "Waiting for the active session's private GDM Xauthority file.";
    if (lstat(target->authority, &authority) != 0 || !S_ISREG(authority.st_mode) ||
        authority.st_uid != seat_uid || (authority.st_mode & 077) ||
        authority.st_size < 1 || authority.st_size > 16384) goto done;
    target->authority_device = authority.st_dev;
    target->authority_inode = authority.st_ino;
    target->authority_modified = authority.st_mtim;
    reason = "Waiting for a Tailscale IPv4 address on tailscale0; no fallback listener.";
    if (!tailscale_address(target->address)) goto done;
    reason = "Waiting for one local Xorg display owned by the active session.";
    if (!session_display(session, seat_uid, current, target)) goto done;
    reason = NULL;
done:
    free(session);
    free(type);
    free(class);
    free(service);
    free(seat);
    free(state);
    return reason;
}

static _Noreturn void child_failure(const char *operation) {
    fprintf(stderr, "Cannot start session host: %s: %s\n", operation, strerror(errno));
    _exit(77);
}

static pid_t start_host(const Target *target, const char *port, const char *fps, bool stats, bool clipboard) {
    int password = open(PASSWORD_FILE, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK);
    struct stat file;
    if (password < 0 || fstat(password, &file) != 0 || !S_ISREG(file.st_mode) ||
        file.st_uid != 0 || (file.st_mode & 077) || file.st_size < 1 || file.st_size > 9) {
        fprintf(stderr, "Cannot open the private root-owned service password. No host started.\n");
        if (password >= 0) close(password);
        return -1;
    }
    pid_t parent = getpid();
    pid_t child = fork();
    if (child == 0) {
        /* The host receives only an open, read-only password descriptor. The
         * root-owned file remains inaccessible by pathname after privilege
         * drop; its bytes never enter argv, environment or supervisor logs. */
        if (dup2(password, 3) < 0 || fcntl(3, F_SETFD, 0) < 0) child_failure("transfer password descriptor");
        if (password != 3) close(password);
        struct sigaction action = {.sa_handler = SIG_DFL};
        sigemptyset(&action.sa_mask);
        sigaction(SIGTERM, &action, NULL);
        sigaction(SIGINT, &action, NULL);
        if (initgroups(target->user, target->gid) != 0) child_failure("initialize session groups");
        if (setresgid(target->gid, target->gid, target->gid) != 0) child_failure("drop group privileges");
        if (setresuid(target->uid, target->uid, target->uid) != 0) child_failure("drop user privileges");
        if (getuid() != target->uid || geteuid() != target->uid) {
            fprintf(stderr, "Cannot start session host: session credentials did not match.\n");
            _exit(77);
        }
        /* Credential changes clear PDEATHSIG, so set it after dropping UID. */
        if (prctl(PR_SET_PDEATHSIG, SIGTERM, 0, 0, 0) != 0) child_failure("watch supervisor lifetime");
        if (getppid() != parent) _exit(77);
        if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) child_failure("prevent privilege acquisition");
        /* Select Unix transport explicitly: no TCP fallback. The host checks
         * the connected peer PID again before capturing or opening VNC. */
        char display[40];
        snprintf(display, sizeof display, "unix/%s", target->display);
        if (clearenv() != 0 ||
            setenv("PATH", "/usr/bin:/bin", 1) != 0 ||
            setenv("HOME", target->home, 1) != 0 ||
            setenv("USER", target->user, 1) != 0 ||
            setenv("LOGNAME", target->user, 1) != 0 ||
            setenv("DISPLAY", display, 1) != 0 ||
            setenv("XAUTHORITY", target->authority, 1) != 0) child_failure("create clean session environment");
        char runtime[64];
        snprintf(runtime, sizeof runtime, "/run/user/%lu", (unsigned long)target->uid);
        if (setenv("XDG_RUNTIME_DIR", runtime, 1) != 0 || chdir("/") != 0) child_failure("set session runtime directory");
        char server_pid[32];
        snprintf(server_pid, sizeof server_pid, "%ld", (long)target->xserver);
        char *arguments[16] = {HOST_BINARY, "--listen", (char *)target->address,
            "--password-fd", "3", "--port", (char *)port, "--fps", (char *)fps,
            "--x11-server-pid", server_pid};
        size_t count = 11;
        if (stats) arguments[count++] = "--stats";
        if (clipboard && !target->greeter) arguments[count++] = "--clipboard";
        arguments[count] = NULL;
        /* Do not give an unprivileged worker any unrelated inherited root
         * descriptors. Ubuntu 22.04's glibc closefrom also handles kernels or
         * emulators without close_range; it terminates if closing fails. */
        closefrom(4);
        execv(HOST_BINARY, arguments);
        perror("Executing unprivileged Sharedesk host");
        _exit(77);
    }
    close(password);
    if (child < 0) perror("Starting session host");
    return child;
}

int main(int argc, char **argv) {
    const char *user = NULL, *port = "5901", *fps = "30";
    bool stats = false, clipboard = false;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--user") && i + 1 < argc) user = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = argv[++i];
        else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = argv[++i];
        else if (!strcmp(argv[i], "--stats")) stats = true;
        else if (!strcmp(argv[i], "--clipboard")) clipboard = true;
        else {
            fprintf(stderr, "Usage: sharedesk-login-service --user USER [--port 5901] [--fps 30] [--stats] [--clipboard]\n");
            return 64;
        }
    }
    if (!user || number(port, 1, 65535) < 0 || number(fps, 1, 30) < 0) {
        fprintf(stderr, "A desktop user, valid port and capture rate are required.\n");
        return 64;
    }
    if (getuid() != 0 || geteuid() != 0) {
        fprintf(stderr, "The login-session supervisor must run as root, normally through systemd.\n");
        return 77;
    }
    struct passwd *account = getpwnam(user);
    if (!account || account->pw_uid < 1000 || account->pw_uid == 65534 || account->pw_uid == (uid_t)-1) {
        fprintf(stderr, "Choose a normal desktop account (UID at least 1000), not root or gdm.\n");
        return 78;
    }
    uid_t desktop_uid = account->pw_uid;
    account = getpwnam("gdm");
    if (!account || account->pw_uid == 0 || account->pw_uid == desktop_uid) {
        fprintf(stderr, "The GDM greeter account is unavailable or is the configured desktop account.\n");
        return 78;
    }
    uid_t greeter_uid = account->pw_uid;
    /* Reject an untrusted installed worker or a writable containing directory.
     * The installer uses these fixed system paths; no checkout is executed. */
    const char *paths[] = {"/usr", "/usr/local", "/usr/local/libexec", "/usr/local/libexec/sharedesk", HOST_BINARY,
                          "/etc", "/etc/sharedesk"};
    for (size_t i = 0; i < sizeof paths / sizeof paths[0]; ++i) {
        struct stat details;
        bool binary = !strcmp(paths[i], HOST_BINARY);
        bool trusted = false;
        if (lstat(paths[i], &details) == 0 && details.st_uid == 0 && !(details.st_mode & 022)) {
            if (binary) {
                trusted = S_ISREG(details.st_mode) && (details.st_mode & 0111) && !(details.st_mode & 06000);
            } else {
                trusted = S_ISDIR(details.st_mode);
            }
        }
        if (!trusted) {
            fprintf(stderr, "Unsafe or missing installed host path: %s\n", paths[i]);
            return 78;
        }
    }
    struct rlimit no_core = {0, 0};
    if (setrlimit(RLIMIT_CORE, &no_core) != 0 || prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) != 0) {
        perror("Restricting supervisor privileges");
        return 77;
    }
    umask(077);
    struct sigaction action = {.sa_handler = stop_service};
    sigemptyset(&action.sa_mask);
    sigaction(SIGTERM, &action, NULL);
    sigaction(SIGINT, &action, NULL);
    struct sigaction children = {.sa_handler = SIG_DFL};
    sigemptyset(&children.sa_mask);
    sigaction(SIGCHLD, &children, NULL); /* Keep children waitable; no PID-reuse signal race. */
    sigset_t unblocked;
    sigemptyset(&unblocked);
    sigprocmask(SIG_SETMASK, &unblocked, NULL);
    sd_login_monitor *monitor = NULL;
    int error = sd_login_monitor_new(NULL, &monitor);
    if (error < 0) {
        fprintf(stderr, "Cannot monitor login sessions: %s\n", strerror(-error));
        return 1;
    }
    struct pollfd watch = {.fd = sd_login_monitor_get_fd(monitor), .events = POLLIN};
    Target current = {0};
    pid_t child = -1;
    int64_t stop_deadline = 0, retry_at = 0;
    const char *last_reason = NULL;
    fprintf(stderr, "Supervising GDM and desktop UID %lu on seat0. Session changes require manual VNC reconnect.\n", (unsigned long)desktop_uid);
    while (!stopping || child > 0) {
        int64_t now = milliseconds();
        if (child > 0) {
            int status = 0;
            pid_t reaped = waitpid(child, &status, WNOHANG);
            if (reaped == child || (reaped < 0 && errno == ECHILD)) {
                if (!stop_deadline) {
                    if (WIFEXITED(status)) fprintf(stderr, "Session host exited with status %d; retrying after five seconds.\n", WEXITSTATUS(status));
                    else fprintf(stderr, "Session host ended unexpectedly; retrying after five seconds.\n");
                    retry_at = now + 5000;
                } else retry_at = now;
                child = -1;
                stop_deadline = 0;
            }
        }
        Target next = {0};
        const char *reason = stopping ? "Stopping the login-session supervisor." :
            select_target(user, desktop_uid, greeter_uid, child > 0 ? &current : NULL, &next);
        if (reason != last_reason) {
            if (reason) fprintf(stderr, "%s\n", reason);
            last_reason = reason;
        }
        bool same = !reason && current.uid == next.uid && current.gid == next.gid &&
            current.greeter == next.greeter && current.xserver == next.xserver &&
            current.socket_device == next.socket_device && current.socket_inode == next.socket_inode &&
            !strcmp(current.session, next.session) && !strcmp(current.display, next.display) &&
            !strcmp(current.address, next.address) && !strcmp(current.user, next.user) && !strcmp(current.home, next.home) &&
            current.authority_device == next.authority_device && current.authority_inode == next.authority_inode &&
            current.authority_modified.tv_sec == next.authority_modified.tv_sec &&
            current.authority_modified.tv_nsec == next.authority_modified.tv_nsec;
        if (child > 0 && !same && !stop_deadline) {
            fprintf(stderr, "Session or Tailscale availability changed; stopping the old host before any handoff.\n");
            kill(child, SIGTERM);
            stop_deadline = now + 2000;
        }
        if (child > 0 && stop_deadline && now >= stop_deadline) {
            kill(child, SIGKILL); /* Only our unreaped child; never a port owner. */
        }
        if (child < 0 && !reason && now >= retry_at) {
            /* Recheck the seat immediately before launch. The monitor handles
             * changes after this point; no inactive or unrelated user is chosen. */
            char *active = NULL;
            uid_t uid = 0;
            bool active_now = sd_seat_get_active("seat0", &active, &uid) >= 0 &&
                active && !strcmp(active, next.session) && uid == next.uid && sd_session_is_active(active) > 0;
            free(active);
            if (active_now && !stopping) {
                current = next;
                child = start_host(&current, port, fps, stats, clipboard);
                retry_at = now + 5000;
                if (child > 0) fprintf(stderr, "Started %s host as UID %lu on %s, port %s; clipboard %s.\n",
                    current.greeter ? "login-screen" : "desktop", (unsigned long)current.uid, current.display, port,
                    clipboard && !current.greeter ? "enabled" : "disabled");
            }
        }
        if (stopping && child < 0) break;
        int ready = poll(&watch, 1, stop_deadline ? 50 : 500);
        if (ready > 0) sd_login_monitor_flush(monitor);
        else if (ready < 0 && errno != EINTR) {
            perror("Monitoring login sessions");
            stopping = 1;
        }
    }
    sd_login_monitor_unref(monitor);
    return 0;
}
