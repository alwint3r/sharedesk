#define _POSIX_C_SOURCE 200809L

#include <X11/Xlib.h>
#include <X11/Xproto.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <rfb/rfb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

/* A single-threaded X11 host. LibVNCServer owns the client sockets; we own the
 * X connection and framebuffer. All callbacks run from rfbProcessEvents(). */
typedef struct {
    Display *display;
    Window root;
    rfbScreenInfoPtr screen;
    rfbClientPtr client;
    uint32_t *pixels;
    uint32_t *next_pixels;
    int width;
    int height;
    int resize_unavailable;
    int buttons;
    unsigned char keys[256];
} Host;

static volatile sig_atomic_t stopping = 0;

static void stop_on_signal(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

static void release_input(Host *host) {
    for (int key = 1; key < 256; ++key) {
        if (host->keys[key]) {
            XTestFakeKeyEvent(host->display, (KeyCode)key, False, CurrentTime);
            host->keys[key] = 0;
        }
    }
    for (int button = 1; button <= 3; ++button) {
        if (host->buttons & (1 << (button - 1))) {
            XTestFakeButtonEvent(host->display, (unsigned int)button, False, CurrentTime);
        }
    }
    host->buttons = 0;
    XFlush(host->display);
}

static void client_gone(rfbClientPtr client) {
    Host *host = client->screen->screenData;
    if (host->client == client) {
        release_input(host);
        host->client = NULL;
        fprintf(stderr, "Viewer disconnected\n");
    }
}

static enum rfbNewClientAction new_client(rfbClientPtr client) {
    Host *host = client->screen->screenData;
    if (host->resize_unavailable) {
        fprintf(stderr, "Rejecting viewer while desktop capture is unavailable\n");
        return RFB_CLIENT_REFUSE;
    }
    if (host->client != NULL) {
        fprintf(stderr, "Rejecting a second viewer\n");
        return RFB_CLIENT_REFUSE;
    }
    host->client = client;
    client->clientGoneHook = client_gone;
    fprintf(stderr, "Viewer connected; waiting for VNC authentication\n");
    return RFB_CLIENT_ACCEPT;
}

static void keyboard_event(rfbBool down, rfbKeySym symbol, rfbClientPtr client) {
    Host *host = client->screen->screenData;
    if (client != host->client) return;
    KeyCode code = XKeysymToKeycode(host->display, (KeySym)symbol);
    if (code == 0) return; /* No key in the current X11 keyboard layout. */
    if (host->keys[code] != (unsigned char)(down != 0)) {
        XTestFakeKeyEvent(host->display, code, down ? True : False, CurrentTime);
        host->keys[code] = (unsigned char)(down != 0);
        XFlush(host->display);
    }
}

static void pointer_event(int mask, int x, int y, rfbClientPtr client) {
    Host *host = client->screen->screenData;
    if (client != host->client) return;
    if (x < 0) x = 0;
    if (y < 0) y = 0;
    if (x >= host->width) x = host->width - 1;
    if (y >= host->height) y = host->height - 1;
    XTestFakeMotionEvent(host->display, -1, x, y, CurrentTime);

    /* RFB buttons 1, 2, 3 are held; bits 4-7 are wheel impulses. */
    for (int button = 1; button <= 3; ++button) {
        int bit = 1 << (button - 1);
        if ((mask ^ host->buttons) & bit) {
            XTestFakeButtonEvent(host->display, (unsigned int)button,
                                 (mask & bit) ? True : False, CurrentTime);
        }
    }
    for (int bit = 3; bit <= 6; ++bit) {
        if ((mask & (1 << bit)) && !(host->buttons & (1 << bit))) {
            XTestFakeButtonEvent(host->display, (unsigned int)(bit + 1), True, CurrentTime);
            XTestFakeButtonEvent(host->display, (unsigned int)(bit + 1), False, CurrentTime);
        }
    }
    host->buttons = mask & 0x7f;
    rfbDefaultPtrAddEvent(mask, x, y, client);
    XFlush(host->display);
}

static int read_password(const char *path, char password[9]) {
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) {
        perror("Opening password file");
        return -1;
    }
    struct stat st;
    if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) || st.st_uid != geteuid() ||
        (st.st_mode & 077) != 0) {
        fprintf(stderr, "Password file must be a regular file owned by this user, with no group/other access: %s\n", path);
        close(fd);
        return -1;
    }
    FILE *file = fdopen(fd, "rb");
    if (!file) {
        perror("Reading password file");
        close(fd);
        return -1;
    }
    char content[11];
    size_t length = fread(content, 1, sizeof content, file);
    int error = ferror(file);
    fclose(file);
    if (error) {
        fprintf(stderr, "Cannot read password file: %s\n", path);
        return -1;
    }
    if (length && content[length - 1] == '\n') --length;
    if (length < 1 || length > 8) {
        fprintf(stderr, "VNC password must contain 1-8 ASCII characters (optional final newline)\n");
        return -1;
    }
    for (size_t i = 0; i < length; ++i) {
        if ((unsigned char)content[i] < 33 || (unsigned char)content[i] > 126) {
            fprintf(stderr, "VNC password must contain printable ASCII without spaces\n");
            return -1;
        }
    }
    memcpy(password, content, length);
    password[length] = '\0';
    return 0;
}

