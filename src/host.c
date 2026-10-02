#define _POSIX_C_SOURCE 200809L

#include <X11/Xlib.h>
#include <X11/Xatom.h>
#include <X11/XKBlib.h>
#include <X11/keysym.h>
#include <X11/Xproto.h>
#include <X11/Xutil.h>
#include <X11/extensions/XTest.h>
#include <X11/extensions/Xfixes.h>
#include <X11/extensions/Xdamage.h>
#include <X11/extensions/XShm.h>
#include <X11/extensions/shmproto.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <limits.h>
#include <rfb/rfb.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/shm.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

typedef struct {
    int enabled;
    int64_t started_ns;
    int64_t cpu_started_us;
    uint64_t captures;
    uint64_t cursor_frames;
    uint64_t capture_ns;
    uint64_t capture_max_ns;
    uint64_t grab_ns;
    uint64_t grab_max_ns;
    uint64_t sent_bytes;
    uint32_t last_sent_bytes;
} Stats;

#define CLIPBOARD_LIMIT (1U << 20) /* Standard LibVNCServer cut-text limit. */
#define CLIPBOARD_X_LIMIT (2U * CLIPBOARD_LIMIT) /* Latin-1 expanded to UTF-8. */

typedef struct {
    int enabled;
    int active; /* Export selection changes only during an authenticated connection. */
    Window window; /* Owns imported text; persists across viewer disconnects. */
    Atom selection, utf8, targets, timestamp, incr, property;
    Time owned_at;
    unsigned long owned_after; /* Ignore notifications queued before a newer import. */
    char *text; /* Owned Latin-1 selection contents, freed on ownership loss. */
    size_t text_length;
    char *wire_text; /* Per-connection echo suppression, not a clipboard log. */
    size_t wire_length;
    Window reader; /* A fresh requestor isolates each asynchronous transfer. */
    Time requested_at;
    Atom requested_target, received_type;
    int incremental;
    unsigned char *received;
    size_t received_length;
    int64_t deadline_ns;
    size_t max_property_bytes;
} Clipboard;

/* A single-threaded X11 host. LibVNCServer owns the client sockets; we own the
 * X connection, framebuffer and per-report statistics. All callbacks run from
 * rfbProcessEvents(); statistics stay in the same foreground event loop. */
typedef struct {
    Display *display;
    Window root;
    rfbScreenInfoPtr screen;
    rfbClientPtr client;
    uint32_t *pixels;      /* Viewer output, borrowed by LibVNCServer. */
    uint32_t *next_pixels; /* Working framebuffer, including a painted cursor. */
    uint32_t *raw_pixels;  /* Last successful clean RGB capture, owned by host. */
    Damage damage;
    int damage_opcode;
    int damage_event_base;
    int damage_error;
    int screen_dirty;
    int64_t last_pixel_capture_ns;
    int cursor_repaint;
    int cursor_composited;
    /* Persistent raw capture storage, never borrowed by LibVNCServer. The
     * image metadata and SysV mapping belong to this host; Xorg writes only
     * during the synchronous XShmGetImage call. */
    XImage *shm_image;
    XShmSegmentInfo shm_segment;
    int shm_enabled;
    int shm_opcode;
    int shm_attached;
    int shm_marked;
    int shm_error;
    int width;
    int height;
    int resize_unavailable;
    int cursor_event_base;
    int cursor_dirty;
    int cursor_read_failed;
    int buttons;
    /* Logical viewer presses: 1 = held in X11, 2 = corrected tap/repeat.
     * Corrected keys are physically up between taps, so Xorg cannot repeat
     * them with the restored modifier state. */
    unsigned char keys[256];
    KeySym key_symbols[256];
    KeySym key_aliases[256]; /* Unshifted symbol captured at key-down. */
    int64_t key_repeat_at[256];
    XkbDescPtr keymap; /* Host-owned snapshot; never changes the server map. */
    XkbStateRec keyboard_state;
    unsigned long keyboard_state_after;
    unsigned int layout_mods;
    int keyboard_event_base;
    int keyboard_state_valid;
    int keymap_dirty;
    int keyboard_read_failed;
    Stats stats;
    Clipboard clipboard;
} Host;

static volatile sig_atomic_t stopping = 0;
/* Xlib error handlers have no context argument. This borrowed pointer exists
 * only while trapping our own capture requests in the single-threaded loop. */
static Host *capture_error_host;

static void stop_on_signal(int signal_number) {
    (void)signal_number;
    stopping = 1;
}

static int64_t monotonic_ns(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        perror("Reading monotonic clock");
        exit(EXIT_FAILURE); /* The event loop also needs this clock to run. */
    }
    return (int64_t)now.tv_sec * 1000000000LL + now.tv_nsec;
}

/* Returns process CPU time in microseconds, or -1 when it is unavailable. */
static int64_t process_cpu_us(void) {
    struct rusage usage;
    if (getrusage(RUSAGE_SELF, &usage) != 0) return -1;
    return (int64_t)usage.ru_utime.tv_sec * 1000000 + usage.ru_utime.tv_usec +
           (int64_t)usage.ru_stime.tv_sec * 1000000 + usage.ru_stime.tv_usec;
}

static void record_capture(Host *host, int64_t started_ns, uint64_t grab_ns, int read_pixels) {
    Stats *stats = &host->stats;
    if (!stats->enabled) return;
    if (!read_pixels) {
        ++stats->cursor_frames;
        return;
    }
    uint64_t elapsed = (uint64_t)(monotonic_ns() - started_ns);
    ++stats->captures;
    stats->capture_ns += elapsed;
    if (elapsed > stats->capture_max_ns) stats->capture_max_ns = elapsed;
    stats->grab_ns += grab_ns;
    if (grab_ns > stats->grab_max_ns) stats->grab_max_ns = grab_ns;
}

static void sample_client_bytes(Host *host, rfbClientPtr client) {
    Stats *stats = &host->stats;
    if (!stats->enabled || client != host->client) return;
    /* LibVNCServer's counter is 32-bit. Sample after every framebuffer update
     * (each is smaller than 4 GiB) so unsigned subtraction handles a wrap.
     * Keep our interval total in 64 bits and never reset the library's counters. */
    uint32_t total = (uint32_t)rfbStatGetSentBytes(client);
    stats->sent_bytes += (uint32_t)(total - stats->last_sent_bytes);
    stats->last_sent_bytes = total;
}

static void display_finished(rfbClientPtr client, int success) {
    (void)success;
    /* These are library-accounted bytes, not a socket-write acknowledgement. */
    sample_client_bytes(client->screen->screenData, client);
}

static void process_x_events(Host *host);

/* Foreign selection requestors can disappear while we reply. Trap only their
 * BadWindow errors; other X11 errors retain the normal handler. */
static Window clipboard_reply_window;
static XErrorHandler clipboard_previous_error;

static int clipboard_error(Display *display, XErrorEvent *error) {
    if (error->error_code == BadWindow && error->resourceid == clipboard_reply_window) return 0;
    return clipboard_previous_error(display, error);
}

static void cancel_clipboard_read(Host *host) {
    Clipboard *clip = &host->clipboard;
    if (clip->reader) XDestroyWindow(host->display, clip->reader);
    clip->reader = None;
    free(clip->received);
    clip->received = NULL;
    clip->received_length = 0;
    clip->incremental = 0;
    clip->deadline_ns = 0;
}

static void reset_clipboard_connection(Host *host) {
    cancel_clipboard_read(host);
    host->clipboard.active = 0;
    free(host->clipboard.wire_text);
    host->clipboard.wire_text = NULL;
    host->clipboard.wire_length = 0;
}

