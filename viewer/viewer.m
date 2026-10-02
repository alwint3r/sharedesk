#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <IOKit/hidsystem/IOLLEvent.h>
#include <arpa/inet.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <rfb/rfbclient.h>
#include <rfb/keysym.h>
#include <signal.h>
#include <sys/socket.h>
#include <unistd.h>

#define CLIPBOARD_LIMIT (1U << 20)
#define QUEUE_LIMIT (2U << 20)

/* One app-owned worker owns LibVNCClient and its writable framebuffer. AppKit
 * owns the UI and pasteboard on the main thread. The lock protects bounded
 * outgoing packets and latest immutable snapshots, never calls into AppKit.
 * No credentials, clipboard history, preferences or reconnect policy persist. */
@interface SDSession : NSObject {
@public
    NSLock *_lock;
    NSMutableArray<NSData *> *_packets;
    NSUInteger _queuedBytes;
    BOOL _stop, _ready, _finished, _clipboardEnabled, _ioTimedOut;
    NSTimeInterval _ioDeadline; /* Monotonic time; enforced by the main-thread poll. */
    int _cancelSocket; /* Duplicate descriptor; shutdown cancels library I/O. */
    NSString *_host, *_password, *_status;
    int _port;
    uint8_t *_pixels; /* Worker-owned; LibVNCClient cleanup does not free it. */
    NSData *_frame, *_cursor, *_clipboard;
    int _width, _height, _cursorWidth, _cursorHeight, _hotX, _hotY;
}
- (instancetype)initWithHost:(NSString *)host port:(int)port password:(NSString *)password;
- (void)start;
- (void)stop;
- (void)enqueue:(NSData *)packet;
- (void)key:(uint32_t)symbol down:(BOOL)down;
- (void)pointerX:(int)x y:(int)y buttons:(int)buttons;
- (void)clipboard:(NSData *)text;
- (void)setClipboardSharing:(BOOL)enabled;
- (void)beginIOWithTimeout:(NSTimeInterval)seconds;
- (void)endIO;
- (NSDictionary *)poll; /* Main thread: check the deadline and take latest updates. */
@end

static char sessionTag;
static SDSession *sessionFor(rfbClient *client) {
    return (__bridge SDSession *)rfbClientGetClientData(client, &sessionTag);
}
static char *passwordFor(rfbClient *client) {
    const char *password = sessionFor(client)->_password.UTF8String;
    return strdup(password ? password : "");
}
static rfbBool allocateFramebuffer(rfbClient *client) {
    if (client->width < 1 || client->height < 1 || client->width > 8192 || client->height > 8192) return FALSE;
    size_t bytes = (size_t)client->width * client->height * 4;
    uint8_t *pixels = calloc(1, bytes);
    if (!pixels) return FALSE;
    SDSession *session = sessionFor(client);
    free(session->_pixels);
    session->_pixels = pixels;
    client->frameBuffer = pixels;
    return TRUE;
}
static void finishedFramebuffer(rfbClient *client) {
    SDSession *session = sessionFor(client);
    NSData *frame = [NSData dataWithBytes:client->frameBuffer length:(size_t)client->width * client->height * 4];
    [session->_lock lock];
    session->_frame = frame; /* Replace, rather than queue, stale video frames. */
    session->_width = client->width;
    session->_height = client->height;
    [session->_lock unlock];
}
static void receivedClipboard(rfbClient *client, const char *text, int length) {
    if (length < 0 || (unsigned int)length > CLIPBOARD_LIMIT || (length && memchr(text, 0, (size_t)length))) return;
    SDSession *session = sessionFor(client);
    [session->_lock lock];
    if (session->_clipboardEnabled) session->_clipboard = [NSData dataWithBytes:text length:(NSUInteger)length];
    [session->_lock unlock];
}
static void receivedCursor(rfbClient *client, int hotX, int hotY, int width, int height, int bytesPerPixel) {
    if (bytesPerPixel != 4 || width < 1 || height < 1 || width > 1024 || height > 1024 ||
        hotX < 0 || hotY < 0 || hotX >= width || hotY >= height) return;
    NSMutableData *data = [NSMutableData dataWithLength:(size_t)width * height * 4];
    uint32_t *pixels = data.mutableBytes;
    for (int i = 0; i < width * height; ++i) {
        pixels[i] = client->rcMask[i] ? (((uint32_t *)client->rcSource)[i] | 0xff000000U) : 0;
    }
    SDSession *session = sessionFor(client);
    [session->_lock lock];
    session->_cursor = data;
    session->_cursorWidth = width; session->_cursorHeight = height;
    session->_hotX = hotX; session->_hotY = hotY;
    [session->_lock unlock];
}
static rfbBool receivedCursorPosition(rfbClient *client, int x, int y) {
    /* Do not move the Mac's global pointer when someone uses Ubuntu locally. */
    (void)client; (void)x; (void)y;
    return TRUE;
}

