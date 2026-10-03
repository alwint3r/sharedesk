#include "VNCBridge.h"
#include <limits.h>
#include <arpa/inet.h>
#include <rfb/rfbclient.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <zlib.h>

#define CLIPBOARD_LIMIT (1U << 20)

struct SDVNCClient {
    rfbClient *rfb;
    SDVNCCallbacks callbacks;
    void *context;
    const char *password;
    uint64_t framebuffer_updates;
    uint32_t clipboard_capabilities;
    uint32_t clipboard_unsolicited_limit;
    uint64_t clipboard_epoch;
    char *clipboard_offer; /* Protocol response state, never a history. */
    size_t clipboard_offer_length;
};

static char bridge_tag;
static SDVNCClient *bridge_for(rfbClient *client) {
    return rfbClientGetClientData(client, &bridge_tag);
}
static char *password_for(rfbClient *client) {
    const char *password = bridge_for(client)->password;
    return strdup(password ? password : "");
}
static rfbBool allocate_framebuffer(rfbClient *client) {
    if (client->width < 1 || client->height < 1 || client->width > 8192 || client->height > 8192) return FALSE;
    uint8_t *pixels = calloc((size_t)client->width * client->height, 4);
    if (!pixels) return FALSE;
    free(client->frameBuffer);
    client->frameBuffer = pixels;
    return TRUE;
}
static void finished_framebuffer(rfbClient *client) {
    SDVNCClient *bridge = bridge_for(client);
    if (bridge->callbacks.frame) bridge->callbacks.frame(bridge->context, client->frameBuffer, client->width, client->height);
}
static void received_clipboard(rfbClient *client, const char *text, int length) {
    SDVNCClient *bridge = bridge_for(client);
    if (bridge->callbacks.clipboard) bridge->callbacks.clipboard(bridge->context, text, length, false);
}
static void received_clipboard_utf8(rfbClient *client, const char *text, int length) {
    SDVNCClient *bridge = bridge_for(client);
    if (bridge->callbacks.clipboard) bridge->callbacks.clipboard(bridge->context, text, length, true);
}

static bool clipboard_allowed(SDVNCClient *bridge) {
    uint64_t state = bridge->callbacks.clipboard_state ? bridge->callbacks.clipboard_state(bridge->context) : 0;
    if (state != bridge->clipboard_epoch) {
        free(bridge->clipboard_offer);
        bridge->clipboard_offer = NULL;
        bridge->clipboard_offer_length = 0;
        bridge->clipboard_epoch = state;
    }
    return (state & 1) != 0;
}

static bool clipboard_control(SDVNCClient *bridge, uint32_t flags, bool caps) {
    uint32_t packet[4] = {htonl(6U << 24), htonl(caps ? (uint32_t)-8 : (uint32_t)-4),
                         htonl(flags), htonl(CLIPBOARD_LIMIT)};
    return WriteToRFBServer(bridge->rfb, (char *)packet, caps ? 16 : 12);
}

static SDVNCClipboardResult clipboard_provide(SDVNCClient *bridge) {
    size_t length = bridge->clipboard_offer_length;
    if (length >= CLIPBOARD_LIMIT) return SDVNC_CLIPBOARD_TOO_LARGE;
    size_t plain_length = length + 5;
    uint8_t *plain = malloc(plain_length);
    uLong capacity = compressBound(plain_length) + 32;
    uint8_t *packet = malloc(capacity + 12);
    if (!plain || !packet) { free(plain); free(packet); return SDVNC_CLIPBOARD_FAILED; }
    uint32_t size = htonl((uint32_t)length + 1);
    memcpy(plain, &size, 4);
    memcpy(plain + 4, bridge->clipboard_offer, length + 1);
    z_stream stream = {0};
    bool valid = deflateInit(&stream, Z_DEFAULT_COMPRESSION) == Z_OK;
    if (valid) {
        stream.next_in = plain; stream.avail_in = (uInt)plain_length;
        stream.next_out = packet + 12; stream.avail_out = (uInt)capacity;
        valid = deflate(&stream, Z_SYNC_FLUSH) == Z_OK && stream.avail_in == 0;
        capacity = stream.total_out;
        deflateEnd(&stream);
    }
    free(plain);
    if (!valid) { free(packet); return SDVNC_CLIPBOARD_FAILED; }
    if (capacity + 4 > CLIPBOARD_LIMIT) { free(packet); return SDVNC_CLIPBOARD_TOO_LARGE; }
    uint32_t header[3] = {htonl(6U << 24), htonl((uint32_t)-(int32_t)(capacity + 4)),
                         htonl(rfbExtendedClipboard_Provide | rfbExtendedClipboard_Text)};
    memcpy(packet, header, 12);
    if (!clipboard_allowed(bridge)) { free(packet); return SDVNC_CLIPBOARD_SENT; }
    valid = WriteToRFBServer(bridge->rfb, (char *)packet, (unsigned int)capacity + 12);
    free(packet);
    return valid ? SDVNC_CLIPBOARD_SENT : SDVNC_CLIPBOARD_FAILED;
}