static void clipboard_from_viewer(char *text, int length, rfbClientPtr client) {
    Host *host = client->screen->screenData;
    Clipboard *clip = &host->clipboard;
    if (!clip->enabled || client != host->client || client->state != RFB_NORMAL ||
        client->sock == RFB_INVALID_SOCKET || length < 0 || (unsigned int)length > CLIPBOARD_LIMIT ||
        (length && memchr(text, '\0', (size_t)length))) return;
    if (!clip->active) {
        process_x_events(host); /* Discard selection changes from before authentication. */
        clip->active = 1;
    }
    char *owned = malloc((size_t)length + 1), *wire = malloc((size_t)length + 1);
    if (!owned || !wire) {
        free(owned);
        free(wire);
        fprintf(stderr, "Clipboard import unavailable: allocation failed\n");
        return;
    }
    memcpy(owned, text, (size_t)length);
    memcpy(wire, text, (size_t)length);
    owned[length] = wire[length] = '\0';
    cancel_clipboard_read(host);
    free(clip->text);
    free(clip->wire_text);
    clip->text = owned;
    clip->text_length = (size_t)length;
    clip->wire_text = wire;
    clip->wire_length = (size_t)length;
    clip->owned_at = CurrentTime;
    clip->owned_after = NextRequest(host->display);
    XSetSelectionOwner(host->display, clip->selection, clip->window, CurrentTime);
    XFlush(host->display);
}

static void clipboard_event(Host *host, XEvent *event) {
    Clipboard *clip = &host->clipboard;
    if (!clip->enabled) return;
    if (event->type == host->cursor_event_base + XFixesSelectionNotify &&
        ((XFixesSelectionNotifyEvent *)event)->selection == clip->selection) {
        XFixesSelectionNotifyEvent *selection = (XFixesSelectionNotifyEvent *)event;
        if (selection->serial < clip->owned_after) return;
        if (selection->owner == clip->window) {
            clip->owned_at = selection->selection_timestamp;
            return;
        }
        free(clip->text);
        clip->text = NULL;
        clip->text_length = 0;
        cancel_clipboard_read(host);
        if (!clip->active || !host->client || host->client->state != RFB_NORMAL ||
            host->client->sock == RFB_INVALID_SOCKET || selection->owner == None) return;
        clip->reader = XCreateSimpleWindow(host->display, host->root, 0, 0, 1, 1, 0, 0, 0);
        XSelectInput(host->display, clip->reader, PropertyChangeMask);
        clip->requested_at = selection->selection_timestamp;
        clip->requested_target = clip->utf8;
        clip->received_type = None;
        clip->deadline_ns = monotonic_ns() + 2000000000LL;
        XConvertSelection(host->display, clip->selection, clip->utf8, clip->property,
                          clip->reader, clip->requested_at);
        XFlush(host->display);
        return;
    }
    if (event->type == SelectionClear && event->xselectionclear.window == clip->window) {
        /* A delayed clear may precede a newer import that already reclaimed it. */
        if (XGetSelectionOwner(host->display, clip->selection) != clip->window) {
            free(clip->text);
            clip->text = NULL;
            clip->text_length = 0;
        }
        return;
    }
    if (event->type == SelectionRequest && event->xselectionrequest.owner == clip->window) {
        XSelectionRequestEvent *request = &event->xselectionrequest;
        XEvent reply = {0};
        reply.xselection = (XSelectionEvent){.type = SelectionNotify, .display = host->display,
            .requestor = request->requestor, .selection = request->selection,
            .target = request->target, .time = request->time, .property = None};
        Atom property = request->property ? request->property : request->target;
        unsigned char *converted = NULL;
        const unsigned char *data = (const unsigned char *)clip->text;
        size_t length = clip->text_length;
        Atom type = XA_STRING;
        int format = 8;
        Atom offered[] = {clip->targets, clip->timestamp, clip->utf8, XA_STRING};
        unsigned long timestamp = clip->owned_at;
        int valid = clip->text && request->selection == clip->selection &&
            (request->time == CurrentTime || clip->owned_at == CurrentTime ||
             (int32_t)(request->time - clip->owned_at) >= 0);
        if (request->target == clip->targets) {
            data = (const unsigned char *)offered;
            length = sizeof offered / sizeof offered[0];
            type = XA_ATOM;
            format = 32;
        } else if (request->target == clip->timestamp) {
            data = (const unsigned char *)&timestamp;
            length = 1;
            type = XA_INTEGER;
            format = 32;
        } else if (request->target == clip->utf8 && valid) {
            converted = malloc(length * 2 + 1);
            if (!converted) valid = 0;
            else {
                size_t count = 0;
                for (size_t i = 0; i < length; ++i) {
                    unsigned char c = data[i];
                    if (c >= 128) converted[count++] = (unsigned char)(0xc0 | (c >> 6));
                    converted[count++] = c < 128 ? c : (unsigned char)(0x80 | (c & 63));
                }
                data = converted;
                length = count;
                type = clip->utf8;
            }
        } else if (request->target != XA_STRING) valid = 0;
        if (length > clip->max_property_bytes / (size_t)(format / 8)) valid = 0;
        XSync(host->display, False);
        clipboard_reply_window = request->requestor;
        clipboard_previous_error = XSetErrorHandler(clipboard_error);
        if (valid) {
            XChangeProperty(host->display, request->requestor, property, type, format,
                            PropModeReplace, data, (int)length);
            reply.xselection.property = property;
        }
        XSendEvent(host->display, request->requestor, False, 0, &reply);
        XSync(host->display, False);
        XSetErrorHandler(clipboard_previous_error);
        clipboard_reply_window = None;
        free(converted);
        return;
    }
    int initial = event->type == SelectionNotify && clip->reader &&
        event->xselection.requestor == clip->reader && event->xselection.selection == clip->selection &&
        event->xselection.target == clip->requested_target && event->xselection.time == clip->requested_at;
    int chunk = event->type == PropertyNotify && clip->reader && clip->incremental &&
        event->xproperty.window == clip->reader && event->xproperty.atom == clip->property &&
        event->xproperty.state == PropertyNewValue;
    if (!initial && !chunk) return;
    if (monotonic_ns() >= clip->deadline_ns) {
        fprintf(stderr, "Clipboard export timed out; desktop sharing remains available\n");
        cancel_clipboard_read(host);
        return;
    }
    if (initial && event->xselection.property == None) {
        if (clip->requested_target == clip->utf8) {
            clip->requested_target = XA_STRING;
            XConvertSelection(host->display, clip->selection, XA_STRING, clip->property,
                              clip->reader, clip->requested_at);
            XFlush(host->display);
        } else cancel_clipboard_read(host);
        return;
    }
    if (initial && event->xselection.property != clip->property) {
        cancel_clipboard_read(host);
        return;
    }
    Atom type;
    int format;
    unsigned long length, remaining;
    unsigned char *value = NULL;
    int status = XGetWindowProperty(host->display, clip->reader, clip->property, 0,
        CLIPBOARD_X_LIMIT / 4 + 1, True, AnyPropertyType, &type, &format, &length, &remaining, &value);
    if (status != Success || remaining || type == None) {
        if (value) XFree(value);
        cancel_clipboard_read(host);
        return;
    }
    if (initial && type == clip->incr) {
        /* Some owners (including xclip) omit the advisory size. The actual
         * chunks remain bounded by our byte limit and total timeout. */
        int valid = format == 32 && (length == 0 ||
            (length == 1 && *(unsigned long *)value <= CLIPBOARD_X_LIMIT));
        XFree(value);
        if (valid) clip->incremental = 1;
        else cancel_clipboard_read(host);
        XFlush(host->display); /* Deleting the INCR marker acknowledges readiness. */
        return;
    }
    int valid = format == 8 && (type == clip->utf8 || type == XA_STRING) &&
        (clip->received_type == None || type == clip->received_type) &&
        length <= CLIPBOARD_X_LIMIT - clip->received_length;
    if (!valid) {
        XFree(value);
        cancel_clipboard_read(host);
        fprintf(stderr, "Clipboard export ignored: invalid or oversized text\n");
        return;
    }
    clip->received_type = type;
    if (length) {
        unsigned char *received = realloc(clip->received, clip->received_length + length + 1);
        if (!received) {
            XFree(value);
            cancel_clipboard_read(host);
            return;
        }
        clip->received = received;
        memcpy(received + clip->received_length, value, length);
        clip->received_length += length;
    }
    XFree(value);
    XFlush(host->display);
    if (clip->incremental && length) return;
    /* Standard RFB cut text is Latin-1, not UTF-8. Refuse unrepresentable text
     * rather than corrupting Unicode or silently replacing characters. */
    size_t count = 0;
    for (size_t i = 0; i < clip->received_length; ++i) {
        unsigned char c = clip->received[i];
        if (!c) { valid = 0; break; }
        if (type == clip->utf8 && c >= 128) {
            if ((c != 0xc2 && c != 0xc3) || i + 1 >= clip->received_length ||
                (clip->received[i + 1] & 0xc0) != 0x80) { valid = 0; break; }
            c = (unsigned char)(((c & 3) << 6) | (clip->received[++i] & 63));
        }
        clip->received[count++] = c;
    }
    if (count > CLIPBOARD_LIMIT) valid = 0;
    if (valid && clip->active && host->client && host->client->state == RFB_NORMAL &&
        host->client->sock != RFB_INVALID_SOCKET &&
        (!clip->wire_text || clip->wire_length != count ||
         (count && memcmp(clip->wire_text, clip->received, count)))) {
        char *wire = malloc(count + 1);
        if (wire) {
            if (count) memcpy(wire, clip->received, count);
            wire[count] = '\0';
            free(clip->wire_text);
            clip->wire_text = wire;
            clip->wire_length = count;
            /* Clipboard writes are synchronous in LibVNCServer. Bound a slow
             * viewer's wait; the existing capture/input loop owns all work. */
            int previous_wait = host->screen->maxClientWait;
            host->screen->maxClientWait = 1000;
            rfbSendServerCutText(host->screen, wire, (int)count);
            host->screen->maxClientWait = previous_wait;
        }
    } else if (!valid) fprintf(stderr, "Clipboard export ignored: text is not Latin-1 or exceeds 1 MiB\n");
    cancel_clipboard_read(host);
}