@implementation SDSession
- (instancetype)initWithHost:(NSString *)host port:(int)port password:(NSString *)password {
    if ((self = [super init])) {
        _host = [host copy]; _port = port; _password = [password copy];
        _lock = [NSLock new]; _packets = [NSMutableArray new];
        _cancelSocket = -1; _status = @"Connecting…";
    }
    return self;
}
- (void)start {
    /* NSThread retains its target until run returns; no controller callback or
     * retain cycle is needed to keep a cancelling session alive. */
    [[[NSThread alloc] initWithTarget:self selector:@selector(run) object:nil] start];
}
- (void)stop {
    [_lock lock];
    _stop = YES;
    if (_cancelSocket >= 0) shutdown(_cancelSocket, SHUT_RDWR);
    [_lock unlock];
}
- (void)enqueue:(NSData *)packet {
    [_lock lock];
    const uint8_t *bytes = packet.bytes;
    if (_ready && !_stop && (bytes[0] != rfbClientCutText || _clipboardEnabled)) {
        NSData *last = _packets.lastObject;
        const uint8_t *previous = last.bytes;
        /* Coalesce pointer motion, never button transitions, wheel impulses,
         * clipboard messages or key releases. */
        if (packet.length == 6 && bytes[0] == rfbPointerEvent && !(bytes[1] & 0x78) &&
            last.length == 6 && previous[0] == rfbPointerEvent && previous[1] == bytes[1]) {
            [_packets removeLastObject]; _queuedBytes -= last.length;
        }
        if (_queuedBytes + packet.length > QUEUE_LIMIT || _packets.count >= 2048) {
            _status = @"Input queue full; disconnected to avoid stuck input.";
            _stop = YES;
            if (_cancelSocket >= 0) shutdown(_cancelSocket, SHUT_RDWR);
        } else {
            [_packets addObject:packet]; _queuedBytes += packet.length;
        }
    }
    [_lock unlock];
}
- (void)key:(uint32_t)symbol down:(BOOL)down {
    uint8_t packet[8] = {rfbKeyEvent, down ? 1 : 0, 0, 0};
    uint32_t wire = htonl(symbol); memcpy(packet + 4, &wire, sizeof wire);
    [self enqueue:[NSData dataWithBytes:packet length:sizeof packet]];
}
- (void)pointerX:(int)x y:(int)y buttons:(int)buttons {
    uint8_t packet[6] = {rfbPointerEvent, (uint8_t)buttons};
    uint16_t wx = htons((uint16_t)x), wy = htons((uint16_t)y);
    memcpy(packet + 2, &wx, 2); memcpy(packet + 4, &wy, 2);
    [self enqueue:[NSData dataWithBytes:packet length:sizeof packet]];
}
- (void)clipboard:(NSData *)text {
    if (text.length > CLIPBOARD_LIMIT || (text.length && memchr(text.bytes, 0, text.length))) return;
    uint8_t header[8] = {rfbClientCutText, 0, 0, 0};
    uint32_t length = htonl((uint32_t)text.length); memcpy(header + 4, &length, 4);
    NSMutableData *packet = [NSMutableData dataWithBytes:header length:sizeof header];
    [packet appendData:text];
    [self enqueue:packet];
}
- (void)setClipboardSharing:(BOOL)enabled {
    [_lock lock];
    _clipboardEnabled = enabled;
    _clipboard = nil;
    if (!enabled) {
        for (NSInteger i = (NSInteger)_packets.count - 1; i >= 0; --i) {
            NSData *packet = _packets[(NSUInteger)i];
            if (((const uint8_t *)packet.bytes)[0] == rfbClientCutText) {
                _queuedBytes -= packet.length; [_packets removeObjectAtIndex:(NSUInteger)i];
            }
        }
    }
    [_lock unlock];
}
- (void)beginIOWithTimeout:(NSTimeInterval)seconds {
    [_lock lock];
    _ioDeadline = NSProcessInfo.processInfo.systemUptime + seconds;
    [_lock unlock];
}
- (void)endIO {
    [_lock lock]; _ioDeadline = 0; [_lock unlock];
}
- (NSDictionary *)poll {
    [_lock lock];
    if (!_stop && _ioDeadline > 0 && NSProcessInfo.processInfo.systemUptime >= _ioDeadline) {
        _ioTimedOut = YES; _stop = YES; _ready = NO;
        _status = @"Network operation timed out; disconnected.";
        fprintf(stderr, "Sharedesk: network operation exceeded its elapsed-time deadline\n");
        if (_cancelSocket >= 0) shutdown(_cancelSocket, SHUT_RDWR);
    }
    NSMutableDictionary *updates = [@{@"ready": @(_ready), @"finished": @(_finished), @"status": _status} mutableCopy];
    if (_frame) {
        updates[@"frame"] = _frame; updates[@"width"] = @(_width); updates[@"height"] = @(_height); _frame = nil;
    }
    if (_cursor) {
        updates[@"cursor"] = _cursor; updates[@"cursorWidth"] = @(_cursorWidth); updates[@"cursorHeight"] = @(_cursorHeight);
        updates[@"hotX"] = @(_hotX); updates[@"hotY"] = @(_hotY); _cursor = nil;
    }
    if (_clipboard) { updates[@"clipboard"] = _clipboard; _clipboard = nil; }
    [_lock unlock];
    return updates;
}
- (void)run {
    @autoreleasepool {
        rfbClient *client = rfbGetClient(8, 3, 4);
        BOOL connected = NO, healthy = client != NULL;
        if (client) {
            rfbClientSetClientData(client, &sessionTag, (__bridge void *)self);
            client->GetPassword = passwordFor;
            client->MallocFrameBuffer = allocateFramebuffer;
            client->FinishedFrameBufferUpdate = finishedFramebuffer;
            client->GotXCutText = receivedClipboard;
            client->GotCursorShape = receivedCursor;
            client->HandleCursorPos = receivedCursorPosition;
            client->appData.useRemoteCursor = TRUE;
            client->appData.encodingsString = "zrle zlib hextile raw";
            client->appData.enableJPEG = FALSE;
            client->canHandleNewFBSize = TRUE;
            client->connectTimeout = 3;
            /* 0.9.15 counts EAGAIN retries, not elapsed time: fragmented data
             * can exhaust a five-second budget in less than a second. The app
             * instead enforces monotonic deadlines through poll()/shutdown(). */
            client->readTimeout = 0;
            client->format.bitsPerPixel = 32; client->format.depth = 24; client->format.trueColour = TRUE;
            const uint16_t endian = 1;
            client->format.bigEndian = *(const uint8_t *)&endian == 0;
            client->format.redMax = client->format.greenMax = client->format.blueMax = 255;
            client->format.redShift = 16; client->format.greenShift = 8; client->format.blueShift = 0;
            uint32_t schemes[] = {rfbVncAuth}; SetClientAuthSchemes(client, schemes, 1);
            healthy = ConnectToRFBServer(client, _host.UTF8String, _port);
            if (healthy) {
                [_lock lock];
                _cancelSocket = dup(client->sock);
                if (_stop && _cancelSocket >= 0) shutdown(_cancelSocket, SHUT_RDWR);
                healthy = _cancelSocket >= 0 && !_stop;
                [_lock unlock];
            }
            /* Public stages preserve ownership on failure. rfbInitClient()
             * instead frees the client on failed initialization. */
            if (healthy) {
                [self beginIOWithTimeout:5];
                healthy = InitialiseRFBConnection(client) && client->authScheme == rfbVncAuth;
                [self endIO];
            }
            _password = nil;
            if (healthy) {
                [self beginIOWithTimeout:5];
                client->width = client->si.framebufferWidth; client->height = client->si.framebufferHeight;
                client->updateRect.x = client->updateRect.y = 0;
                client->updateRect.w = client->width; client->updateRect.h = client->height;
                client->isUpdateRectManagedByLib = TRUE;
                healthy = allocateFramebuffer(client) && SetFormatAndEncodings(client) &&
                    SendFramebufferUpdateRequest(client, 0, 0, client->width, client->height, FALSE);
                [self endIO];
            }
            [_lock lock];
            if (healthy && !_stop) {
                _ready = YES; connected = YES; _status = @"Connected. Control = Ctrl; Command = Super. Terminal paste: Ctrl+Shift+V.";
            }
            [_lock unlock];
            while (healthy && connected) {
                @autoreleasepool {
                    [_lock lock];
                    BOOL stopping = _stop;
                    NSArray<NSData *> *packets = [_packets copy]; [_packets removeAllObjects]; _queuedBytes = 0;
                    [_lock unlock];
                    if (stopping) break;
                    for (NSData *packet in packets) {
                        [_lock lock];
                        BOOL skip = _stop || (((const uint8_t *)packet.bytes)[0] == rfbClientCutText && !_clipboardEnabled);
                        [_lock unlock];
                        if (skip) continue;
                        [self beginIOWithTimeout:20];
                        healthy = WriteToRFBServer(client, packet.bytes, (unsigned int)packet.length);
                        [self endIO];
                        if (!healthy) break;
                    }
                    if (!healthy) break;
                    /* WaitForMessage checks only the socket, not bytes already
                     * read ahead by LibVNCClient. Drain those without waiting
                     * for unrelated future screen or clipboard traffic. */
                    int ready = client->buffered ? 1 : WaitForMessage(client, 10000);
                    if (ready < 0) healthy = NO;
                    else if (ready > 0) {
                        [self beginIOWithTimeout:20];
                        healthy = HandleRFBServerMessage(client);
                        [self endIO];
                    }
                }
            }
            [_lock lock];
            if (_cancelSocket >= 0) { close(_cancelSocket); _cancelSocket = -1; }
            [_lock unlock];
            rfbClientCleanup(client);
        }
        free(_pixels); _pixels = NULL; _password = nil;
        [_lock lock];
        if (!_stop) _status = connected ? @"Connection closed or timed out." : @"Connection or authentication failed. Check address, port and password.";
        else if (!_ioTimedOut && ![_status hasPrefix:@"Input queue full"]) _status = @"Disconnected.";
        _ready = NO; _finished = YES; [_packets removeAllObjects]; _queuedBytes = 0;
        _frame = _cursor = _clipboard = nil;
        [_lock unlock];
    }
}
@end