/* LibVNCClient 0.9.15 ignores notify/request and does not validate format
 * terminators. Decode only clipboard messages here; all video/input protocol
 * remains in the library. Every compressed and inflated buffer is bounded. */
static bool process_clipboard(SDVNCClient *bridge) {
    rfbClient *client = bridge->rfb;
    uint8_t header[8];
    if (!ReadFromRFBServer(client, (char *)header, 8)) return false;
    uint32_t network_length;
    memcpy(&network_length, header + 4, 4);
    int32_t signed_length = (int32_t)ntohl(network_length);
    if (signed_length == INT32_MIN) return false;
    size_t length = signed_length < 0 ? (size_t)-signed_length : (size_t)signed_length;
    if (length > CLIPBOARD_LIMIT || (signed_length < 0 && length < 4)) return false;
    uint8_t *data = malloc(length + 1);
    if (!data || !ReadFromRFBServer(client, (char *)data, (unsigned int)length)) { free(data); return false; }
    data[length] = 0;
    bool allowed = clipboard_allowed(bridge), valid = true;
    if (signed_length >= 0) {
        if (allowed) received_clipboard(client, (char *)data, (int)length);
    } else {
        uint32_t flags;
        memcpy(&flags, data, 4); flags = ntohl(flags);
        uint32_t action = flags & 0xff000000U;
        if (action & rfbExtendedClipboard_Caps) {
            size_t formats = 0;
            for (unsigned int i = 0; i < 16; ++i) if (flags & (1U << i)) ++formats;
            valid = length == 4 + formats * 4 && !(flags & 0x00ff0000U);
            if (valid) {
                bridge->clipboard_capabilities = flags;
                uint32_t limit = 0;
                if (flags & rfbExtendedClipboard_Text) memcpy(&limit, data + 4, 4);
                bridge->clipboard_unsolicited_limit = ntohl(limit);
                free(bridge->clipboard_offer); bridge->clipboard_offer = NULL;
                bridge->clipboard_offer_length = 0;
                valid = clipboard_control(bridge, rfbExtendedClipboard_Caps | rfbExtendedClipboard_Text |
                    rfbExtendedClipboard_Notify | rfbExtendedClipboard_Request | rfbExtendedClipboard_Provide, true);
            }
        } else if (action == rfbExtendedClipboard_Provide) {
            if (flags == (rfbExtendedClipboard_Provide | rfbExtendedClipboard_Text) && allowed) {
                z_stream stream = {0};
                valid = inflateInit(&stream) == Z_OK;
                if (valid) {
                    stream.next_in = data + 4; stream.avail_in = (uInt)length - 4;
                    uint32_t size = 0;
                    stream.next_out = (uint8_t *)&size; stream.avail_out = 4;
                    int result = inflate(&stream, Z_SYNC_FLUSH);
                    size = ntohl(size);
                    valid = result == Z_OK && stream.total_out == 4 && size >= 1 && size <= CLIPBOARD_LIMIT;
                    uint8_t *text = valid ? malloc(size) : NULL;
                    if (valid && !text) valid = false;
                    if (valid) {
                        stream.next_out = text; stream.avail_out = size;
                        result = inflate(&stream, Z_SYNC_FLUSH);
                        valid = (result == Z_OK || result == Z_STREAM_END) && stream.total_out == (uLong)size + 4;
                        if (valid) {
                            uint8_t extra;
                            stream.next_out = &extra; stream.avail_out = 1;
                            result = inflate(&stream, Z_SYNC_FLUSH);
                            valid = stream.total_out == (uLong)size + 4 && stream.avail_in == 0 &&
                                (result == Z_OK || result == Z_STREAM_END || result == Z_BUF_ERROR);
                        }
                        if (valid && text[size - 1] == 0 && !memchr(text, 0, size - 1))
                            received_clipboard_utf8(client, (char *)text, (int)size - 1);
                    }
                    free(text);
                    inflateEnd(&stream);
                }
            }
        } else if (action == rfbExtendedClipboard_Notify) {
            valid = length == 4;
            if (valid && allowed && (flags & rfbExtendedClipboard_Text) && sd_vnc_clipboard_utf8(bridge) &&
                (bridge->clipboard_capabilities & rfbExtendedClipboard_Request))
                valid = clipboard_control(bridge, rfbExtendedClipboard_Request | rfbExtendedClipboard_Text, false);
        } else if (action == rfbExtendedClipboard_Request) {
            valid = length == 4;
            if (valid && allowed && (flags & rfbExtendedClipboard_Text) && bridge->clipboard_offer)
                valid = clipboard_provide(bridge) == SDVNC_CLIPBOARD_SENT;
        } else if (action == rfbExtendedClipboard_Peek) {
            valid = length == 4;
            if (valid && allowed) valid = clipboard_control(bridge, rfbExtendedClipboard_Notify |
                (bridge->clipboard_offer ? rfbExtendedClipboard_Text : 0), false);
        }
    }
    free(data);
    return valid;
}
static void received_cursor(rfbClient *client, int hot_x, int hot_y, int width, int height, int bytes_per_pixel) {
    SDVNCClient *bridge = bridge_for(client);
    if (bytes_per_pixel == 4 && bridge->callbacks.cursor) {
        bridge->callbacks.cursor(bridge->context, client->rcSource, client->rcMask, width, height, hot_x, hot_y);
    }
}
static rfbBool received_cursor_position(rfbClient *client, int x, int y) {
    /* Do not warp the Mac's global pointer when Ubuntu is used locally. */
    (void)client; (void)x; (void)y;
    return TRUE;
}