static int refresh_keyboard(Host *host) {
    XkbDescPtr map = XkbGetMap(host->display, XkbAllMapComponentsMask, XkbUseCoreKbd);
    XkbStateRec state;
    if (!map || XkbGetControls(host->display, XkbAllControlsMask, map) != Success ||
        XkbGetState(host->display, XkbUseCoreKbd, &state) != Success) {
        if (map) XkbFreeKeyboard(map, XkbAllComponentsMask, True);
        if (!host->keyboard_read_failed) fprintf(stderr, "Cannot read XKB keyboard map\n");
        host->keyboard_read_failed = 1;
        return -1;
    }
    unsigned int layout = ShiftMask, shortcuts = ControlMask | LockMask;
    for (int code = map->min_key_code; code <= map->max_key_code; ++code) {
        unsigned int mods = map->map->modmap[code];
        for (int i = 0; mods && i < XkbKeyNumSyms(map, code); ++i) {
            KeySym symbol = XkbKeySymsPtr(map, code)[i];
            if (symbol == XK_ISO_Level3_Shift) layout |= mods;
            if (symbol == XK_Control_L || symbol == XK_Control_R ||
                symbol == XK_Alt_L || symbol == XK_Alt_R ||
                symbol == XK_Meta_L || symbol == XK_Meta_R ||
                symbol == XK_Super_L || symbol == XK_Super_R ||
                symbol == XK_Hyper_L || symbol == XK_Hyper_R) shortcuts |= mods;
        }
    }
    if (host->keymap) XkbFreeKeyboard(host->keymap, XkbAllComponentsMask, True);
    host->keymap = map;
    host->layout_mods = layout & ~shortcuts;
    host->keyboard_state = state;
    host->keyboard_state_after = LastKnownRequestProcessed(host->display);
    host->keyboard_state_valid = 1;
    host->keymap_dirty = 0;
    host->keyboard_read_failed = 0;
    return 0;
}

static int inject_key(Host *host, KeyCode code, Bool down) {
    if (host->keymap && (code < host->keymap->min_key_code || code > host->keymap->max_key_code)) return -1;
    unsigned long serial = NextRequest(host->display);
    if (!XTestFakeKeyEvent(host->display, code, down, CurrentTime)) return -1;
    /* Notifications from before this request cannot describe its result. */
    if (host->keymap && XkbKeyHasActions(host->keymap, code)) {
        for (int i = 0; i < XkbKeyNumActions(host->keymap, code); ++i) {
            if (XkbKeyActionsPtr(host->keymap, code)[i].any.type != XkbSA_NoAction) {
                host->keyboard_state_valid = 0;
                host->keyboard_state_after = serial;
                break;
            }
        }
    }
    return 0;
}