static CGImageRef imageForData(NSData *data, int width, int height, CGBitmapInfo bitmap) {
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef color = CGColorSpaceCreateDeviceRGB();
    CGImageRef image = CGImageCreate((size_t)width, (size_t)height, 8, 32, (size_t)width * 4,
        color, bitmap | kCGBitmapByteOrder32Little, provider, NULL, false, kCGRenderingIntentDefault);
    CGColorSpaceRelease(color); CGDataProviderRelease(provider);
    return image; /* Caller owns this reference. Provider retains the NSData. */
}

@class SDController;
@interface SDDesktopView : NSView {
    CGImageRef _image;
    NSCursor *_cursor;
    NSTrackingArea *_tracking;
    uint32_t _held[256]; /* Key-down symbols, not key-up's changed characters. */
    int _buttons, _lastX, _lastY;
    CGFloat _scrollX, _scrollY;
}
@property(nonatomic, strong) SDSession *session;
@property(nonatomic, weak) SDController *controller;
@property(nonatomic) BOOL inputEnabled;
- (void)clearDesktop;
- (void)showFrame:(NSData *)data width:(int)width height:(int)height;
- (void)showCursor:(NSData *)data width:(int)width height:(int)height hotX:(int)x hotY:(int)y;
- (void)releaseInput;
@end
@interface SDController : NSObject <NSApplicationDelegate, NSWindowDelegate> {
@public
    NSWindow *_window;
    NSTextField *_hostField, *_portField, *_statusField;
    NSSecureTextField *_passwordField;
    NSButton *_connectButton, *_clipboardButton, *_sendButton;
    SDDesktopView *_desktop;
    SDSession *_session;
    NSTimer *_timer;
    NSPasteboard *_pasteboard; /* Main-thread only. Tests can supply a private board. */
    NSInteger _pasteboardChange;
    BOOL _ready, _terminating;
    NSTimeInterval _nextClipboardPoll;
}
- (void)syncClipboard:(BOOL)force;
@end

