import AppKit
import Darwin

@MainActor
final class ViewerApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var hostField: NSTextField!
    private var portField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var connectButton: NSButton!
    private var clipboardButton: NSButton!
    private var sendButton: NSButton!
    private var statusField: NSTextField!
    private var desktop: DesktopView!
    private var session: VNCSession?
    private var timer: Timer?
    private var pasteboard = NSPasteboard.general // Main thread only; never the worker.
    private var pasteboardChange = 0
    private var ready = false
    private var terminating = false
    private var nextClipboardPoll: TimeInterval = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sharedesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        menu.addItem(editItem)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = edit
        NSApp.mainMenu = menu

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 720),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Sharedesk"
        window.minSize = NSSize(width: 800, height: 480)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.acceptsMouseMovedEvents = true
        hostField = NSTextField(string: "")
        hostField.placeholderString = "Tailscale IPv4"
        portField = NSTextField(string: "5901")
        passwordField = NSSecureTextField()
        passwordField.placeholderString = "VNC password"
        connectButton = NSButton(title: "Connect", target: self, action: #selector(connect(_:)))
        let connection = NSStackView(views: [NSTextField(labelWithString: "Host"), hostField,
                                           NSTextField(labelWithString: "Port"), portField, passwordField, connectButton])
        connection.orientation = .horizontal
        connection.spacing = 8
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        portField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        passwordField.widthAnchor.constraint(greaterThanOrEqualToConstant: 150).isActive = true
        clipboardButton = NSButton(checkboxWithTitle: "Share text clipboard (Latin-1)", target: self, action: #selector(clipboardChanged(_:)))
        sendButton = NSButton(title: "Send Clipboard", target: self, action: #selector(sendClipboard(_:)))
        sendButton.isEnabled = false
        let options = NSStackView(views: [clipboardButton, sendButton])
        options.orientation = .horizontal
        options.spacing = 12
        desktop = DesktopView()
        desktop.controller = self
        desktop.setContentHuggingPriority(.defaultLow, for: .vertical)
        statusField = NSTextField(labelWithString: "Private VNC connection. Clipboard is off until you enable it. Passwords are not saved.")
        statusField.font = .systemFont(ofSize: 11)
        let stack = NSStackView(views: [connection, options, desktop, statusField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            desktop.widthAnchor.constraint(equalTo: stack.widthAnchor),
            desktop.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        pasteboardChange = pasteboard.changeCount
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(poll(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(hostField)
    }

    @objc private func connect(_ sender: Any?) {
        if let session {
            desktop.releaseInput()
            session.stop()
            connectButton.isEnabled = false
            return
        }
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var address = in_addr()
        let ip: UInt32 = host.withCString { inet_pton(AF_INET, $0, &address) == 1 ? UInt32(bigEndian: address.s_addr) : 0 }
        let scanner = Scanner(string: portField.stringValue)
        let password = passwordField.stringValue
        let ascii = password.data(using: .ascii, allowLossyConversion: false)
        let validPassword = ascii.map { (1...8).contains($0.count) && $0.allSatisfy { (33...126).contains($0) } } ?? false
        guard (ip & 0xffc00000 == 0x64400000 || ip & 0xff000000 == 0x7f000000),
              let port = scanner.scanInt(), scanner.isAtEnd, (1...65535).contains(port), validPassword else {
            statusField.stringValue = "Use a Tailscale/loopback IPv4, port 1–65535 and a 1–8 character ASCII VNC password."
            return
        }
        desktop.clearDesktop()
        let session = VNCSession(host: host, port: port, password: password)
        self.session = session
        desktop.session = session
        session.setClipboardSharing(clipboardButton.state == .on)
        passwordField.stringValue = ""
        hostField.isEnabled = false
        portField.isEnabled = false
        passwordField.isEnabled = false
        connectButton.title = "Disconnect"
        statusField.stringValue = "Connecting…"
        pasteboardChange = pasteboard.changeCount // Never export the old clipboard on connect.
        session.start()
        window.makeFirstResponder(desktop)
    }

    @objc private func clipboardChanged(_ sender: Any?) {
        session?.setClipboardSharing(clipboardButton.state == .on)
        pasteboardChange = pasteboard.changeCount // Enabling does not send an old copy.
        sendButton.isEnabled = ready && clipboardButton.state == .on
        if ready { window.makeFirstResponder(desktop) }
    }

    @objc private func sendClipboard(_ sender: Any?) {
        syncClipboard(force: true)
        if ready { window.makeFirstResponder(desktop) }
    }

    func syncClipboard(force: Bool) {
        guard ready, clipboardButton.state == .on else { return }
        let change = pasteboard.changeCount
        guard force || change != pasteboardChange else { return }
        pasteboardChange = change
        guard let text = pasteboard.string(forType: .string) else {
            if force { statusField.stringValue = "No text is available on the Mac clipboard." }
            return
        }
        guard let data = text.data(using: .isoLatin1, allowLossyConversion: false),
              data.count <= clipboardLimit, !data.contains(0) else {
            statusField.stringValue = "Clipboard was not sent: use Latin-1 text up to 1 MiB, without NUL bytes."
            return
        }
        session?.sendClipboard(data)
        statusField.stringValue = "Mac clipboard queued for Ubuntu. Paste there with the application's Ubuntu shortcut."
    }

    @objc private func poll(_ timer: Timer) {
        guard let session else { return }
        let update = session.poll()
        let wasReady = ready
        ready = update.state.ready
        desktop.inputEnabled = ready
        if ready && !wasReady {
            pasteboardChange = pasteboard.changeCount
            window.makeFirstResponder(desktop)
        }
        if ready != wasReady || update.state.finished { statusField.stringValue = update.state.message }
        if let frame = update.frame { desktop.showFrame(frame) }
        if let cursor = update.cursor { desktop.showCursor(cursor) }
        if let data = update.clipboard, clipboardButton.state == .on, ready,
           let text = String(data: data, encoding: .isoLatin1) {
            pasteboard.clearContents()
            let written = pasteboard.setString(text, forType: .string)
            pasteboardChange = pasteboard.changeCount // Suppress our own echo.
            statusField.stringValue = written ? "Ubuntu text received on the Mac clipboard." : "Could not write the received text to the Mac clipboard."
        }
        sendButton.isEnabled = ready && clipboardButton.state == .on
        let now = ProcessInfo.processInfo.systemUptime
        if ready && NSApp.isActive && now >= nextClipboardPoll {
            nextClipboardPoll = now + 0.2
            syncClipboard(force: false)
        }
        if update.state.finished {
            desktop.clearDesktop()
            desktop.session = nil
            self.session = nil
            ready = false
            sendButton.isEnabled = false
            hostField.isEnabled = true
            portField.isEnabled = true
            passwordField.isEnabled = true
            connectButton.title = "Connect"
            connectButton.isEnabled = true
            if terminating { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    func windowDidResignKey(_ notification: Notification) { desktop.releaseInput() }
    func windowWillClose(_ notification: Notification) { desktop.releaseInput(); session?.stop() }
    func applicationWillTerminate(_ notification: Notification) { timer?.invalidate(); timer = nil }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let session {
            terminating = true
            desktop.releaseInput()
            session.stop()
            return .terminateLater
        }
        return .terminateNow
    }
}
