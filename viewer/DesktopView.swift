import AppKit
import Carbon
import SharedeskVNC

// Native scrollbars move the document. Its image scale is shared by drawing
// and input mapping; wheel input over the canvas remains remote input.
@MainActor
final class DesktopScrollView: NSScrollView {
    private(set) var zoomFactor: CGFloat = 1
    private var resizeCenter: NSPoint?

    override func setFrameSize(_ newSize: NSSize) {
        if newSize != frame.size, resizeCenter == nil { resizeCenter = remoteCenter }
        super.setFrameSize(newSize)
    }

    func setZoom(_ factor: CGFloat) {
        precondition(factor.isFinite && factor >= 1)
        let center = remoteCenter
        zoomFactor = factor
        needsLayout = true
        layoutSubtreeIfNeeded()
        if let center { scrollToRemoteCenter(center) }
    }

    fileprivate var remoteCenter: NSPoint? {
        guard let desktop = documentView as? DesktopView else { return nil }
        let image = desktop.desktopRect
        guard image.width > 0, image.height > 0 else { return nil }
        return NSPoint(x: (contentView.bounds.midX - image.minX) / image.width,
                       y: (contentView.bounds.midY - image.minY) / image.height)
    }

    fileprivate func scrollToRemoteCenter(_ center: NSPoint) {
        guard let desktop = documentView as? DesktopView else { return }
        let image = desktop.desktopRect
        let origin = NSPoint(x: image.minX + center.x * image.width - contentView.bounds.width / 2,
                             y: image.minY + center.y * image.height - contentView.bounds.height / 2)
        let proposed = NSRect(origin: origin, size: contentView.bounds.size)
        contentView.scroll(to: contentView.constrainBoundsRect(proposed).origin)
        reflectScrolledClipView(contentView)
        window?.invalidateCursorRects(for: desktop)
    }

    override func layout() {
        let center = resizeCenter ?? remoteCenter
        resizeCenter = nil
        super.layout()
        guard let desktop = documentView as? DesktopView, bounds.width > 16, bounds.height > 16 else { return }
        var imageSize = NSSize.zero
        if let image = desktop.framebuffer {
            let fit = min((bounds.width - 16) / CGFloat(image.width), (bounds.height - 16) / CGFloat(image.height))
            desktop.imageScale = fit * zoomFactor
            imageSize = NSSize(width: CGFloat(image.width) * desktop.imageScale,
                               height: CGFloat(image.height) * desktop.imageScale)
        }
        // Decide both scrollbar axes together, including space for legacy bars.
        // This avoids Fit/scrollbar feedback loops and large empty pan regions.
        let bar = scrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
        var horizontal = imageSize.width + 16 > bounds.width + 0.01
        var vertical = imageSize.height + 16 > bounds.height + 0.01
        for _ in 0..<2 {
            horizontal = horizontal || imageSize.width + 16 > bounds.width - (vertical ? bar : 0) + 0.01
            vertical = vertical || imageSize.height + 16 > bounds.height - (horizontal ? bar : 0) + 0.01
        }
        hasHorizontalScroller = horizontal
        hasVerticalScroller = vertical
        tile()
        let size = NSSize(width: max(contentView.frame.width, imageSize.width + 16),
                          height: max(contentView.frame.height, imageSize.height + 16))
        if desktop.frame.size != size { desktop.setFrameSize(size) }
        if let center { scrollToRemoteCenter(center) }
        desktop.needsDisplay = true
        window?.invalidateCursorRects(for: desktop)
    }

    override func scrollWheel(with event: NSEvent) {
        // Do not let NSScrollView turn Ubuntu wheel input into local panning.
        documentView?.scrollWheel(with: event)
    }
}