static int parse_number(const char *text, int minimum, int maximum) {
    char *end;
    errno = 0;
    long value = strtol(text, &end, 10);
    if (errno || end == text || *end || value < minimum || value > maximum) return -1;
    return (int)value;
}

static uint32_t channel(unsigned long pixel, unsigned long mask) {
    if (!mask) return 0;
    unsigned int shift = 0;
    while (!(mask & 1)) {
        mask >>= 1;
        ++shift;
    }
    unsigned long value = (pixel >> shift) & mask;
    return (uint32_t)((value * 255UL) / mask);
}

static int pause_for_resize(Host *host, unsigned int width, unsigned int height,
                            const char *reason) {
    if (!host->resize_unavailable) {
        fprintf(stderr, "Cannot capture %ux%u desktop: %s\n", width, height, reason);
        host->resize_unavailable = 1;
        if (host->client) {
            release_input(host);
            rfbCloseClient(host->client);
        }
        if (host->screen) fprintf(stderr, "Waiting for a capturable desktop; host is still listening\n");
    }
    return host->screen ? 0 : -1;
}

static int image_error(Display *display, XErrorEvent *error) {
    /* The root can shrink between XGetGeometry and XGetImage. Do not let
     * Xlib's default error handler terminate the host for this race. */
    if (error->request_code == X_GetImage &&
        (error->error_code == BadMatch || error->error_code == BadValue)) return 0;
    char message[128];
    XGetErrorText(display, error->error_code, message, sizeof message);
    fprintf(stderr, "X11 capture error: %s (request %u)\n", message, error->request_code);
    stopping = 1;
    return 0;
}

