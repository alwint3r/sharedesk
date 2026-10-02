#include "VNCBridge.h"
#include <limits.h>
#include <rfb/rfbclient.h>
#include <stdlib.h>
#include <string.h>

struct SDVNCClient {
    rfbClient *rfb;
    SDVNCCallbacks callbacks;
    void *context;
    const char *password;
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
    if (bridge->callbacks.clipboard) bridge->callbacks.clipboard(bridge->context, text, length);
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
    return HandleRFBServerMessage(bridge->rfb);
}
bool sd_vnc_write(SDVNCClient *bridge, const uint8_t *packet, size_t length) {
    if (length > UINT_MAX) return false;
    return WriteToRFBServer(bridge->rfb, (const char *)packet, (unsigned int)length);
}