@implementation SDDesktopView
- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)dealloc { if (_image) CGImageRelease(_image); }
- (void)clearDesktop {
    [self releaseInput];
    self.inputEnabled = NO;
    if (_image) { CGImageRelease(_image); _image = NULL; }
    _cursor = nil; self.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self];
}
- (NSRect)desktopRect {
    if (!_image) return NSZeroRect;
    CGFloat width = CGImageGetWidth(_image), height = CGImageGetHeight(_image);
    CGFloat scale = fmin(self.bounds.size.width / width, self.bounds.size.height / height);
    return NSMakeRect((self.bounds.size.width - width * scale) / 2,
                      (self.bounds.size.height - height * scale) / 2, width * scale, height * scale);
}
- (void)showFrame:(NSData *)data width:(int)width height:(int)height {
    CGImageRef next = imageForData(data, width, height, (CGBitmapInfo)kCGImageAlphaNoneSkipFirst);
    if (!next) return;
    if (_image) CGImageRelease(_image);
    _image = next; self.needsDisplay = YES;
    [self.window invalidateCursorRectsForView:self];
}
- (void)showCursor:(NSData *)data width:(int)width height:(int)height hotX:(int)x hotY:(int)y {
    CGImageRef image = imageForData(data, width, height, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst);
    if (!image) return;
    NSImage *cursorImage = [[NSImage alloc] initWithCGImage:image size:NSMakeSize(width, height)];
    CGImageRelease(image);
    _cursor = [[NSCursor alloc] initWithImage:cursorImage hotSpot:NSMakePoint(x, y)];
    [self.window invalidateCursorRectsForView:self];
}
- (void)resetCursorRects {
    [self addCursorRect:[self desktopRect] cursor:_cursor ? _cursor : NSCursor.arrowCursor];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_tracking) [self removeTrackingArea:_tracking];
    _tracking = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved | NSTrackingActiveInKeyWindow | NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_tracking];
}
- (void)drawRect:(NSRect)dirty {
    (void)dirty;
    [NSColor.blackColor setFill]; NSRectFill(self.bounds);
    if (!_image) {
        NSString *label = @"Connect to your Ubuntu desktop";
        NSDictionary *attributes = @{NSFontAttributeName: [NSFont systemFontOfSize:18], NSForegroundColorAttributeName: NSColor.lightGrayColor};
        NSSize size = [label sizeWithAttributes:attributes];
        [label drawAtPoint:NSMakePoint((self.bounds.size.width - size.width) / 2, (self.bounds.size.height - size.height) / 2) withAttributes:attributes];
        return;
    }
    NSRect target = [self desktopRect];
    CGContextRef context = NSGraphicsContext.currentContext.CGContext;
    CGContextSaveGState(context);
    CGContextTranslateCTM(context, target.origin.x, target.origin.y + target.size.height);
    CGContextScaleCTM(context, 1, -1);
    CGContextSetInterpolationQuality(context, kCGInterpolationLow);
    CGContextDrawImage(context, CGRectMake(0, 0, target.size.width, target.size.height), _image);
    CGContextRestoreGState(context);
}
- (BOOL)locate:(NSEvent *)event clamp:(BOOL)clamp {
    if (!_image || !self.inputEnabled) return NO;
    NSRect rect = [self desktopRect];
    if (rect.size.width <= 0 || rect.size.height <= 0) return NO;
    NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (!clamp && !NSPointInRect(point, rect)) return NO;
    _lastX = (int)fmax(0, fmin(CGImageGetWidth(_image) - 1, floor((point.x - rect.origin.x) * CGImageGetWidth(_image) / rect.size.width)));
    _lastY = (int)fmax(0, fmin(CGImageGetHeight(_image) - 1, floor((point.y - rect.origin.y) * CGImageGetHeight(_image) / rect.size.height)));
    return YES;
}
- (void)mouseMoved:(NSEvent *)event {
    if ([self locate:event clamp:_buttons != 0]) [self.session pointerX:_lastX y:_lastY buttons:_buttons];
}
- (void)mouseDown:(NSEvent *)event {
    [self.window makeFirstResponder:self];
    if (![self locate:event clamp:NO]) return;
    [self.controller syncClipboard:NO]; /* Also precede mouse-driven paste actions. */
    int bit = event.buttonNumber == 0 ? 1 : event.buttonNumber == 1 ? 4 : event.buttonNumber == 2 ? 2 : 0;
    [self syncModifiers:event];
    _buttons |= bit; [self.session pointerX:_lastX y:_lastY buttons:_buttons];
}
- (void)mouseUp:(NSEvent *)event {
    if (![self locate:event clamp:YES]) return;
    int bit = event.buttonNumber == 0 ? 1 : event.buttonNumber == 1 ? 4 : event.buttonNumber == 2 ? 2 : 0;
    _buttons &= ~bit; [self.session pointerX:_lastX y:_lastY buttons:_buttons];
}
- (void)rightMouseDown:(NSEvent *)event { [self mouseDown:event]; }
- (void)otherMouseDown:(NSEvent *)event { [self mouseDown:event]; }
- (void)rightMouseUp:(NSEvent *)event { [self mouseUp:event]; }
- (void)otherMouseUp:(NSEvent *)event { [self mouseUp:event]; }
- (void)mouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)rightMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)otherMouseDragged:(NSEvent *)event { [self mouseMoved:event]; }
- (void)scrollWheel:(NSEvent *)event {
    if (![self locate:event clamp:NO]) return;
    CGFloat divisor = event.hasPreciseScrollingDeltas ? 10 : 1;
    _scrollY = fmax(-10, fmin(10, _scrollY + event.scrollingDeltaY / divisor));
    _scrollX = fmax(-10, fmin(10, _scrollX + event.scrollingDeltaX / divisor));
    for (int count = 0; count < 10 && (fabs(_scrollY) >= 1 || fabs(_scrollX) >= 1); ++count) {
        int bit;
        if (fabs(_scrollY) >= 1) { bit = _scrollY > 0 ? 8 : 16; _scrollY += _scrollY > 0 ? -1 : 1; }
        else { bit = _scrollX > 0 ? 32 : 64; _scrollX += _scrollX > 0 ? -1 : 1; }
        [self.session pointerX:_lastX y:_lastY buttons:_buttons | bit];
        [self.session pointerX:_lastX y:_lastY buttons:_buttons];
    }
}
- (void)syncModifiers:(NSEvent *)event {
    if (!self.inputEnabled) return;
    /* Device-specific bits distinguish both sides and restore modifiers held
     * before the window gained focus. Lock and Fn state are never forwarded. */
    const struct { unsigned short code; uint32_t symbol; NSUInteger mask; } modifiers[] = {
        {kVK_Shift, XK_Shift_L, NX_DEVICELSHIFTKEYMASK}, {kVK_RightShift, XK_Shift_R, NX_DEVICERSHIFTKEYMASK},
        {kVK_Control, XK_Control_L, NX_DEVICELCTLKEYMASK}, {kVK_RightControl, XK_Control_R, NX_DEVICERCTLKEYMASK},
        {kVK_Option, XK_Alt_L, NX_DEVICELALTKEYMASK}, {kVK_RightOption, XK_Alt_R, NX_DEVICERALTKEYMASK},
        {kVK_Command, XK_Super_L, NX_DEVICELCMDKEYMASK}, {kVK_RightCommand, XK_Super_R, NX_DEVICERCMDKEYMASK}
    };
    for (NSUInteger i = 0; i < sizeof modifiers / sizeof *modifiers; ++i) {
        BOOL down = (event.modifierFlags & modifiers[i].mask) != 0;
        if (down != (_held[modifiers[i].code] != 0)) {
            [self.session key:modifiers[i].symbol down:down];
            _held[modifiers[i].code] = down ? modifiers[i].symbol : 0;
        }
    }
}
- (void)flagsChanged:(NSEvent *)event { [self syncModifiers:event]; }
- (void)keyDown:(NSEvent *)event {
    if (!self.inputEnabled || event.keyCode >= 256 || event.isARepeat || _held[event.keyCode]) return;
    [self.controller syncClipboard:NO]; /* Queue new clipboard data before paste keys. */
    [self syncModifiers:event];
    uint32_t symbol = 0;
    switch (event.keyCode) {
        case kVK_Return: case kVK_ANSI_KeypadEnter: symbol = XK_Return; break;
        case kVK_Tab: symbol = XK_Tab; break;
        case kVK_Delete: symbol = XK_BackSpace; break;
        case kVK_ForwardDelete: symbol = XK_Delete; break;
        case kVK_Escape: symbol = XK_Escape; break;
        case kVK_LeftArrow: symbol = XK_Left; break;
        case kVK_RightArrow: symbol = XK_Right; break;
        case kVK_UpArrow: symbol = XK_Up; break;
        case kVK_DownArrow: symbol = XK_Down; break;
        case kVK_Home: symbol = XK_Home; break;
        case kVK_End: symbol = XK_End; break;
        case kVK_PageUp: symbol = XK_Page_Up; break;
        case kVK_PageDown: symbol = XK_Page_Down; break;
        case kVK_F1: symbol = XK_F1; break; case kVK_F2: symbol = XK_F2; break;
        case kVK_F3: symbol = XK_F3; break; case kVK_F4: symbol = XK_F4; break;
        case kVK_F5: symbol = XK_F5; break; case kVK_F6: symbol = XK_F6; break;
        case kVK_F7: symbol = XK_F7; break; case kVK_F8: symbol = XK_F8; break;
        case kVK_F9: symbol = XK_F9; break; case kVK_F10: symbol = XK_F10; break;
        case kVK_F11: symbol = XK_F11; break; case kVK_F12: symbol = XK_F12; break;
        default: break;
    }
    if (!symbol) {
        BOOL shortcut = (event.modifierFlags & (NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand)) != 0;
        NSString *characters = shortcut ? event.charactersIgnoringModifiers : event.characters;
        if (characters.length != 1) return; /* Initial scope: direct keys, not IME composition. */
        unichar character = [characters characterAtIndex:0];
        if (!character || (character >= 0xd800 && character <= 0xdfff) || character >= 0xf700) return;
        symbol = character <= 255 ? character : 0x01000000U | character;
    }
    _held[event.keyCode] = symbol; [self.session key:symbol down:YES];
}
- (void)keyUp:(NSEvent *)event {
    if (!self.inputEnabled) return;
    if (event.keyCode < 256 && _held[event.keyCode]) {
        [self.session key:_held[event.keyCode] down:NO]; _held[event.keyCode] = 0;
    }
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
    if (self.window.firstResponder == self && (event.modifierFlags & NSEventModifierFlagCommand)) {
        NSString *key = event.charactersIgnoringModifiers.lowercaseString;
        if (![key isEqualToString:@"q"] && ![key isEqualToString:@"w"]) { [self keyDown:event]; return YES; }
    }
    return [super performKeyEquivalent:event];
}
- (void)releaseInput {
    for (int code = 0; code < 256; ++code) if (_held[code]) { [self.session key:_held[code] down:NO]; _held[code] = 0; }
    if (_buttons) [self.session pointerX:_lastX y:_lastY buttons:0];
    _buttons = 0; _scrollX = _scrollY = 0;
}
- (BOOL)resignFirstResponder { [self releaseInput]; return [super resignFirstResponder]; }
@end

