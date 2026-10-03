#ifndef SHAREDESK_VNC_BRIDGE_H
#define SHAREDESK_VNC_BRIDGE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <rfb/keysym.h>
#include <IOKit/hidsystem/IOLLEvent.h>

typedef struct SDVNCClient SDVNCClient;

/* Callbacks run synchronously on the calling worker. All pixel/text/mask
 * pointers are borrowed only for that callback. Copy before returning.
 * context is caller-owned and must live until sd_vnc_destroy() returns. */
typedef struct {
    void (*frame)(void *context, const uint8_t *pixels, int width, int height);
    void (*cursor)(void *context, const uint8_t *pixels, const uint8_t *mask,
                   int width, int height, int hot_x, int hot_y);
    /* Text excludes the protocol terminator. utf8=false means ISO-8859-1. */
    void (*clipboard)(void *context, const char *text, int length, bool utf8);
    /* Swift owns opt-in policy. Bit 0 enables sharing; other bits are an
     * epoch changed on every toggle, invalidating retained protocol offers. */
    uint64_t (*clipboard_state)(void *context);
} SDVNCCallbacks;

/* The worker owns the handle. No function starts a thread or schedules work.
 * Network operations may block. The caller controls elapsed
 * deadlines and cancellation by shutting down its own duplicate of socket().
 * The framebuffer is bridge-owned, native-endian 32-bit 0x00RRGGBB. */
SDVNCClient *sd_vnc_create(SDVNCCallbacks callbacks, void *context);
void sd_vnc_destroy(SDVNCClient *client);
bool sd_vnc_connect(SDVNCClient *client, const char *host, int port, unsigned int timeout_seconds);
int sd_vnc_socket(SDVNCClient *client); /* Borrowed descriptor; do not close it. */
/* password is borrowed only for authenticate(); LibVNCClient frees its copy. */
bool sd_vnc_authenticate(SDVNCClient *client, const char *password);
bool sd_vnc_initialize_framebuffer(SDVNCClient *client);
/* Readiness: -1 = error, 0 = no data, positive = buffered/socket data ready.
 * wait bounds only the readiness check, not process_message(). */
int sd_vnc_wait(SDVNCClient *client, unsigned int timeout_microseconds);
bool sd_vnc_process_message(SDVNCClient *client);
typedef struct {
    int width, height;
    uint64_t updates; /* Completed framebuffer-update messages, including metadata-only updates. */
} SDVNCFramebufferInfo;
/* Worker-only, nonblocking value snapshot. No allocation or retained buffers. */
SDVNCFramebufferInfo sd_vnc_framebuffer_info(SDVNCClient *client);
bool sd_vnc_write(SDVNCClient *client, const uint8_t *packet, size_t length);
bool sd_vnc_clipboard_utf8(SDVNCClient *client); /* Negotiated text/provide support. */
typedef enum {
    SDVNC_CLIPBOARD_SENT, SDVNC_CLIPBOARD_UNSUPPORTED,
    SDVNC_CLIPBOARD_TOO_LARGE, SDVNC_CLIPBOARD_FAILED
} SDVNCClipboardResult;
/* UTF-8 is CRLF-normalized, without its protocol NUL; the worker borrows it
 * for this call. A protocol offer is retained only until replacement/toggle
 * or destruction. This may block on writes under the caller's I/O deadline. */
SDVNCClipboardResult sd_vnc_send_clipboard_utf8(SDVNCClient *client, const uint8_t *text, size_t length);

#endif