SDVNCClient *sd_vnc_create(SDVNCCallbacks callbacks, void *context) {
    SDVNCClient *bridge = calloc(1, sizeof *bridge);
    if (!bridge) return NULL;
    rfbClient *client = rfbGetClient(8, 3, 4);
    if (!client) { free(bridge); return NULL; }
    bridge->rfb = client; bridge->callbacks = callbacks; bridge->context = context;
    rfbClientSetClientData(client, &bridge_tag, bridge);
    client->GetPassword = password_for;
    client->MallocFrameBuffer = allocate_framebuffer;
    client->FinishedFrameBufferUpdate = finished_framebuffer;
    client->GotXCutText = received_clipboard;
    client->GotXCutTextUTF8 = received_clipboard_utf8; /* Advertise standard UTF-8 support. */
    client->GotCursorShape = received_cursor;
    client->HandleCursorPos = received_cursor_position;
    client->appData.useRemoteCursor = TRUE;
    client->appData.encodingsString = "zrle zlib hextile raw";
    client->appData.enableJPEG = FALSE;
    client->canHandleNewFBSize = TRUE;
    /* The Swift caller enforces elapsed deadlines. 0.9.15's retry counter can
     * falsely time out healthy fragmented transfers in less than a second. */
    client->readTimeout = 0;
    client->format.bitsPerPixel = 32; client->format.depth = 24; client->format.trueColour = TRUE;
    const uint16_t endian = 1;
    client->format.bigEndian = *(const uint8_t *)&endian == 0;
    client->format.redMax = client->format.greenMax = client->format.blueMax = 255;
    client->format.redShift = 16; client->format.greenShift = 8; client->format.blueShift = 0;
    uint32_t schemes[] = {rfbVncAuth};
    SetClientAuthSchemes(client, schemes, 1);
    return bridge;
}
void sd_vnc_destroy(SDVNCClient *bridge) {
    if (!bridge) return;
    /* LibVNCClient owns its decoder, socket and cursor, not frameBuffer. */
    free(bridge->rfb->frameBuffer);
    bridge->rfb->frameBuffer = NULL;
    rfbClientCleanup(bridge->rfb);
    free(bridge->clipboard_offer);
    free(bridge);
}
bool sd_vnc_connect(SDVNCClient *bridge, const char *host, int port, unsigned int timeout_seconds) {
    bridge->rfb->connectTimeout = timeout_seconds;
    return ConnectToRFBServer(bridge->rfb, host, port);
}
int sd_vnc_socket(SDVNCClient *bridge) {
    return bridge->rfb->sock;
}
bool sd_vnc_authenticate(SDVNCClient *bridge, const char *password) {
    bridge->password = password;
    bool authenticated = InitialiseRFBConnection(bridge->rfb) && bridge->rfb->authScheme == rfbVncAuth;
    bridge->password = NULL;
    return authenticated;
}
bool sd_vnc_initialize_framebuffer(SDVNCClient *bridge) {
    rfbClient *client = bridge->rfb;
    client->width = client->si.framebufferWidth; client->height = client->si.framebufferHeight;
    client->updateRect.x = client->updateRect.y = 0;
    client->updateRect.w = client->width; client->updateRect.h = client->height;
    client->isUpdateRectManagedByLib = TRUE;
    return allocate_framebuffer(client) && SetFormatAndEncodings(client) &&
        SendFramebufferUpdateRequest(client, 0, 0, client->width, client->height, FALSE);
}
int sd_vnc_wait(SDVNCClient *bridge, unsigned int timeout_microseconds) {
    /* The library's wait checks only the socket, not its read-ahead buffer. */
    return bridge->rfb->buffered ? 1 : WaitForMessage(bridge->rfb, timeout_microseconds);
}
bool sd_vnc_process_message(SDVNCClient *bridge) {
    uint8_t type;
    if (bridge->rfb->buffered) type = (uint8_t)bridge->rfb->bufoutptr[0];
    else if (recv(bridge->rfb->sock, &type, 1, MSG_PEEK) != 1) return false;
    bool success = type == rfbServerCutText ? process_clipboard(bridge) : HandleRFBServerMessage(bridge->rfb);
    if (success && type == rfbFramebufferUpdate) ++bridge->framebuffer_updates;
    return success;
}