@MainActor
final class DesktopView: NSView {
    var session: VNCSession?
    weak var controller: ViewerApplication?
    var inputEnabled = false
    fileprivate var framebuffer: CGImage?
    fileprivate var imageScale: CGFloat = 1
    private var remoteCursor: NSCursor?
    private var pointerTracking: NSTrackingArea?
    private var heldKeys: [UInt32] = Array(repeating: 0, count: 256)
    private var buttons: UInt8 = 0
    private var lastX = 0
    private var lastY = 0
    private var scrollX: CGFloat = 0
    private var scrollY: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    var hasFramebuffer: Bool { framebuffer != nil }

    func clearDesktop() {
        releaseInput()
        inputEnabled = false
        framebuffer = nil
        remoteCursor = nil
        (enclosingScrollView as? DesktopScrollView)?.setZoom(1)
        enclosingScrollView?.contentView.scroll(to: .zero)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    fileprivate var desktopRect: NSRect {
        guard let framebuffer else { return .zero }
        let width = CGFloat(framebuffer.width) * imageScale
        let height = CGFloat(framebuffer.height) * imageScale
        // Fit leaves eight points around the image; zoomed documents keep the
        // same edge margin and centre any axis that needs no local scrolling.
        return NSRect(x: bounds.midX - width / 2, y: bounds.midY - height / 2, width: width, height: height)
    }

    func showFrame(_ frame: PixelFrame) {
        guard let image = frame.image(alpha: .noneSkipFirst) else { return }
        let resized = framebuffer?.width != image.width || framebuffer?.height != image.height
        let viewport = enclosingScrollView as? DesktopScrollView
        let center = resized ? viewport?.remoteCenter : nil
        framebuffer = image
        if resized {
            viewport?.needsLayout = true
            viewport?.layoutSubtreeIfNeeded()
            if let center { viewport?.scrollToRemoteCenter(center) }
        }
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    func showCursor(_ cursor: RemoteCursor) {
        guard let image = cursor.frame.image(alpha: .premultipliedFirst) else { return }
        remoteCursor = NSCursor(image: NSImage(cgImage: image, size: NSSize(width: cursor.frame.width, height: cursor.frame.height)),
                                hotSpot: NSPoint(x: cursor.hotX, y: cursor.hotY))
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(desktopRect, cursor: remoteCursor ?? .arrow)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTracking { removeTrackingArea(pointerTracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        pointerTracking = area
        addTrackingArea(area)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()
        guard let framebuffer else {
            NSColor(calibratedWhite: 0.075, alpha: 1).setFill()
            bounds.fill()
            let center = NSPoint(x: bounds.midX, y: bounds.midY)
            if let icon = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 42, weight: .light)
                    .applying(.init(hierarchicalColor: NSColor(calibratedWhite: 0.88, alpha: 1)))) {
                icon.draw(in: NSRect(x: center.x - 30, y: center.y - 65, width: 60, height: 48),
                          from: .zero, operation: .sourceOver, fraction: 0.55, respectFlipped: true, hints: nil)
            }
            let title = "Your Ubuntu desktop" as NSString
            let titleStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 19, weight: .medium),
                                                            .foregroundColor: NSColor(calibratedWhite: 0.88, alpha: 1)]
            let titleSize = title.size(withAttributes: titleStyle)
            title.draw(at: NSPoint(x: center.x - titleSize.width / 2, y: center.y), withAttributes: titleStyle)
            let hint = "Choose a profile or enter a host above, then connect." as NSString
            let hintStyle: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12),
                                                           .foregroundColor: NSColor(calibratedWhite: 0.6, alpha: 1)]
            let hintSize = hint.size(withAttributes: hintStyle)
            hint.draw(at: NSPoint(x: center.x - hintSize.width / 2, y: center.y + 30), withAttributes: hintStyle)
            return
        }
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let target = desktopRect
        context.saveGState()
        context.translateBy(x: target.minX, y: target.maxY)
        context.scaleBy(x: 1, y: -1)
        context.interpolationQuality = .low
        context.draw(framebuffer, in: CGRect(origin: .zero, size: target.size))
        context.restoreGState()
    }

    private func locate(_ event: NSEvent, clamp: Bool) -> Bool {
        guard inputEnabled, let framebuffer else { return false }
        let rect = desktopRect
        guard rect.width > 0, rect.height > 0 else { return false }
        let point = convert(event.locationInWindow, from: nil)
        guard clamp || (NSPointInRect(point, rect) && NSPointInRect(point, visibleRect)) else { return false }
        lastX = Int(max(0, min(CGFloat(framebuffer.width - 1), floor((point.x - rect.minX) * CGFloat(framebuffer.width) / rect.width))))
        lastY = Int(max(0, min(CGFloat(framebuffer.height - 1), floor((point.y - rect.minY) * CGFloat(framebuffer.height) / rect.height))))
        return true
    }

    override func mouseMoved(with event: NSEvent) {
        if locate(event, clamp: buttons != 0) { session?.sendPointer(x: lastX, y: lastY, buttons: buttons) }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        guard locate(event, clamp: false) else { return }
        controller?.syncClipboard(force: false) // Clipboard precedes mouse-driven paste.
        let bit: UInt8 = switch event.buttonNumber { case 0: 1; case 1: 4; case 2: 2; default: 0 }
        syncModifiers(event)
        buttons |= bit
        session?.sendPointer(x: lastX, y: lastY, buttons: buttons)
    }

    override func mouseUp(with event: NSEvent) {
        guard locate(event, clamp: true) else { return }
        let bit: UInt8 = switch event.buttonNumber { case 0: 1; case 1: 4; case 2: 2; default: 0 }
        buttons &= ~bit
        session?.sendPointer(x: lastX, y: lastY, buttons: buttons)
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func otherMouseDown(with event: NSEvent) { mouseDown(with: event) }
    override func rightMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func otherMouseUp(with event: NSEvent) { mouseUp(with: event) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func rightMouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func otherMouseDragged(with event: NSEvent) { mouseMoved(with: event) }

    override func scrollWheel(with event: NSEvent) {
        guard locate(event, clamp: false) else { return }
        let divisor: CGFloat = event.hasPreciseScrollingDeltas ? 10 : 1
        scrollY = max(-10, min(10, scrollY + event.scrollingDeltaY / divisor))
        scrollX = max(-10, min(10, scrollX + event.scrollingDeltaX / divisor))
        for _ in 0..<10 {
            guard abs(scrollY) >= 1 || abs(scrollX) >= 1 else { break }
            let bit: UInt8
            if abs(scrollY) >= 1 { bit = scrollY > 0 ? 8 : 16; scrollY += scrollY > 0 ? -1 : 1 }
            else { bit = scrollX > 0 ? 32 : 64; scrollX += scrollX > 0 ? -1 : 1 }
            session?.sendPointer(x: lastX, y: lastY, buttons: buttons | bit)
            session?.sendPointer(x: lastX, y: lastY, buttons: buttons)
        }
    }

    private func syncModifiers(_ event: NSEvent) {
        guard inputEnabled else { return }
        // Side-specific bits handle both Shifts and keys held before focus.
        // Caps/Num/Scroll Lock and Fn never change the host's lock state.
        let modifiers: [(code: Int, symbol: UInt32, mask: UInt)] = [
            (kVK_Shift, UInt32(XK_Shift_L), UInt(NX_DEVICELSHIFTKEYMASK)),
            (kVK_RightShift, UInt32(XK_Shift_R), UInt(NX_DEVICERSHIFTKEYMASK)),
            (kVK_Control, UInt32(XK_Control_L), UInt(NX_DEVICELCTLKEYMASK)),
            (kVK_RightControl, UInt32(XK_Control_R), UInt(NX_DEVICERCTLKEYMASK)),
            (kVK_Option, UInt32(XK_Alt_L), UInt(NX_DEVICELALTKEYMASK)),
            (kVK_RightOption, UInt32(XK_Alt_R), UInt(NX_DEVICERALTKEYMASK)),
            (kVK_Command, UInt32(XK_Super_L), UInt(NX_DEVICELCMDKEYMASK)),
            (kVK_RightCommand, UInt32(XK_Super_R), UInt(NX_DEVICERCMDKEYMASK))
        ]
        for modifier in modifiers {
            let down = event.modifierFlags.rawValue & modifier.mask != 0
            if down != (heldKeys[modifier.code] != 0) {
                session?.sendKey(modifier.symbol, down: down)
                heldKeys[modifier.code] = down ? modifier.symbol : 0
            }
        }
    }

    override func flagsChanged(with event: NSEvent) { syncModifiers(event) }

    override func keyDown(with event: NSEvent) {
        let code = Int(event.keyCode)
        guard inputEnabled, code < heldKeys.count, !event.isARepeat, heldKeys[code] == 0 else { return }
        controller?.syncClipboard(force: false) // Clipboard precedes paste keys.
        syncModifiers(event)
        var symbol: UInt32 = switch code {
        case kVK_Return, kVK_ANSI_KeypadEnter: UInt32(XK_Return)
        case kVK_Tab: UInt32(XK_Tab)
        case kVK_Delete: UInt32(XK_BackSpace)
        case kVK_ForwardDelete: UInt32(XK_Delete)
        case kVK_Escape: UInt32(XK_Escape)
        case kVK_LeftArrow: UInt32(XK_Left)
        case kVK_RightArrow: UInt32(XK_Right)
        case kVK_UpArrow: UInt32(XK_Up)
        case kVK_DownArrow: UInt32(XK_Down)
        case kVK_Home: UInt32(XK_Home)
        case kVK_End: UInt32(XK_End)
        case kVK_PageUp: UInt32(XK_Page_Up)
        case kVK_PageDown: UInt32(XK_Page_Down)
        case kVK_F1: UInt32(XK_F1)
        case kVK_F2: UInt32(XK_F2)
        case kVK_F3: UInt32(XK_F3)
        case kVK_F4: UInt32(XK_F4)
        case kVK_F5: UInt32(XK_F5)
        case kVK_F6: UInt32(XK_F6)
        case kVK_F7: UInt32(XK_F7)
        case kVK_F8: UInt32(XK_F8)
        case kVK_F9: UInt32(XK_F9)
        case kVK_F10: UInt32(XK_F10)
        case kVK_F11: UInt32(XK_F11)
        case kVK_F12: UInt32(XK_F12)
        default: 0
        }
        if symbol == 0 {
            let shortcut = !event.modifierFlags.intersection([.control, .option, .command]).isEmpty
            let text = shortcut ? event.charactersIgnoringModifiers : event.characters
            guard let text, text.utf16.count == 1, let character = text.utf16.first,
                  character != 0, !(0xd800...0xdfff).contains(character), character < 0xf700 else { return }
            symbol = character <= 255 ? UInt32(character) : 0x01000000 | UInt32(character)
        }
        // Key-up must use this symbol, even if Shift/Caps state later changes.
        heldKeys[code] = symbol
        session?.sendKey(symbol, down: true)
    }

    override func keyUp(with event: NSEvent) {
        let code = Int(event.keyCode)
        guard inputEnabled, code < heldKeys.count, heldKeys[code] != 0 else { return }
        session?.sendKey(heldKeys[code], down: false)
        heldKeys[code] = 0
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if window?.firstResponder === self, event.modifierFlags.contains(.command) {
            let key = event.charactersIgnoringModifiers?.lowercased()
            if key != "q", key != "w" { keyDown(with: event); return true }
        }
        return super.performKeyEquivalent(with: event)
    }

    func releaseInput() {
        for code in heldKeys.indices where heldKeys[code] != 0 {
            session?.sendKey(heldKeys[code], down: false)
            heldKeys[code] = 0
        }
        if buttons != 0 { session?.sendPointer(x: lastX, y: lastY, buttons: 0) }
        buttons = 0
        scrollX = 0
        scrollY = 0
    }

    override func resignFirstResponder() -> Bool {
        releaseInput()
        return super.resignFirstResponder()
    }
}