static int capture(Host *host) {
    Window unused_root;
    int x, y;
    unsigned int width, height, border, depth;
    if (!XGetGeometry(host->display, host->root, &unused_root, &x, &y,
                      &width, &height, &border, &depth)) {
        fprintf(stderr, "Cannot query X11 desktop; session may have ended\n");
        return -1;
    }
    int resized = width != (unsigned int)host->width || height != (unsigned int)host->height;
    /* Check geometry even while idle so the next viewer gets the current size,
     * but avoid reading screen pixels without a viewer unless resizing. */
    if (!resized && !host->client && !host->resize_unavailable) return 0;

    uint32_t *pixels = host->pixels;
    uint32_t *next_pixels = host->next_pixels;
    if (resized) {
        if (width < 1 || height < 1 || width > 8192 || height > 8192 ||
            (size_t)width * height > INT_MAX / 4) {
            return pause_for_resize(host, width, height, "unsupported size (maximum 8192x8192)");
        }
        size_t bytes = (size_t)width * height * 4;
        pixels = malloc(bytes);
        next_pixels = malloc(bytes);
        if (!pixels || !next_pixels) {
            free(pixels);
            free(next_pixels);
            return pause_for_resize(host, width, height, "cannot allocate replacement framebuffers");
        }
    }

    /* XGetGeometry above has already completed pending X requests. Install the
     * error handler only around the synchronous image read, not input events. */
    XErrorHandler previous_handler = XSetErrorHandler(image_error);
    XImage *image = XGetImage(host->display, host->root, 0, 0, width, height,
                             AllPlanes, ZPixmap);
    XSetErrorHandler(previous_handler);
    if (!image) {
        if (resized) {
            free(pixels);
            free(next_pixels);
        }
        /* On a running host, retry with fresh geometry on the next capture. */
        if (host->screen && !stopping) return 0;
        fprintf(stderr, "XGetImage failed while opening the X11 desktop\n");
        return -1;
    }

    if (image->bits_per_pixel == 32 && image->byte_order == LSBFirst &&
        image->red_mask == 0x00ff0000 && image->green_mask == 0x0000ff00 &&
        image->blue_mask == 0x000000ff) {
        for (unsigned int row = 0; row < height; ++row) {
            memcpy(next_pixels + (size_t)row * width,
                   image->data + (size_t)row * image->bytes_per_line, width * 4);
        }
    } else {
        for (unsigned int row = 0; row < height; ++row) {
            for (unsigned int col = 0; col < width; ++col) {
                unsigned long pixel = XGetPixel(image, col, row);
                next_pixels[(size_t)row * width + col] =
                    (channel(pixel, image->red_mask) << 16) |
                    (channel(pixel, image->green_mask) << 8) |
                    channel(pixel, image->blue_mask);
            }
        }
    }
    XDestroyImage(image);

    if (host->resize_unavailable) {
        fprintf(stderr, "Desktop capture resumed\n");
        host->resize_unavailable = 0;
    }
    if (resized) {
        memcpy(pixels, next_pixels, (size_t)width * height * 4);
        if (host->screen) {
            if (host->client && host->client->state == RFB_NORMAL && !host->client->useNewFBSize) {
                fprintf(stderr, "Viewer does not support resizing; disconnecting it so it can reconnect\n");
                release_input(host);
                rfbCloseClient(host->client);
            }
            /* Publish only a fully captured frame. LibVNCServer resets its
             * pixel format here; restore ours and rebuild client translation. */
            rfbPixelFormat format = host->screen->serverFormat;
            rfbNewFramebuffer(host->screen, (char *)pixels, (int)width, (int)height, 8, 3, 4);
            host->screen->serverFormat = format;
            if (host->client) host->screen->setTranslateFunction(host->client);
            fprintf(stderr, "Desktop resized from %dx%d to %ux%u\n",
                    host->width, host->height, width, height);
        }
        free(host->pixels);
        free(host->next_pixels);
        host->pixels = pixels;
        host->next_pixels = next_pixels;
        host->width = (int)width;
        host->height = (int)height;
        return 0;
    }
    /* Compare tiles to avoid sending the entire screen for a small change. */
    for (int top = 0; top < host->height; top += 64) {
        int bottom = top + 64 < host->height ? top + 64 : host->height;
        for (int left = 0; left < host->width; left += 64) {
            int right = left + 64 < host->width ? left + 64 : host->width;
            size_t row_bytes = (size_t)(right - left) * 4;
            int changed = 0;
            for (int row = top; row < bottom; ++row) {
                size_t offset = (size_t)row * width + left;
                if (memcmp(host->pixels + offset, host->next_pixels + offset, row_bytes)) {
                    changed = 1;
                    break;
                }
            }
            if (changed) {
                for (int row = top; row < bottom; ++row) {
                    size_t offset = (size_t)row * width + left;
                    memcpy(host->pixels + offset, host->next_pixels + offset, row_bytes);
                }
                rfbMarkRectAsModified(host->screen, left, top, right, bottom);
            }
        }
    }
    return 0;
}

