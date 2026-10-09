import AppKit

// The app owns shared settings and retains each window until its networking
// worker has finished. Connection state and credentials belong to that window.
@MainActor
final class ViewerApplication: NSObject, NSApplicationDelegate {
    let profileStore = ConnectionProfileStore(fileURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".sharedesk", isDirectory: true).appendingPathComponent("profiles.json"))
    private(set) var profileLoadError: String?
    private(set) var isTerminating = false
    // This local-only pasteboard marker applies to every connection window.
    var privatePasteboardChange: Int?
    private var viewers: [ViewerWindow] = []
    private weak var lastFocusedViewer: ViewerWindow?
    private weak var mcpOwner: ViewerWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        let mcpItem = appMenu.addItem(withTitle: "MCP Server…", action: #selector(showMCPServer(_:)), keyEquivalent: "")
        mcpItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Sharedesk", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        menu.addItem(fileItem)
        let fileMenu = NSMenu(title: "File")
        let newItem = fileMenu.addItem(withTitle: "New Connection Window", action: #selector(newConnectionWindow(_:)), keyEquivalent: "n")
        newItem.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        menu.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editItem.submenu = editMenu

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        menu.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        NSApp.mainMenu = menu
        NSApp.windowsMenu = windowMenu

        do { try profileStore.load() }
        catch { profileLoadError = error.localizedDescription }
        newConnectionWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func newConnectionWindow(_ sender: Any?) {
        guard !isTerminating else { return }
        let previous = viewers.last(where: { !$0.isClosing })?.window
        let viewer = ViewerWindow(application: self)
        viewers.append(viewer)
        if let previous {
            viewer.window.cascadeTopLeft(from: NSPoint(x: previous.frame.minX, y: previous.frame.maxY))
        }
        viewer.window.makeKeyAndOrderFront(sender)
    }

    @objc private func showMCPServer(_ sender: Any?) {
        guard !isTerminating else { return }
        // One fixed endpoint, explicitly bound to its owner while its panel is
        // open. Focus changes must never redirect an authorized MCP client.
        if let owner = mcpOwner, !owner.isClosing, owner.hasMCPPanel {
            owner.window.makeKeyAndOrderFront(sender)
            owner.showMCPServer(sender)
            return
        }
        if !viewers.contains(where: { !$0.isClosing }) { newConnectionWindow(sender) }
        guard let viewer = viewers.first(where: { !$0.isClosing && $0.window === NSApp.mainWindow }) ??
                (lastFocusedViewer?.isClosing == false ? lastFocusedViewer : nil) ??
                viewers.last(where: { !$0.isClosing }) else { return }
        mcpOwner = viewer
        viewer.showMCPServer(sender)
    }

    func viewerDidBecomeKey(_ viewer: ViewerWindow) {
        if lastFocusedViewer !== viewer {
            // Switching hosts does not automatically export text copied for
            // the previous host. Send Clipboard remains an explicit action.
            viewer.resetClipboardBaseline()
            lastFocusedViewer = viewer
        }
    }

    func suppressClipboardEcho() {
        for viewer in viewers { viewer.resetClipboardBaseline() }
    }

    func profilesDidChange(changedID: UUID, excluding source: ViewerWindow) {
        for viewer in viewers where viewer !== source && !viewer.isClosing {
            viewer.profilesDidChange(changedID: changedID)
        }
    }

    func autoHideControlsDidChange() {
        for viewer in viewers where !viewer.isClosing { viewer.autoHideControlsDidChange() }
    }

    func viewerDidFinishSession(_ viewer: ViewerWindow) {
        if viewer.isClosing { viewers.removeAll { $0 === viewer } }
        if isTerminating && !viewers.contains(where: \.hasSession) {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !isTerminating else { return false }
        if !flag {
            if let viewer = viewers.last(where: { !$0.isClosing }) {
                viewer.window.deminiaturize(nil)
                viewer.window.makeKeyAndOrderFront(nil)
            } else {
                newConnectionWindow(nil)
            }
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        isTerminating = true
        for viewer in viewers { viewer.stopForTermination() }
        return viewers.contains(where: \.hasSession) ? .terminateLater : .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        for viewer in viewers {
            viewer.stopForTermination()
            viewer.invalidateTimer()
        }
    }
}