static void release_input(Host *host) {
    for (int key = 1; key < 256; ++key) {
        if (host->keys[key]) {
            if (host->keys[key] == 1) inject_key(host, (KeyCode)key, False);
            host->keys[key] = 0;
            host->key_symbols[key] = NoSymbol;
            host->key_aliases[key] = NoSymbol;
            host->key_repeat_at[key] = 0;
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
        /* The library frees the client's statistics after this callback. */
        sample_client_bytes(host, client);
        release_input(host);
        reset_clipboard_connection(host);
        if (host->cursor_composited) {
            memcpy(host->pixels, host->raw_pixels, (size_t)host->width * host->height * 4);
            host->cursor_composited = 0;
            host->cursor_repaint = 1;
        }
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
    host->screen_dirty = 1; /* Refresh a snapshot that may have aged while idle. */
    host->cursor_repaint = 1;
    if (host->stats.enabled) host->stats.last_sent_bytes = 0;
    client->clientGoneHook = client_gone;
    fprintf(stderr, "Viewer connected; waiting for VNC authentication\n");
    return RFB_CLIENT_ACCEPT;
}

/* New presses and corrected-key repeats share translation and injection.
 * A nonzero code pins a repeat to its original binding. */
static int press_key(Host *host, KeySym symbol, KeyCode repeat_code) {
    process_x_events(host);
    if (host->keymap_dirty && refresh_keyboard(host) != 0) return -1;
    if (!host->keyboard_state_valid) {
        if (XkbGetState(host->display, XkbUseCoreKbd, &host->keyboard_state) != Success) return -1;
        host->keyboard_state_after = LastKnownRequestProcessed(host->display);
        host->keyboard_state_valid = 1;
    }
    KeyCode code = 0;
    unsigned int wanted = 0, current = 0;
    for (int attempt = 0; attempt < 2; ++attempt) {
        current = host->keyboard_state.mods;
        unsigned int editable = host->layout_mods &
            ~(host->keyboard_state.locked_mods | host->keyboard_state.latched_mods);
        int best = INT_MAX;
        code = 0;
        for (int key = host->keymap->min_key_code; key <= host->keymap->max_key_code; ++key) {
            if (repeat_code ? key != repeat_code : host->keys[key] != 0) continue;
            /* Function/navigation/modifier keys are physical shortcut keys,
             * not text. Preserve their modifiers even when XKB gives the
             * combination another name (e.g. Ctrl+Alt+F1). */
            if ((IsModifierKey(symbol) || (symbol >= 0xff00 && symbol <= 0xffff)) &&
                !IsKeypadKey(symbol)) {
                for (int i = 0; i < XkbKeyNumSyms(host->keymap, key); ++i) {
                    if (XkbKeySymsPtr(host->keymap, key)[i] == symbol) {
                        code = (KeyCode)key;
                        wanted = current;
                        best = 0;
                        break;
                    }
                }
                if (best == 0) break;
                continue;
            }
            for (unsigned int variation = 0; variation <= editable; ++variation) {
                if (variation & ~editable) continue;
                unsigned int mods = (current & ~editable) | variation;
                int score = 0;
                for (unsigned int bits = mods ^ current; bits; bits >>= 1) score += bits & 1;
                if (score >= best) continue;
                KeySym produced;
                unsigned int consumed;
                if (XkbTranslateKeyCode(host->keymap, (KeyCode)key,
                    XkbBuildCoreState(mods, host->keyboard_state.group), &consumed, &produced) &&
                    produced == symbol) {
                    code = (KeyCode)key;
                    wanted = mods;
                    best = score;
                }
            }
            if (best == 0) break;
        }
        if (!code) return -1; /* Never inject a different symbol or rewrite the keymap. */
        if (wanted == current || attempt == 1) break;
        /* Synchronize before temporary changes. Matching ordinary keys use
         * the cached map/state without a round trip. */
        if (XkbGetState(host->display, XkbUseCoreKbd, &host->keyboard_state) != Success) return -1;
        host->keyboard_state_after = LastKnownRequestProcessed(host->display);
        host->keyboard_state_valid = 1;
    }
    XkbControlsPtr controls = host->keymap->ctrls;
    int can_repeat = (controls->enabled_ctrls & XkbRepeatKeysMask) &&
                    ((controls->per_key_repeat[code / 8] >> (code % 8)) & 1);
    if (repeat_code && !can_repeat) {
        host->key_repeat_at[code] = 0;
        return 0;
    }
    signed char changes[256] = {0};
    if (wanted != current || repeat_code) {
        char physical[32];
        XQueryKeymap(host->display, physical);
        if (((unsigned char)physical[code / 8] >> (code % 8)) & 1) return -1;
        unsigned int off = current & ~wanted, on = wanted & ~current, covered = 0;
        for (int key = host->keymap->min_key_code; key <= host->keymap->max_key_code; ++key) {
            unsigned int mods = host->keymap->map->modmap[key];
            if ((mods & off) && (((unsigned char)physical[key / 8] >> (key % 8)) & 1)) {
                if (mods & ~host->layout_mods) return -1;
                changes[key] = -1;
                covered |= mods;
            }
        }
        if (off & ~covered) return -1;
        for (int key = host->keymap->min_key_code; key <= host->keymap->max_key_code; ++key) {
            unsigned int mods = host->keymap->map->modmap[key];
            if (mods && !(mods & ~on) && (mods & on)) {
                changes[key] = 1;
                on &= ~mods;
            }
        }
        if (on) return -1;
    }
    int tapped = repeat_code || wanted != current;
    int ready = 1;
    for (int key = 1; key < 256; ++key) {
        if (changes[key] < 0 && inject_key(host, (KeyCode)key, False) != 0) ready = 0;
    }
    for (int key = 1; key < 256; ++key) {
        if (changes[key] > 0 && inject_key(host, (KeyCode)key, True) != 0) ready = 0;
    }
    int sent = ready && inject_key(host, code, True) == 0;
    int held = sent;
    if (sent && tapped) {
        if (inject_key(host, code, False) == 0 || inject_key(host, code, False) == 0) held = 0;
    }
    /* Always undo attempted modifier changes, including on injection failure. */
    for (int key = 255; key > 0; --key) if (changes[key] > 0) inject_key(host, (KeyCode)key, False);
    for (int key = 255; key > 0; --key) if (changes[key] < 0) inject_key(host, (KeyCode)key, True);
    if (!sent) {
        XFlush(host->display);
        return -1;
    }
    if (!repeat_code) {
        host->keys[code] = held ? 1 : 2;
        host->key_symbols[code] = symbol;
        KeySym alias;
        unsigned int consumed;
        unsigned int base = current & ~(host->layout_mods | LockMask);
        host->key_aliases[code] = XkbTranslateKeyCode(host->keymap, code,
            XkbBuildCoreState(base, host->keyboard_state.group), &consumed, &alias) ? alias : NoSymbol;
    }
    if (repeat_code && held) host->keys[code] = 1; /* Release hook owns a failed tap-up. */
    if (tapped && !held && can_repeat) {
        unsigned int delay = repeat_code ? controls->repeat_interval : controls->repeat_delay;
        host->key_repeat_at[code] = monotonic_ns() + (int64_t)(delay ? delay : 1) * 1000000;
    } else {
        host->key_repeat_at[code] = 0;
    }
    XFlush(host->display);
    return 0;
}

static void keyboard_event(rfbBool down, rfbKeySym symbol, rfbClientPtr client) {
    Host *host = client->screen->screenData;
    if (client != host->client) return;
    /* Keysyms carry case/number intent. Viewer locks must not toggle the
     * existing desktop's Caps/Num/Scroll Lock settings. */
    if (symbol == XK_Caps_Lock || symbol == XK_Shift_Lock ||
        symbol == XK_Num_Lock || symbol == XK_Scroll_Lock) return;
    KeyCode code = 0;
    for (int key = 1; key < 256; ++key) {
        if (host->keys[key] && host->key_symbols[key] == (KeySym)symbol) {
            code = (KeyCode)key;
            break;
        }
    }
    if (down) {
        /* Native repeat or our corrected-tap timer owns repeats, never both. */
        if (!code) (void)press_key(host, (KeySym)symbol, 0);
        return;
    }
    if (!code) {
        for (int key = 1; key < 256; ++key) {
            if (!host->keys[key]) continue;
            KeySym lower, upper;
            XConvertCase(host->key_symbols[key], &lower, &upper);
            if (host->key_aliases[key] == (KeySym)symbol ||
                lower == (KeySym)symbol || upper == (KeySym)symbol) {
                if (code) return; /* Do not guess between unrelated held keys. */
                code = (KeyCode)key;
            }
        }
    }
    if (!code) return;
    if (host->keys[code] == 1) inject_key(host, code, False);
    host->keys[code] = 0;
    host->key_symbols[code] = NoSymbol;
    host->key_aliases[code] = NoSymbol;
    host->key_repeat_at[code] = 0;
    XFlush(host->display);
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
    if (x != host->screen->cursorX || y != host->screen->cursorY) host->cursor_repaint = 1;
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

static int cursor_in_framebuffer(rfbClientPtr client) {
    rfbCursorPtr cursor = client->screen->cursor;
    if (!cursor) return 0;
    size_t bytes = (size_t)cursor->width * cursor->height * 4 +
                   (size_t)((cursor->width + 7) / 8) * cursor->height +
                   sz_rfbFramebufferUpdateRectHeader + sz_rfbXCursorColors;
    /* LibVNCServer cannot send a cursor larger than its update buffer. */
    return !client->enableCursorPosUpdates || bytes > UPDATE_BUF_SIZE;
}

static rfbCursorPtr viewer_cursor(rfbClientPtr client) {
    /* Hide the viewer's cursor when its image is already in the screen stream. */
    return cursor_in_framebuffer(client) ? NULL : client->screen->cursor;
}

static void process_x_events(Host *host) {
    while (XPending(host->display)) {
        XEvent event;
        XNextEvent(host->display, &event);
        if (event.type == host->cursor_event_base + XFixesCursorNotify) {
            host->cursor_dirty = 1;
        } else if (host->damage && event.type == host->damage_event_base + XDamageNotify &&
                   ((XDamageNotifyEvent *)&event)->damage == host->damage) {
            host->screen_dirty = 1;
        } else if (event.type == host->keyboard_event_base + XkbEventCode) {
            XkbEvent *keyboard = (XkbEvent *)&event;
            if (keyboard->any.xkb_type == XkbStateNotify &&
                keyboard->any.serial >= host->keyboard_state_after) {
                host->keyboard_state.mods = (unsigned char)keyboard->state.mods;
                host->keyboard_state.group = (unsigned char)keyboard->state.group;
                host->keyboard_state.locked_mods = (unsigned char)keyboard->state.locked_mods;
                host->keyboard_state.latched_mods = (unsigned char)keyboard->state.latched_mods;
                host->keyboard_state_valid = 1;
            } else if (keyboard->any.xkb_type == XkbMapNotify ||
                       keyboard->any.xkb_type == XkbNewKeyboardNotify ||
                       keyboard->any.xkb_type == XkbControlsNotify) {
                host->keymap_dirty = 1;
            }
        } else if (event.type == MappingNotify) {
            XRefreshKeyboardMapping(&event.xmapping);
            if (event.xmapping.request != MappingPointer) host->keymap_dirty = 1;
        } else {
            clipboard_event(host, &event);
        }
    }
}

static int update_cursor(Host *host) {
    process_x_events(host);
    int result = 0;
    if (host->cursor_dirty) {
        host->cursor_dirty = 0;
        XFixesCursorImage *image = XFixesGetCursorImage(host->display);
        if (!image) {
            if (!host->cursor_read_failed) {
                fprintf(stderr, "Cannot read X11 cursor image; keeping the previous cursor and retrying\n");
            }
            host->cursor_read_failed = 1;
            host->cursor_dirty = 1;
            result = -1;
        } else {
            host->cursor_read_failed = 0;
            if (image->width > 1024 || image->height > 1024) {
                fprintf(stderr, "Ignoring unsupported %ux%u cursor (maximum 1024x1024)\n",
                        image->width, image->height);
                result = -1;
            } else {
                unsigned int width = image->width ? image->width : 1;
                unsigned int height = image->height ? image->height : 1;
                size_t count = (size_t)width * height;
                size_t mask_stride = (width + 7) / 8;
                rfbCursorPtr cursor = calloc(1, sizeof *cursor);
                if (cursor) {
                    cursor->cleanup = TRUE;
                    cursor->cleanupMask = TRUE;
                    cursor->cleanupRichSource = TRUE;
                    cursor->width = (unsigned short)width;
                    cursor->height = (unsigned short)height;
                    cursor->xhot = image->xhot < width ? image->xhot : 0;
                    cursor->yhot = image->yhot < height ? image->yhot : 0;
                    cursor->richSource = calloc(count, 4);
                    cursor->alphaSource = calloc(count, 1);
                    cursor->mask = calloc(mask_stride, height);
                }
                if (!cursor || !cursor->richSource || !cursor->alphaSource || !cursor->mask) {
                    rfbFreeCursor(cursor);
                    fprintf(stderr, "Cannot allocate X11 cursor image; keeping the previous cursor\n");
                    result = -1;
                } else {
                    for (unsigned int row = 0; row < image->height; ++row) {
                        for (unsigned int col = 0; col < image->width; ++col) {
                            size_t offset = (size_t)row * width + col;
                            uint32_t argb = (uint32_t)image->pixels[offset];
                            uint32_t alpha = argb >> 24;
                            uint32_t rgb = 0;
                            /* XFixes supplies premultiplied ARGB. VNC rich
                             * cursors need straight RGB in our server format. */
                            for (int shift = 0; shift <= 16; shift += 8) {
                                uint32_t value = (argb >> shift) & 255;
                                value = alpha ? (value * 255 + alpha / 2) / alpha : 0;
                                if (value > 255) value = 255;
                                rgb |= value << shift;
                            }
                            ((uint32_t *)cursor->richSource)[offset] = rgb;
                            cursor->alphaSource[offset] = (unsigned char)alpha;
                            /* Standard VNC cursor masks have one-bit opacity. */
                            if (alpha >= 128) {
                                cursor->mask[row * mask_stride + col / 8] |=
                                    (unsigned char)(0x80 >> (col % 8));
                            }
                        }
                    }
                    /* Ownership transfers to LibVNCServer, which frees this
                     * cursor on replacement and during screen cleanup. */
                    rfbSetCursor(host->screen, cursor);
                    host->cursor_repaint = 1;
                }
            }
            XFree(image);
        }
    }

    Window root, child;
    int x, y, window_x, window_y;
    unsigned int mask;
    if (XQueryPointer(host->display, host->root, &root, &child, &x, &y,
                      &window_x, &window_y, &mask)) {
        if (x < 0) x = 0;
        if (y < 0) y = 0;
        if (x >= host->width) x = host->width - 1;
        if (y >= host->height) y = host->height - 1;
        if (x != host->screen->cursorX || y != host->screen->cursorY) {
            host->screen->cursorX = x;
            host->screen->cursorY = y;
            host->cursor_repaint = 1;
            if (host->client) host->client->cursorWasMoved = TRUE;
        }
    }
    return result;
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
    Host *host = capture_error_host;
    if (host && error->request_code == host->damage_opcode &&
        (error->minor_code == X_DamageQueryVersion || error->minor_code == X_DamageCreate ||
         error->minor_code == X_DamageSubtract || error->minor_code == X_DamageDestroy)) {
        host->damage_error = error->error_code;
        return 0;
    }
    if (host && error->request_code == host->shm_opcode &&
        (error->minor_code == X_ShmAttach || error->minor_code == X_ShmGetImage ||
         error->minor_code == X_ShmDetach)) {
        /* Shared memory is optional, including when an advertised extension
         * cannot attach our segment (for example, a different IPC namespace). */
        host->shm_error = error->error_code;
        return 0;
    }
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

static void release_damage(Host *host) {
    if (!host->damage) return;
    XSync(host->display, False);
    host->damage_error = 0;
    capture_error_host = host;
    XErrorHandler previous_handler = XSetErrorHandler(image_error);
    XDamageDestroy(host->display, host->damage);
    XSync(host->display, False);
    XSetErrorHandler(previous_handler);
    capture_error_host = NULL;
    host->damage = None;
    host->screen_dirty = 1;
}

static void release_shm_image(Host *host) {
    if (!host->shm_image) return;
    if (host->shm_attached) {
        /* Complete previous requests before trapping just our detach request.
         * Wait for Xorg to release its mapping before releasing ours. */
        XSync(host->display, False);
        host->shm_error = 0;
        capture_error_host = host;
        XErrorHandler previous_handler = XSetErrorHandler(image_error);
        XShmDetach(host->display, &host->shm_segment);
        XSync(host->display, False);
        XSetErrorHandler(previous_handler);
        capture_error_host = NULL;
        host->shm_attached = 0;
    }
    host->shm_image->data = NULL; /* The mapping is not malloc-owned image data. */
    XDestroyImage(host->shm_image);
    host->shm_image = NULL;
    if (host->shm_segment.shmaddr && shmdt(host->shm_segment.shmaddr) != 0) {
        perror("Detaching XShm memory");
    }
    if (host->shm_segment.shmid >= 0 && !host->shm_marked &&
        shmctl(host->shm_segment.shmid, IPC_RMID, NULL) != 0) {
        perror("Removing XShm segment");
    }
    host->shm_segment = (XShmSegmentInfo){.shmid = -1};
    host->shm_marked = 0;
}

static void disable_shm(Host *host, const char *reason) {
    fprintf(stderr, "XShm capture unavailable (%s); using XGetImage until restart\n", reason);
    host->shm_enabled = 0;
    release_shm_image(host);
}

static int capture(Host *host) {
    int64_t current_ns = (host->stats.enabled || host->damage) ? monotonic_ns() : 0;
    int64_t started_ns = host->stats.enabled ? current_ns : 0;
    Window unused_root;
    int x, y;
    unsigned int width, height, border, depth;
    if (!XGetGeometry(host->display, host->root, &unused_root, &x, &y,
                      &width, &height, &border, &depth)) {
        fprintf(stderr, "Cannot query X11 desktop; session may have ended\n");
        return -1;
    }
    int resized = width != (unsigned int)host->width || height != (unsigned int)host->height;
    if (host->shm_image && (host->shm_image->width != (int)width ||
        host->shm_image->height != (int)height || host->shm_image->depth != (int)depth)) {
        release_shm_image(host);
        host->screen_dirty = 1;
    }
    /* Check geometry even while idle so the next viewer gets the current size,
     * but avoid reading screen pixels without a viewer unless resizing. */
    if (!resized && !host->client && !host->resize_unavailable) return 0;

    /* Geometry is synchronous: collect notifications it brought in before
     * deciding to reuse the cache. Refresh at least once a second as a safety
     * measure for applications/drivers that omit damage notifications. */
    process_x_events(host);
    int read_pixels = resized || host->resize_unavailable || !host->damage ||
                      host->screen_dirty || current_ns - host->last_pixel_capture_ns >= 1000000000LL;
    int paint_cursor = host->client && host->client->enableCursorShapeUpdates &&
                       cursor_in_framebuffer(host->client);
    if (!read_pixels && paint_cursor == host->cursor_composited &&
        (!paint_cursor || !host->cursor_repaint)) return 0;

    uint32_t *pixels = host->pixels;
    uint32_t *next_pixels = host->next_pixels;
    uint32_t *raw_pixels = host->raw_pixels;
    if (resized) {
        if (width < 1 || height < 1 || width > 8192 || height > 8192 ||
            (size_t)width * height > INT_MAX / 4) {
            return pause_for_resize(host, width, height, "unsupported size (maximum 8192x8192)");
        }
        size_t bytes = (size_t)width * height * 4;
        pixels = malloc(bytes);
        next_pixels = malloc(bytes);
        raw_pixels = malloc(bytes);
        if (!pixels || !next_pixels || !raw_pixels) {
            free(pixels);
            free(next_pixels);
            free(raw_pixels);
            return pause_for_resize(host, width, height, "cannot allocate replacement framebuffers");
        }
    }

    uint64_t grab_ns = 0;
    if (!read_pixels) goto compose_frame;
    if (host->damage) {
        /* Clear BEFORE reading, never after: drawing concurrent with capture
         * must leave the tracker armed for a later snapshot. */
        host->screen_dirty = 0;
        host->damage_error = 0;
        capture_error_host = host;
        XErrorHandler previous_handler = XSetErrorHandler(image_error);
        XDamageSubtract(host->display, host->damage, None, None);
        XSync(host->display, False);
        XSetErrorHandler(previous_handler);
        capture_error_host = NULL;
        if (host->damage_error) {
            char message[128];
            XGetErrorText(host->display, host->damage_error, message, sizeof message);
            fprintf(stderr, "XDamage tracking failed (%s); using polling until restart\n", message);
            release_damage(host);
        }
    }

    if (host->shm_enabled && !host->shm_image) {
        const char *failure = NULL;
        char message[160];
        do {
            host->shm_segment = (XShmSegmentInfo){.shmid = -1};
            host->shm_image = XShmCreateImage(host->display,
                DefaultVisual(host->display, DefaultScreen(host->display)), depth,
                ZPixmap, NULL, &host->shm_segment, width, height);
            if (!host->shm_image) {
                failure = "cannot allocate image metadata";
                break;
            }
            if (host->shm_image->bytes_per_line <= 0 || host->shm_image->height <= 0 ||
                (size_t)host->shm_image->bytes_per_line > SIZE_MAX / (size_t)host->shm_image->height) {
                failure = "invalid shared image size";
                break;
            }
            size_t bytes = (size_t)host->shm_image->bytes_per_line * host->shm_image->height;
            host->shm_segment.shmid = shmget(IPC_PRIVATE, bytes, IPC_CREAT | 0600);
            if (host->shm_segment.shmid < 0) {
                snprintf(message, sizeof message, "shmget: %s", strerror(errno));
                failure = message;
                break;
            }
            char *address = shmat(host->shm_segment.shmid, NULL, 0);
            if (address == (char *)-1) {
                snprintf(message, sizeof message, "shmat: %s", strerror(errno));
                failure = message;
                break;
            }
            host->shm_segment.shmaddr = address;
            host->shm_image->data = address;
            host->shm_segment.readOnly = False; /* Xorg must write the capture. */
            /* Linux allows Xorg to attach after IPC_RMID while our mapping is
             * alive. Mark early so a crash/disconnect during XShmAttach does
             * not leave the segment behind. It disappears after both detach. */
            if (shmctl(host->shm_segment.shmid, IPC_RMID, NULL) != 0) {
                snprintf(message, sizeof message, "shmctl: %s", strerror(errno));
                failure = message;
                break;
            }
            host->shm_marked = 1;
            host->shm_error = 0;
            capture_error_host = host;
            XErrorHandler previous_handler = XSetErrorHandler(image_error);
            Bool attached = XShmAttach(host->display, &host->shm_segment);
            XSync(host->display, False); /* Attach errors are asynchronous. */
            XSetErrorHandler(previous_handler);
            capture_error_host = NULL;
            if (!attached || host->shm_error) {
                if (host->shm_error) {
                    XGetErrorText(host->display, host->shm_error, message, sizeof message);
                    failure = message;
                } else {
                    failure = "XShmAttach failed";
                }
                break;
            }
            host->shm_attached = 1;
        } while (0);
        if (failure) disable_shm(host, failure);
    }

    /* Geometry has completed pending input requests. Trap errors only around
     * image operations; never expose optional shared-memory errors to Xlib's
     * default handler. The reply makes the shared pixels safe to read. */
    XImage *image = NULL;
    if (host->shm_enabled) {
        host->shm_error = 0;
        capture_error_host = host;
        XErrorHandler previous_handler = XSetErrorHandler(image_error);
        int64_t grab_started_ns = host->stats.enabled ? monotonic_ns() : 0;
        Bool captured = XShmGetImage(host->display, host->root, host->shm_image, 0, 0, AllPlanes);
        if (host->stats.enabled) grab_ns += (uint64_t)(monotonic_ns() - grab_started_ns);
        XSetErrorHandler(previous_handler);
        capture_error_host = NULL;
        if (captured && !host->shm_error) {
            image = host->shm_image;
        } else {
            char message[128] = "XShmGetImage failed";
            if (host->shm_error) XGetErrorText(host->display, host->shm_error, message, sizeof message);
            disable_shm(host, message);
        }
    }
    if (!image) {
        XErrorHandler previous_handler = XSetErrorHandler(image_error);
        int64_t grab_started_ns = host->stats.enabled ? monotonic_ns() : 0;
        image = XGetImage(host->display, host->root, 0, 0, width, height, AllPlanes, ZPixmap);
        if (host->stats.enabled) grab_ns += (uint64_t)(monotonic_ns() - grab_started_ns);
        XSetErrorHandler(previous_handler);
    }
    if (!image) {
        host->screen_dirty = 1; /* A failed read must not consume the change. */
        if (resized) {
            free(pixels);
            free(next_pixels);
            free(raw_pixels);
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
            memcpy(raw_pixels + (size_t)row * width,
                   image->data + (size_t)row * image->bytes_per_line, width * 4);
        }
    } else {
        for (unsigned int row = 0; row < height; ++row) {
            for (unsigned int col = 0; col < width; ++col) {
                unsigned long pixel = XGetPixel(image, col, row);
                raw_pixels[(size_t)row * width + col] =
                    (channel(pixel, image->red_mask) << 16) |
                    (channel(pixel, image->green_mask) << 8) |
                    channel(pixel, image->blue_mask);
            }
        }
    }
    if (image != host->shm_image) XDestroyImage(image);
    if (host->damage) host->last_pixel_capture_ns = monotonic_ns();

compose_frame:
    /* Keep a clean cache for both capture methods. Painting into it would
     * leave cursor trails when the screen itself has not changed. */
    memcpy(next_pixels, raw_pixels, (size_t)width * height * 4);
    if (paint_cursor) {
        rfbCursorPtr cursor = host->screen->cursor;
        int left = host->screen->cursorX - cursor->xhot;
        int top = host->screen->cursorY - cursor->yhot;
        int start_x = left < 0 ? -left : 0;
        int start_y = top < 0 ? -top : 0;
        int end_x = left + cursor->width > (int)width ? (int)width - left : cursor->width;
        int end_y = top + cursor->height > (int)height ? (int)height - top : cursor->height;
        /* Compose onto clean pixels, including on cursor-only cached frames,
         * so moving or changing the cursor restores its old background. */
        for (int row = start_y; row < end_y; ++row) {
            for (int col = start_x; col < end_x; ++col) {
                size_t offset = (size_t)row * cursor->width + col;
                uint32_t alpha = cursor->alphaSource ? cursor->alphaSource[offset] :
                    ((cursor->mask[row * ((cursor->width + 7) / 8) + col / 8] &
                      (0x80 >> (col % 8))) ? 255 : 0);
                if (!alpha) continue;
                uint32_t source = ((uint32_t *)cursor->richSource)[offset];
                uint32_t *destination = next_pixels + (size_t)(top + row) * width + (size_t)(left + col);
                uint32_t rgb = 0;
                for (int shift = 0; shift <= 16; shift += 8) {
                    uint32_t foreground = (source >> shift) & 255;
                    uint32_t background = (*destination >> shift) & 255;
                    rgb |= ((foreground * alpha + background * (255 - alpha) + 127) / 255) << shift;
                }
                *destination = rgb;
            }
        }
    }

    host->cursor_composited = paint_cursor;
    host->cursor_repaint = 0;
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
        free(host->raw_pixels);
        host->pixels = pixels;
        host->next_pixels = next_pixels;
        host->raw_pixels = raw_pixels;
        host->width = (int)width;
        host->height = (int)height;
        record_capture(host, started_ns, grab_ns, read_pixels);
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
    record_capture(host, started_ns, grab_ns, read_pixels);
    return 0;
}

int main(int argc, char **argv) {
    const char *listen_ip = NULL;
    const char *password_file = NULL;
    int port = 5900, fps = 10, stats_enabled = 0, clipboard_enabled = 0;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "--listen") && i + 1 < argc) listen_ip = argv[++i];
        else if (!strcmp(argv[i], "--password-file") && i + 1 < argc) password_file = argv[++i];
        else if (!strcmp(argv[i], "--port") && i + 1 < argc) port = parse_number(argv[++i], 1, 65535);
        else if (!strcmp(argv[i], "--fps") && i + 1 < argc) fps = parse_number(argv[++i], 1, 30);
        else if (!strcmp(argv[i], "--stats")) stats_enabled = 1;
        else if (!strcmp(argv[i], "--clipboard")) clipboard_enabled = 1;
        else {
            fprintf(stderr, "Usage: %s --listen <Tailscale IPv4> --password-file <file> [--port 5900] [--fps 10] [--stats] [--clipboard]\n", argv[0]);
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
    major = XFIXES_MAJOR;
    minor = XFIXES_MINOR;
    if (!XFixesQueryExtension(host.display, &host.cursor_event_base, &error_base) ||
        !XFixesQueryVersion(host.display, &major, &minor) || major < 1) {
        fprintf(stderr, "X11 XFIXES cursor extension is unavailable\n");
        XCloseDisplay(host.display);
        return 1;
    }
    major = XkbMajorVersion;
    minor = XkbMinorVersion;
    int keyboard_opcode;
    if (!XkbQueryExtension(host.display, &keyboard_opcode, &host.keyboard_event_base,
                          &error_base, &major, &minor)) {
        fprintf(stderr, "X11 XKEYBOARD input extension is unavailable\n");
        XCloseDisplay(host.display);
        return 1;
    }
    unsigned int keyboard_events = XkbStateNotifyMask | XkbMapNotifyMask |
                                  XkbNewKeyboardNotifyMask | XkbControlsNotifyMask;
    XkbSelectEvents(host.display, XkbUseCoreKbd, keyboard_events, keyboard_events);
    host.keymap_dirty = 1;
    if (refresh_keyboard(&host) != 0) {
        XCloseDisplay(host.display);
        return 1;
    }
    host.root = DefaultRootWindow(host.display);
    host.shm_enabled = XQueryExtension(host.display, "MIT-SHM", &host.shm_opcode, &event_base, &error_base);
    if (!host.shm_enabled) disable_shm(&host, "MIT-SHM extension is unavailable");
    host.screen_dirty = 1;
    if (XQueryExtension(host.display, "DAMAGE", &host.damage_opcode, &host.damage_event_base, &error_base)) {
        host.damage_error = 0;
        capture_error_host = &host;
        XErrorHandler previous_handler = XSetErrorHandler(image_error);
        major = DAMAGE_MAJOR;
        minor = DAMAGE_MINOR;
        Damage candidate = None;
        if (XDamageQueryVersion(host.display, &major, &minor) && major == DAMAGE_MAJOR &&
            !host.damage_error) {
            candidate = XDamageCreate(host.display, host.root, XDamageReportNonEmpty);
            XSync(host.display, False);
        }
        XSetErrorHandler(previous_handler);
        capture_error_host = NULL;
        if (candidate && !host.damage_error) host.damage = candidate;
    }
    if (!host.damage) fprintf(stderr, "XDamage unavailable; using polling until restart\n");
    XFixesSelectCursorInput(host.display, host.root, XFixesDisplayCursorNotifyMask);
    host.cursor_dirty = 1;
    if (capture(&host) != 0) {
        release_damage(&host);
        release_shm_image(&host);
        free(host.pixels);
        free(host.next_pixels);
        free(host.raw_pixels);
        XkbFreeKeyboard(host.keymap, XkbAllComponentsMask, True);
        XCloseDisplay(host.display);
        return 1;
    }

    int vnc_argc = 1;
    char *vnc_argv[] = {argv[0], NULL};
    host.screen = rfbGetScreen(&vnc_argc, vnc_argv, host.width, host.height, 8, 3, 4);
    if (!host.screen) {
        fprintf(stderr, "Cannot initialize VNC screen\n");
        release_damage(&host);
        release_shm_image(&host);
        free(host.pixels);
        free(host.next_pixels);
        free(host.raw_pixels);
        XkbFreeKeyboard(host.keymap, XkbAllComponentsMask, True);
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
    host.screen->setXCutText = clipboard_from_viewer; /* Disabled unless explicitly enabled. */
    host.screen->getCursorPtr = viewer_cursor;
    if (stats_enabled) host.screen->displayFinishedHook = display_finished;
    /* A cursor image can be unavailable during session/display startup. Keep
     * remote access available with an invisible cursor until a refresh succeeds. */
    rfbCursorPtr initial_cursor = rfbMakeXCursor(1, 1, " ", " ");
    if (!initial_cursor) {
        fprintf(stderr, "Cannot initialize VNC cursor\n");
        rfbScreenCleanup(host.screen);
        release_damage(&host);
        release_shm_image(&host);
        free(host.pixels);
        free(host.next_pixels);
        free(host.raw_pixels);
        XkbFreeKeyboard(host.keymap, XkbAllComponentsMask, True);
        XCloseDisplay(host.display);
        return 1;
    }
    rfbSetCursor(host.screen, initial_cursor);
    (void)update_cursor(&host);

    struct sigaction action = {0};
    action.sa_handler = stop_on_signal;
    sigaction(SIGINT, &action, NULL);
    sigaction(SIGTERM, &action, NULL);
    rfbInitServer(host.screen);
    if (host.screen->listenSock == RFB_INVALID_SOCKET || !rfbIsActive(host.screen)) {
        fprintf(stderr, "VNC server could not start; check the listen IP and port\n");
        rfbScreenCleanup(host.screen);
        release_damage(&host);
        release_shm_image(&host);
        free(host.pixels);
        free(host.next_pixels);
        free(host.raw_pixels);
        XkbFreeKeyboard(host.keymap, XkbAllComponentsMask, True);
        XCloseDisplay(host.display);
        return 1;
    }
    if (clipboard_enabled) {
        Clipboard *clip = &host.clipboard;
        char *names[] = {"CLIPBOARD", "UTF8_STRING", "TARGETS", "TIMESTAMP", "INCR", "_SHAREDESK_CLIPBOARD"};
        Atom atoms[6];
        if (XInternAtoms(host.display, names, 6, False, atoms)) {
            clip->selection = atoms[0]; clip->utf8 = atoms[1]; clip->targets = atoms[2];
            clip->timestamp = atoms[3]; clip->incr = atoms[4]; clip->property = atoms[5];
            clip->window = XCreateSimpleWindow(host.display, host.root, 0, 0, 1, 1, 0, 0, 0);
            long words = XExtendedMaxRequestSize(host.display);
            if (!words) words = XMaxRequestSize(host.display);
            clip->max_property_bytes = words > 64 ? (size_t)(words - 64) * 4 : 0;
            if (clip->window) {
                clip->enabled = 1;
                XFixesSelectSelectionInput(host.display, clip->window, clip->selection,
                    XFixesSetSelectionOwnerNotifyMask | XFixesSelectionWindowDestroyNotifyMask |
                    XFixesSelectionClientCloseNotifyMask);
                fprintf(stderr, "Text clipboard sharing enabled (Latin-1, up to 1 MiB)\n");
            }
        }
        if (!clip->enabled) fprintf(stderr, "Clipboard initialization failed; desktop sharing remains available\n");
    }
    fprintf(stderr, "Capture method: %s; changes: %s\n",
            host.shm_enabled ? "xshm (shared memory)" : "xgetimage",
            host.damage ? "xdamage (with 1-second safety refresh)" : "polling");
    fprintf(stderr, "Serving %dx%d X11 desktop on %s:%d at up to %d fps (Ctrl+C to stop)\n",
            host.width, host.height, listen_ip, port, fps);
    int result = 0;
    int64_t interval_ns = 1000000000LL / fps;
    int64_t started_ns = monotonic_ns();
    int64_t next_capture = started_ns + interval_ns;
    /* Exclude startup capture and initialization from the measurement window. */
    host.stats.enabled = stats_enabled;
    host.stats.started_ns = started_ns;
    host.stats.cpu_started_us = stats_enabled ? process_cpu_us() : -1;
    if (stats_enabled) fprintf(stderr, "Performance statistics enabled (5-second intervals)\n");
    while (!stopping && rfbIsActive(host.screen)) {
        /* Shape notifications are coalesced; local position is polled even
         * without screen damage. Missing images retry; other refresh failures
         * retain the previous cursor until the next shape notification. */
        (void)update_cursor(&host);
        int64_t current = monotonic_ns();
        if (host.clipboard.enabled) {
            if (host.client && host.client->state == RFB_NORMAL && host.client->sock != RFB_INVALID_SOCKET)
                host.clipboard.active = 1; /* Pre-authentication events were drained above. */
            else if (host.clipboard.active) reset_clipboard_connection(&host);
            if (host.clipboard.reader && current >= host.clipboard.deadline_ns) {
                fprintf(stderr, "Clipboard export timed out; desktop sharing remains available\n");
                cancel_clipboard_read(&host);
            }
        }
        for (int key = 1; key < 256; ++key) {
            if (host.keys[key] == 2 && host.key_repeat_at[key] && current >= host.key_repeat_at[key]) {
                if (press_key(&host, host.key_symbols[key], (KeyCode)key) != 0) {
                    host.key_repeat_at[key] = current + 50000000; /* Bounded retry. */
                }
            }
        }
        if (current >= next_capture) {
            if (capture(&host) != 0) {
                result = 1;
                break;
            }
            next_capture = current + interval_ns;
        }
        if (host.stats.enabled) {
            Stats *stats = &host.stats;
            int64_t report_ns = monotonic_ns();
            int64_t elapsed_ns = report_ns - stats->started_ns;
            if (elapsed_ns >= 5000000000LL) {
                if (host.client) sample_client_bytes(&host, host.client);
                double seconds = elapsed_ns / 1000000000.0;
                char capture_ms[48] = "n/a", grab_ms[48] = "n/a", cpu[32] = "n/a";
                if (stats->captures) {
                    snprintf(capture_ms, sizeof capture_ms, "%.2f/%.2f",
                             stats->capture_ns / (double)stats->captures / 1000000.0,
                             stats->capture_max_ns / 1000000.0);
                    snprintf(grab_ms, sizeof grab_ms, "%.2f/%.2f",
                             stats->grab_ns / (double)stats->captures / 1000000.0,
                             stats->grab_max_ns / 1000000.0);
                }
                int64_t cpu_now_us = process_cpu_us();
                if (stats->cpu_started_us >= 0 && cpu_now_us >= stats->cpu_started_us) {
                    snprintf(cpu, sizeof cpu, "%.1f%%",
                             (cpu_now_us - stats->cpu_started_us) * 100.0 / (elapsed_ns / 1000.0));
                }
                const char *viewer = "idle";
                if (host.client && host.client->sock != RFB_INVALID_SOCKET) {
                    viewer = host.client->state == RFB_NORMAL ? "active" : "auth";
                }
                fprintf(stderr, "Stats %.1fs: viewer=%s size=%dx%d capture=%s changes=%s captures=%" PRIu64
                        " fps=%.1f cursor_frames=%" PRIu64 " capture_ms(avg/max)=%s grab_ms(avg/max)=%s"
                        " vnc_bytes=%" PRIu64 " vnc_KiB/s=%.1f cpu=%s\n",
                        seconds, viewer, host.width, host.height,
                        host.shm_enabled ? "xshm" : "xgetimage", host.damage ? "xdamage" : "poll",
                        stats->captures, stats->captures / seconds, stats->cursor_frames, capture_ms, grab_ms,
                        stats->sent_bytes, stats->sent_bytes / seconds / 1024.0, cpu);
                /* Preserve the current client's counter baseline across windows. */
                *stats = (Stats){.enabled = 1, .started_ns = report_ns,
                                 .cpu_started_us = cpu_now_us,
                                 .last_sent_bytes = stats->last_sent_bytes};
            }
        }
        /* Capture and reporting may have consumed part or all of the interval.
         * Wait only until the next capture or corrected-key repeat deadline. */
        int64_t deadline = next_capture;
        for (int key = 1; key < 256; ++key) {
            if (host.keys[key] == 2 && host.key_repeat_at[key] && host.key_repeat_at[key] < deadline)
                deadline = host.key_repeat_at[key];
        }
        int64_t wait_us = (deadline - monotonic_ns()) / 1000;
        if (wait_us > 50000) wait_us = 50000;
        if (wait_us < 1000) wait_us = 1000;
        rfbProcessEvents(host.screen, (long)wait_us);
    }
    if (host.client) release_input(&host);
    rfbShutdownServer(host.screen, TRUE);
    rfbScreenCleanup(host.screen);
    release_damage(&host);
    release_shm_image(&host);
    free(host.pixels);
    free(host.next_pixels);
    free(host.raw_pixels);
    XkbFreeKeyboard(host.keymap, XkbAllComponentsMask, True);
    reset_clipboard_connection(&host);
    free(host.clipboard.text);
    if (host.clipboard.window) XDestroyWindow(host.display, host.clipboard.window);
    XCloseDisplay(host.display);
    memset(password, 0, sizeof password);
    return result;
}