SDVNCFramebufferInfo sd_vnc_framebuffer_info(SDVNCClient *bridge) {
    return (SDVNCFramebufferInfo){bridge->rfb->width, bridge->rfb->height, bridge->framebuffer_updates};
}

bool sd_vnc_clipboard_utf8(SDVNCClient *bridge) {
    return (bridge->clipboard_capabilities & (rfbExtendedClipboard_Text | rfbExtendedClipboard_Provide)) ==
        (rfbExtendedClipboard_Text | rfbExtendedClipboard_Provide);
}

SDVNCClipboardResult sd_vnc_send_clipboard_utf8(SDVNCClient *bridge, const uint8_t *text, size_t length) {
    if (!clipboard_allowed(bridge)) return SDVNC_CLIPBOARD_SENT; /* Disabled since enqueue. */
    if (!sd_vnc_clipboard_utf8(bridge)) return SDVNC_CLIPBOARD_UNSUPPORTED;
    if (length >= CLIPBOARD_LIMIT) return SDVNC_CLIPBOARD_TOO_LARGE;
    char *offer = malloc(length + 1);
    if (!offer) return SDVNC_CLIPBOARD_FAILED;
    if (length) memcpy(offer, text, length);
    offer[length] = 0;
    free(bridge->clipboard_offer);
    bridge->clipboard_offer = offer;
    bridge->clipboard_offer_length = length;
    if (length + 1 <= bridge->clipboard_unsolicited_limit) {
        SDVNCClipboardResult result = clipboard_provide(bridge);
        if (result != SDVNC_CLIPBOARD_SENT) {
            free(bridge->clipboard_offer); bridge->clipboard_offer = NULL;
            bridge->clipboard_offer_length = 0;
        }
        return result;
    }
    if (bridge->clipboard_capabilities & rfbExtendedClipboard_Notify)
        return clipboard_control(bridge, rfbExtendedClipboard_Notify | rfbExtendedClipboard_Text, false) ?
            SDVNC_CLIPBOARD_SENT : SDVNC_CLIPBOARD_FAILED;
    free(bridge->clipboard_offer); bridge->clipboard_offer = NULL;
    bridge->clipboard_offer_length = 0;
    return SDVNC_CLIPBOARD_UNSUPPORTED;
}
bool sd_vnc_write(SDVNCClient *bridge, const uint8_t *packet, size_t length) {
    if (length > UINT_MAX) return false;
    if (length >= 8 && packet[0] == rfbClientCutText) {
        free(bridge->clipboard_offer); bridge->clipboard_offer = NULL;
        bridge->clipboard_offer_length = 0;
        if (!clipboard_allowed(bridge)) return true;
    }
    return WriteToRFBServer(bridge->rfb, (const char *)packet, (unsigned int)length);
}