@implementation SDController
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    (void)notification;
    NSMenu *menu = [NSMenu new];
    NSMenuItem *appItem = [NSMenuItem new]; [menu addItem:appItem];
    NSMenu *appMenu = [NSMenu new];
    [appMenu addItemWithTitle:@"Close Window" action:@selector(performClose:) keyEquivalent:@"w"];
    [appMenu addItem:NSMenuItem.separatorItem];
    [appMenu addItemWithTitle:@"Quit Sharedesk" action:@selector(terminate:) keyEquivalent:@"q"]; appItem.submenu = appMenu;
    NSMenuItem *editItem = [NSMenuItem new]; editItem.title = @"Edit"; [menu addItem:editItem];
    NSMenu *edit = [[NSMenu alloc] initWithTitle:@"Edit"];
    [edit addItemWithTitle:@"Cut" action:@selector(cut:) keyEquivalent:@"x"];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"]; editItem.submenu = edit;
    NSApp.mainMenu = menu;
    _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1024, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    _window.title = @"Sharedesk"; _window.minSize = NSMakeSize(800, 480); _window.delegate = self;
    _window.releasedWhenClosed = NO; _window.restorable = NO; _window.acceptsMouseMovedEvents = YES;
    _hostField = [NSTextField textFieldWithString:@""]; _hostField.placeholderString = @"Tailscale IPv4";
    _portField = [NSTextField textFieldWithString:@"5901"];
    _passwordField = [NSSecureTextField new]; _passwordField.placeholderString = @"VNC password";
    _connectButton = [NSButton buttonWithTitle:@"Connect" target:self action:@selector(connect:)];
    NSStackView *connection = [NSStackView stackViewWithViews:@[[NSTextField labelWithString:@"Host"], _hostField,
        [NSTextField labelWithString:@"Port"], _portField, _passwordField, _connectButton]];
    connection.orientation = NSUserInterfaceLayoutOrientationHorizontal; connection.spacing = 8;
    [_hostField.widthAnchor constraintGreaterThanOrEqualToConstant:220].active = YES;
    [_portField.widthAnchor constraintEqualToConstant:60].active = YES;
    [_passwordField.widthAnchor constraintGreaterThanOrEqualToConstant:150].active = YES;
    _clipboardButton = [NSButton checkboxWithTitle:@"Share text clipboard (Latin-1)" target:self action:@selector(clipboardChanged:)];
    _sendButton = [NSButton buttonWithTitle:@"Send Clipboard" target:self action:@selector(sendClipboard:)]; _sendButton.enabled = NO;
    NSStackView *options = [NSStackView stackViewWithViews:@[_clipboardButton, _sendButton]];
    options.orientation = NSUserInterfaceLayoutOrientationHorizontal; options.spacing = 12;
    _desktop = [SDDesktopView new]; _desktop.controller = self;
    [_desktop setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationVertical];
    _statusField = [NSTextField labelWithString:@"Private VNC connection. Clipboard is off until you enable it. Passwords are not saved."];
    _statusField.font = [NSFont systemFontOfSize:11];
    NSStackView *stack = [NSStackView stackViewWithViews:@[connection, options, _desktop, _statusField]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.alignment = NSLayoutAttributeLeading; stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [_window.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:_window.contentView.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:_window.contentView.trailingAnchor constant:-12],
        [stack.topAnchor constraintEqualToAnchor:_window.contentView.topAnchor constant:12],
        [stack.bottomAnchor constraintEqualToAnchor:_window.contentView.bottomAnchor constant:-12],
        [_desktop.widthAnchor constraintEqualToAnchor:stack.widthAnchor], [_desktop.heightAnchor constraintGreaterThanOrEqualToConstant:240]]];
    _pasteboard = NSPasteboard.generalPasteboard; _pasteboardChange = _pasteboard.changeCount;
    _timer = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(poll:) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:_timer forMode:NSRunLoopCommonModes];
    [_window center]; [_window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES];
    [_window makeFirstResponder:_hostField];
}
- (void)connect:(id)sender {
    (void)sender;
    if (_session) { [_desktop releaseInput]; [_session stop]; _connectButton.enabled = NO; return; }
    NSString *host = [_hostField.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    struct in_addr address;
    uint32_t ip = inet_pton(AF_INET, host.UTF8String, &address) == 1 ? ntohl(address.s_addr) : 0;
    NSScanner *scanner = [NSScanner scannerWithString:_portField.stringValue]; int port;
    NSString *password = _passwordField.stringValue;
    NSData *ascii = [password dataUsingEncoding:NSASCIIStringEncoding allowLossyConversion:NO];
    BOOL validPassword = ascii.length >= 1 && ascii.length <= 8;
    for (NSUInteger i = 0; i < ascii.length; ++i) if (((const uint8_t *)ascii.bytes)[i] < 33 || ((const uint8_t *)ascii.bytes)[i] > 126) validPassword = NO;
    if (((ip & 0xffc00000U) != 0x64400000U && (ip & 0xff000000U) != 0x7f000000U) ||
        ![scanner scanInt:&port] || !scanner.isAtEnd || port < 1 || port > 65535 || !validPassword) {
        _statusField.stringValue = @"Use a Tailscale/loopback IPv4, port 1–65535 and a 1–8 character ASCII VNC password."; return;
    }
    [_desktop clearDesktop];
    _session = [[SDSession alloc] initWithHost:host port:port password:password]; _desktop.session = _session;
    [_session setClipboardSharing:_clipboardButton.state == NSControlStateValueOn];
    _passwordField.stringValue = @"";
    _hostField.enabled = _portField.enabled = _passwordField.enabled = NO;
    _connectButton.title = @"Disconnect"; _statusField.stringValue = @"Connecting…";
    _pasteboardChange = _pasteboard.changeCount; /* Never export an old clipboard on connect. */
    [_session start]; [_window makeFirstResponder:_desktop];
}
- (void)clipboardChanged:(id)sender {
    (void)sender;
    [_session setClipboardSharing:_clipboardButton.state == NSControlStateValueOn];
    _pasteboardChange = _pasteboard.changeCount;
    _sendButton.enabled = _ready && _clipboardButton.state == NSControlStateValueOn;
    if (_ready) [_window makeFirstResponder:_desktop];
}
- (void)sendClipboard:(id)sender {
    (void)sender; [self syncClipboard:YES];
    if (_ready) [_window makeFirstResponder:_desktop];
}
- (void)syncClipboard:(BOOL)force {
    if (!_ready || _clipboardButton.state != NSControlStateValueOn) return;
    NSInteger change = _pasteboard.changeCount;
    if (!force && change == _pasteboardChange) return;
    _pasteboardChange = change;
    NSString *text = [_pasteboard stringForType:NSPasteboardTypeString];
    if (!text) { if (force) _statusField.stringValue = @"No text is available on the Mac clipboard."; return; }
    NSData *data = [text dataUsingEncoding:NSISOLatin1StringEncoding allowLossyConversion:NO];
    if (!data || data.length > CLIPBOARD_LIMIT || (data.length && memchr(data.bytes, 0, data.length))) {
        _statusField.stringValue = @"Clipboard was not sent: use Latin-1 text up to 1 MiB, without NUL bytes."; return;
    }
    [_session clipboard:data]; _statusField.stringValue = @"Mac clipboard queued for Ubuntu. Paste there with the application's Ubuntu shortcut.";
}
- (void)poll:(NSTimer *)timer {
    (void)timer;
    if (!_session) return;
    NSDictionary *updates = [_session poll];
    BOOL wasReady = _ready; _ready = [updates[@"ready"] boolValue];
    _desktop.inputEnabled = _ready;
    if (_ready && !wasReady) {
        _pasteboardChange = _pasteboard.changeCount;
        [_window makeFirstResponder:_desktop];
    }
    if (_ready != wasReady || [updates[@"finished"] boolValue]) _statusField.stringValue = updates[@"status"];
    if (updates[@"frame"]) [_desktop showFrame:updates[@"frame"] width:[updates[@"width"] intValue] height:[updates[@"height"] intValue]];
    if (updates[@"cursor"]) [_desktop showCursor:updates[@"cursor"] width:[updates[@"cursorWidth"] intValue]
        height:[updates[@"cursorHeight"] intValue] hotX:[updates[@"hotX"] intValue] hotY:[updates[@"hotY"] intValue]];
    if (updates[@"clipboard"] && _clipboardButton.state == NSControlStateValueOn && _ready) {
        NSString *text = [[NSString alloc] initWithData:updates[@"clipboard"] encoding:NSISOLatin1StringEncoding];
        if (text) {
            [_pasteboard clearContents];
            BOOL written = [_pasteboard setString:text forType:NSPasteboardTypeString];
            _pasteboardChange = _pasteboard.changeCount; /* Suppress our own pasteboard echo. */
            _statusField.stringValue = written ? @"Ubuntu text received on the Mac clipboard." : @"Could not write the received text to the Mac clipboard.";
        }
    }
    _sendButton.enabled = _ready && _clipboardButton.state == NSControlStateValueOn;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if (_ready && NSApp.isActive && now >= _nextClipboardPoll) { _nextClipboardPoll = now + 0.2; [self syncClipboard:NO]; }
    if ([updates[@"finished"] boolValue]) {
        [_desktop clearDesktop]; _desktop.session = nil; _session = nil;
        _ready = NO; _sendButton.enabled = NO;
        _hostField.enabled = _portField.enabled = _passwordField.enabled = YES;
        _connectButton.title = @"Connect"; _connectButton.enabled = YES;
        if (_terminating) [NSApp replyToApplicationShouldTerminate:YES];
    }
}
- (void)windowDidResignKey:(NSNotification *)notification { (void)notification; [_desktop releaseInput]; }
- (void)windowWillClose:(NSNotification *)notification { (void)notification; [_desktop releaseInput]; [_session stop]; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    (void)notification; [_timer invalidate]; _timer = nil;
}
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { (void)sender; return YES; }
- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender {
    (void)sender;
    if (_session) { _terminating = YES; [_desktop releaseInput]; [_session stop]; return NSTerminateLater; }
    return NSTerminateNow;
}
@end

int main(int argc, const char **argv) {
    (void)argc; (void)argv;
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        NSApplication *app = NSApplication.sharedApplication;
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        __attribute__((objc_precise_lifetime)) SDController *controller = [SDController new];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