int main(int argc, char **argv) {
    const char *listen_ip = NULL;
    const char *password_file = NULL;
    int port = 5900, fps = 10;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--listen") && i + 1 < argc) listen_ip = argv[++i];
        else if (!strcmp(argv[i], "--password-file") && i + 1 < argc) password_file = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = parse_number(argv[++i], 1, 65535);
        else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = parse_number(argv[++i], 1, 30);
        else {
            fprintf(stderr, "Usage: %s --listen <Tailscale IPv4> --password-file <file> [--port 5900] [--fps 10]\n", argv[0]);
            return 2;
        }
    }
    struct in_addr address;
    if (!listen_ip || !password_file || port < 1 || fps < 1 ||
        inet_pton(AF_INET, listen_ip ? listen_ip : "", &address) != 1) {
        fprintf(stderr, "Provide a Tailscale IPv4 or loopback address, a password file, and valid port/fps\n");
        return 2;
    }
    uint32_t ip = ntohl(address.s_addr);
    if ((ip & 0xffc00000U) != 0x64400000U && /* Tailscale: 100.64.0.0/10 */
        (ip & 0xff000000U) != 0x7f000000U) { /* Loopback: 127.0.0.0/8 */
        fprintf(stderr, "Only Tailscale (100.64.0.0/10) or loopback IPv4 addresses are allowed\n");
        return 2;
    }
    char password[9];
    if (read_password(password_file, password) != 0) return 1;
    char *passwords[] = {password, NULL};

    Host host = {0};
    host.display = XOpenDisplay(NULL);
    if (!host.display) {
        fprintf(stderr, "Cannot open X11 display; run inside the logged-in Ubuntu X11 session (DISPLAY/XAUTHORITY)\n");
        return 1;
    }
    int event_base, error_base, major, minor;
    if (!XTestQueryExtension(host.display, &event_base, &error_base, &major, &minor)) {
        fprintf(stderr, "X11 XTEST input extension is unavailable\n");
        XCloseDisplay(host.display);
        return 1;
    }
    host.root = DefaultRootWindow(host.display);
    if (capture(&host) != 0) {
        free(host.pixels);
        free(host.next_pixels);
        XCloseDisplay(host.display);
        return 1;
    }

    int vnc_argc = 1;
    char *vnc_argv[] = {argv[0], NULL};
    host.screen = rfbGetScreen(&vnc_argc, vnc_argv, host.width, host.height, 8, 3, 4);
    if (!host.screen) {
        fprintf(stderr, "Cannot initialize VNC screen\n");
        free(host.pixels);
        free(host.next_pixels);
        XCloseDisplay(host.display);
        return 1;
    }
    host.screen->screenData = &host;
    host.screen->frameBuffer = (char *)host.pixels;
    host.screen->desktopName = "Sharedesk Ubuntu X11";
    host.screen->serverFormat.trueColour = TRUE;
    host.screen->serverFormat.redMax = 255;
    host.screen->serverFormat.greenMax = 255;
    host.screen->serverFormat.blueMax = 255;
    host.screen->serverFormat.redShift = 16;
    host.screen->serverFormat.greenShift = 8;
    host.screen->serverFormat.blueShift = 0;
    const uint16_t endian_check = 1;
    host.screen->serverFormat.bigEndian = *(const unsigned char *)&endian_check == 0;
    host.screen->autoPort = FALSE;
    host.screen->port = port;
    host.screen->listenInterface = address.s_addr;
    host.screen->ipv6port = 0;
    host.screen->httpPort = 0;
    host.screen->http6Port = 0;
    host.screen->udpPort = 0;
    host.screen->permitFileTransfer = FALSE;
    host.screen->passwordCheck = rfbCheckPasswordByList;
    host.screen->authPasswdData = passwords;
    host.screen->neverShared = TRUE;
    host.screen->dontDisconnect = TRUE;
    host.screen->newClientHook = new_client;
    host.screen->kbdAddEvent = keyboard_event;
    host.screen->ptrAddEvent = pointer_event;

    struct sigaction action = {0};
    action.sa_handler = stop_on_signal;
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    rfbInitServer(host.screen);
    if (!rfbIsActive(host.screen)) {
        fprintf(stderr, "VNC server could not start; check the listen IP and port\n");
        rfbScreenCleanup(host.screen);
        free(host.pixels);
        free(host.next_pixels);
        XCloseDisplay(host.display);
        return 1;
    }
    fprintf(stderr, "Serving %dx%d X11 desktop on %s:%d at up to %d fps (Ctrl+C to stop)\n",
            host.width, host.height, listen_ip, port, fps);
    int result = 0;
    int64_t interval_ns = 1000000000LL / fps;
    struct timespec now;
    clock_gettime(CLOCK_MONOTONIC, &now);
    int64_t next_capture = (int64_t)now.tv_sec * 1000000000LL + now.tv_nsec + interval_ns;
    while (!stopping && rfbIsActive(host.screen)) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        int64_t current = (int64_t)now.tv_sec * 1000000000LL + now.tv_nsec;
        if (current >= next_capture) {
            if (capture(&host) != 0) {
                result = 1;
                break;
            }
            next_capture = current + interval_ns;
        }
        int64_t wait_us = (next_capture - current) / 1000;
        if (wait_us > 50000) wait_us = 50000;
        if (wait_us < 1000) wait_us = 1000;
        rfbProcessEvents(host.screen, (long)wait_us);
    }
    if (host.client) release_input(&host);
    rfbShutdownServer(host.screen, TRUE);
    rfbScreenCleanup(host.screen);
    free(host.pixels);
    free(host.next_pixels);
    XCloseDisplay(host.display);
    memset(password, 0, sizeof password);
    return result;
}
