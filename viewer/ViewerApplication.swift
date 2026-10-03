import AppKit
import Darwin

@MainActor
final class ViewerApplication: NSObject, NSApplicationDelegate, NSWindowDelegate, NSTextFieldDelegate {
    private var window: NSWindow!
    private let profileStore = ConnectionProfileStore(fileURL: FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".sharedesk", isDirectory: true).appendingPathComponent("profiles.json"))
    private var profilePopup: NSPopUpButton!
    private var addProfileButton: NSButton!
    private var editProfileButton: NSButton!
    private var deleteProfileButton: NSButton!
    private var hostField: NSTextField!
    private var portField: NSTextField!
    private var passwordField: NSSecureTextField!
    private var connectButton: NSButton!
    private var clipboardButton: NSButton!
    private var sendButton: NSButton!
    private var controlsToggleButton: NSButton!
    private var controlPanel: NSGlassEffectView!
    private var connectionRow: NSStackView!
    private var connectionFooter: NSStackView!
    private var statisticsButton: NSButton!
    private var statisticsWindow: ConnectionStatistics?
    private var lastSessionStatistics: SessionStatistics?
    private var lastDisconnect: SessionEnd?
    private var nextStatisticsRefresh: TimeInterval = 0
    private var statusField: NSTextField!
    private var connectionStateField: NSTextField!
    private var connectionStateImage: NSImageView!
    private var desktop: DesktopView!
    private var desktopViewport: DesktopScrollView!
    private var zoomControl: NSSegmentedControl!
    private let zoomLevels: [CGFloat] = [1, 1.25, 1.5, 2, 3, 4]
    private var session: VNCSession?
    private var connectionState: SessionState = .finished(.disconnected)
    private var sessionEstablished = false
    // Connection fields remain the endpoint/settings source of truth. No
    // separate reconnect profile, password cache or automatic retry timer.
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

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1024, height: 740),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Sharedesk"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .windowBackgroundColor
        window.minSize = NSSize(width: 800, height: 480)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.acceptsMouseMovedEvents = true

        profilePopup = NSPopUpButton()
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        profilePopup.controlSize = .large
        profilePopup.widthAnchor.constraint(equalToConstant: 300).isActive = true
        profilePopup.setAccessibilityLabel("Connection profile")
        addProfileButton = NSButton(title: "Add…", target: self, action: #selector(addProfile(_:)))
        editProfileButton = NSButton(title: "Edit…", target: self, action: #selector(editSelectedProfile(_:)))
        deleteProfileButton = NSButton(title: "Delete…", target: self, action: #selector(deleteProfile(_:)))
        for (button, symbol) in [(addProfileButton!, "plus"), (editProfileButton!, "pencil"), (deleteProfileButton!, "trash")] {
            button.bezelStyle = .glass
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageLeading
        }
        let profileLabel = NSTextField(labelWithString: "Profile")
        profileLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        let profileSpace = NSView()
        profileSpace.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let profileRow = NSStackView(views: [profileLabel, profilePopup, profileSpace,
                                            addProfileButton, editProfileButton, deleteProfileButton])
        profileRow.orientation = .horizontal
        profileRow.alignment = .centerY
        profileRow.spacing = 8

        hostField = NSTextField(string: "")
        hostField.placeholderString = "Tailscale IPv4"
        portField = NSTextField(string: "5901")
        hostField.delegate = self
        portField.delegate = self
        passwordField = NSSecureTextField()
        passwordField.placeholderString = "VNC password"
        connectButton = NSButton(title: "Connect", target: self, action: #selector(connect(_:)))
        connectButton.bezelStyle = .glass
        connectButton.bezelColor = .controlAccentColor
        connectButton.controlSize = .large
        connectButton.font = .systemFont(ofSize: 13, weight: .semibold)
        connectButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
        connectButton.imagePosition = .imageLeading
        connectButton.toolTip = "Connect to the address and port shown above."
        connectButton.widthAnchor.constraint(equalToConstant: 124).isActive = true
        connectButton.setContentHuggingPriority(.required, for: .vertical)
        let connection = NSStackView()
        connectionRow = connection
        connection.orientation = .horizontal
        connection.alignment = .bottom
        connection.spacing = 12
        for (field, title) in [(hostField!, "Host address"), (portField!, "Port"), (passwordField!, "Password")] {
            field.controlSize = .large
            field.font = .systemFont(ofSize: 13)
            field.setContentHuggingPriority(.required, for: .vertical)
            field.setContentCompressionResistancePriority(.required, for: .vertical)
            field.setAccessibilityLabel(title)
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .labelColor
            // Keep AppKit's native field height, centred in a button-height row.
            let input = NSView()
            input.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false
            input.addSubview(field)
            let column = NSStackView(views: [label, input])
            column.orientation = .vertical
            column.distribution = .fill
            column.alignment = .leading
            column.spacing = 5
            NSLayoutConstraint.activate([
                input.widthAnchor.constraint(equalTo: column.widthAnchor),
                input.heightAnchor.constraint(equalToConstant: max(field.intrinsicContentSize.height, connectButton.intrinsicContentSize.height)),
                field.leadingAnchor.constraint(equalTo: input.leadingAnchor),
                field.trailingAnchor.constraint(equalTo: input.trailingAnchor),
                field.centerYAnchor.constraint(equalTo: input.centerYAnchor)
            ])
            connection.addArrangedSubview(column)
        }
        hostField.widthAnchor.constraint(greaterThanOrEqualToConstant: 210).isActive = true
        hostField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        portField.widthAnchor.constraint(equalToConstant: 76).isActive = true
        passwordField.widthAnchor.constraint(equalToConstant: 210).isActive = true
        connection.addArrangedSubview(connectButton)

        clipboardButton = NSButton(checkboxWithTitle: "Share text clipboard", target: self, action: #selector(clipboardChanged(_:)))
        clipboardButton.font = .systemFont(ofSize: 12)
        clipboardButton.toolTip = "Opt-in, two-way text sharing. The Ubuntu host must also enable clipboard sharing."
        sendButton = NSButton(title: "Send Clipboard", target: self, action: #selector(sendClipboard(_:)))
        sendButton.bezelStyle = .glass
        sendButton.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: nil)
        sendButton.imagePosition = .imageLeading
        sendButton.toolTip = "Send text already on the Mac clipboard. Negotiated UTF-8 or Latin-1 fallback, up to 1 MiB per encoded transfer."
        sendButton.isEnabled = false
        let options = NSStackView(views: [clipboardButton, sendButton])
        options.orientation = .horizontal
        options.alignment = .centerY
        options.spacing = 12

        // One native glass surface for controls. It never overlays or filters
        // the remote framebuffer, and the system owns its appearance/effects.
        let controls = NSStackView(views: [profileRow, connection, options])
        controls.orientation = .vertical
        controls.alignment = .leading
        controls.spacing = 12
        controls.setContentHuggingPriority(.required, for: .vertical)
        controls.translatesAutoresizingMaskIntoConstraints = false
        let panelContent = NSView()
        panelContent.addSubview(controls)
        let panel = NSGlassEffectView()
        controlPanel = panel
        panel.style = .regular
        panel.cornerRadius = 20
        panel.effectIsInteractive = true
        panel.contentView = panelContent
        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: panelContent.leadingAnchor, constant: 16),
            controls.trailingAnchor.constraint(equalTo: panelContent.trailingAnchor, constant: -16),
            controls.topAnchor.constraint(equalTo: panelContent.topAnchor, constant: 14),
            controls.bottomAnchor.constraint(equalTo: panelContent.bottomAnchor, constant: -14),
            profileRow.widthAnchor.constraint(equalTo: controls.widthAnchor),
            connection.widthAnchor.constraint(equalTo: controls.widthAnchor),
            panel.heightAnchor.constraint(equalTo: controls.heightAnchor, constant: 28)
        ])

        desktop = DesktopView()
        desktop.controller = self
        desktop.wantsLayer = true
        desktop.setAccessibilityLabel("Remote desktop")
        desktop.setAccessibilityHelp("Choose a profile or enter a host above, then connect. Click the desktop to send keyboard and pointer input. When zoomed, use local scrollbars to move the view; the mouse wheel controls Ubuntu.")
        desktopViewport = DesktopScrollView()
        desktopViewport.borderType = .noBorder
        desktopViewport.backgroundColor = .black
        desktopViewport.automaticallyAdjustsContentInsets = false
        desktopViewport.contentView.automaticallyAdjustsContentInsets = false
        desktopViewport.hasHorizontalScroller = true
        desktopViewport.hasVerticalScroller = true
        desktopViewport.scrollerStyle = .legacy // Discoverable without consuming wheel input.
        desktopViewport.autohidesScrollers = false // Geometry shows only the axes that need them.
        desktopViewport.horizontalScrollElasticity = .none
        desktopViewport.verticalScrollElasticity = .none
        desktopViewport.allowsMagnification = false // Buttons only; do not change gesture policy.
        desktopViewport.isTouchScrollingEnabled = false // Local navigation is through scrollbars, not gestures.
        desktopViewport.documentView = desktop
        desktopViewport.wantsLayer = true
        desktopViewport.layer?.cornerRadius = 16
        desktopViewport.layer?.masksToBounds = true
        desktopViewport.setContentHuggingPriority(.defaultLow, for: .vertical)
        connectionStateField = NSTextField(labelWithString: "Not connected")
        connectionStateField.font = .systemFont(ofSize: 11, weight: .semibold)
        connectionStateField.textColor = .secondaryLabelColor
        connectionStateField.setContentHuggingPriority(.required, for: .horizontal)
        connectionStateField.setContentCompressionResistancePriority(.required, for: .horizontal)
        connectionStateImage = NSImageView(image: NSImage(systemSymbolName: "circle", accessibilityDescription: nil)!)
        connectionStateImage.contentTintColor = .secondaryLabelColor
        connectionStateImage.setAccessibilityElement(false)
        let state = NSStackView(views: [connectionStateImage, connectionStateField])
        state.orientation = .horizontal
        state.alignment = .centerY
        state.spacing = 6
        state.setContentHuggingPriority(.required, for: .horizontal)
        statusField = NSTextField(labelWithString: "Private VNC connection. Clipboard is opt-in. Saved passwords use macOS Keychain.")
        statusField.font = .systemFont(ofSize: 11)
        statusField.textColor = .secondaryLabelColor
        statusField.lineBreakMode = .byTruncatingTail
        statusField.isSelectable = true
        statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        controlsToggleButton = NSButton(title: "Hide Controls", target: self, action: #selector(toggleControls(_:)))
        controlsToggleButton.bezelStyle = .glass
        controlsToggleButton.font = .systemFont(ofSize: 12)
        controlsToggleButton.image = NSImage(systemSymbolName: "chevron.up", accessibilityDescription: nil)
        controlsToggleButton.imagePosition = .imageLeading
        controlsToggleButton.toolTip = "Hide connection controls to give the remote desktop more space."
        controlsToggleButton.setContentHuggingPriority(.required, for: .horizontal)
        controlsToggleButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        zoomControl = NSSegmentedControl(labels: ["", "Fit", ""], trackingMode: .momentary, target: self, action: #selector(changeZoom(_:)))
        zoomControl.controlSize = .small
        zoomControl.font = .systemFont(ofSize: 12)
        zoomControl.setImage(NSImage(systemSymbolName: "minus.magnifyingglass", accessibilityDescription: "Zoom out"), forSegment: 0)
        zoomControl.setImage(NSImage(systemSymbolName: "plus.magnifyingglass", accessibilityDescription: "Zoom in"), forSegment: 2)
        zoomControl.setWidth(28, forSegment: 0)
        zoomControl.setWidth(50, forSegment: 1)
        zoomControl.setWidth(28, forSegment: 2)
        zoomControl.setToolTip("Zoom out towards Fit Desktop.", forSegment: 0)
        zoomControl.setToolTip("Fit Desktop: reset zoom and show the whole remote image.", forSegment: 1)
        zoomControl.setToolTip("Zoom in relative to Fit Desktop. Use local scrollbars to move the view.", forSegment: 2)
        zoomControl.setAccessibilityLabel("Desktop zoom")
        zoomControl.setAccessibilityHelp("Zoom is relative to Fit Desktop. The middle button resets to Fit. Mouse-wheel input still goes to Ubuntu.")
        zoomControl.setContentHuggingPriority(.required, for: .horizontal)
        zoomControl.setContentCompressionResistancePriority(.required, for: .horizontal)
        updateZoomControls()
        statisticsButton = NSButton(title: "Stats", target: self, action: #selector(showStatistics(_:)))
        statisticsButton.bezelStyle = .glass
        statisticsButton.font = .systemFont(ofSize: 12)
        statisticsButton.image = NSImage(systemSymbolName: "chart.bar", accessibilityDescription: nil)
        statisticsButton.imagePosition = .imageLeading
        statisticsButton.toolTip = "Show connection statistics. No content logging or saved history."
        statisticsButton.setAccessibilityLabel("Show connection statistics")
        statisticsButton.setContentHuggingPriority(.required, for: .horizontal)
        statisticsButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let footer = NSStackView(views: [state, statusField, statisticsButton, zoomControl, controlsToggleButton])
        connectionFooter = footer
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = 16
        let stack = NSStackView(views: [panel, desktopViewport, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for row in [profileRow, connection, options, controls, state, footer, stack] { row.distribution = .fill }
        let content = window.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            stack.topAnchor.constraint(equalTo: content.safeAreaLayoutGuide.topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            panel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            desktopViewport.widthAnchor.constraint(equalTo: stack.widthAnchor),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor),
            connectionStateImage.widthAnchor.constraint(equalToConstant: 10),
            connectionStateImage.heightAnchor.constraint(equalToConstant: 10),
            desktopViewport.heightAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
        updateFocusOrder()
        window.autorecalculatesKeyViewLoop = false
        do { try profileStore.load() }
        catch { showStatus("Saved profiles unavailable: \(error.localizedDescription) Manual connections are still available.") }
        refreshProfiles(selectedID: nil)
        pasteboardChange = pasteboard.changeCount
        let timer = Timer(timeInterval: 1.0 / 60, target: self, selector: #selector(poll(_:)), userInfo: nil, repeats: true)
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.makeFirstResponder(hostField)
    }

    @objc private func toggleControls(_ sender: Any?) {
        let hide = !controlPanel.isHidden
        window.makeFirstResponder(desktop) // Never leave an editor focused inside hidden controls.
        if hide {
            connectionRow.removeArrangedSubview(connectButton)
            connectButton.removeFromSuperview()
            connectionFooter.insertArrangedSubview(connectButton, at: connectionFooter.arrangedSubviews.count - 1)
        } else {
            connectionFooter.removeArrangedSubview(connectButton)
            connectButton.removeFromSuperview()
            connectionRow.addArrangedSubview(connectButton)
        }
        controlPanel.isHidden = hide
        controlsToggleButton.title = hide ? "Show Controls" : "Hide Controls"
        controlsToggleButton.image = NSImage(systemSymbolName: hide ? "chevron.down" : "chevron.up", accessibilityDescription: nil)
        controlsToggleButton.toolTip = hide ? "Show profiles, connection fields and clipboard controls." : "Hide connection controls to give the remote desktop more space."
        updateFocusOrder()
        window.contentView?.layoutSubtreeIfNeeded()
    }

    @objc private func showStatistics(_ sender: Any?) {
        desktop.releaseInput()
        if statisticsWindow == nil {
            statisticsWindow = ConnectionStatistics()
            statisticsWindow?.window?.center()
        }
        let wasVisible = statisticsWindow?.window?.isVisible == true
        statisticsWindow?.showWindow(sender)
        if !wasVisible { refreshStatistics() }
    }

    private func refreshStatistics() {
        guard let statisticsWindow, statisticsWindow.window?.isVisible == true else { return }
        statisticsWindow.update(session?.statistics() ?? lastSessionStatistics, lastDisconnect: lastDisconnect)
        nextStatisticsRefresh = ProcessInfo.processInfo.systemUptime + 1
    }

    @objc private func changeZoom(_ sender: NSSegmentedControl) {
        guard desktop.hasFramebuffer, ready else { return }
        let current = desktopViewport.zoomFactor
        let next: CGFloat
        switch sender.selectedSegment {
        case 0: next = zoomLevels.last(where: { $0 < current - 0.001 }) ?? zoomLevels[0]
        case 1: next = zoomLevels[0]
        case 2: next = zoomLevels.first(where: { $0 > current + 0.001 }) ?? zoomLevels[zoomLevels.count - 1]
        default: return
        }
        desktopViewport.setZoom(next)
        window.contentView?.layoutSubtreeIfNeeded()
        desktopViewport.flashScrollers()
        window.invalidateCursorRects(for: desktop)
        updateZoomControls()
        window.makeFirstResponder(desktop)
    }

    private func updateZoomControls() {
        let scale = desktopViewport.zoomFactor
        let label = scale <= 1.001 ? "Fit" : String(format: "%g×", Double(scale))
        if zoomControl.label(forSegment: 1) != label { zoomControl.setLabel(label, forSegment: 1) }
        zoomControl.isEnabled = ready && desktop.hasFramebuffer
        zoomControl.setEnabled(scale > zoomLevels[0] + 0.001, forSegment: 0)
        zoomControl.setEnabled(scale < zoomLevels[zoomLevels.count - 1] - 0.001, forSegment: 2)
    }

    private func updateFocusOrder() {
        let order: [NSView]
        if controlPanel.isHidden {
            order = [desktop, statusField, statisticsButton, zoomControl, connectButton, controlsToggleButton]
        } else {
            order = [profilePopup, addProfileButton, editProfileButton, deleteProfileButton,
                     hostField, portField, passwordField, connectButton, clipboardButton, sendButton,
                     desktop, statusField, statisticsButton, zoomControl, controlsToggleButton]
        }
        for index in order.indices { order[index].nextKeyView = order[(index + 1) % order.count] }
    }

    private func focusConnectionPassword() {
        if controlPanel.isHidden { toggleControls(nil) }
        window.makeFirstResponder(passwordField)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard session == nil, let field = notification.object as? NSTextField,
              field === hostField || field === portField else { return }
        // Editing an endpoint leaves recovery mode. Never label a connection
        // to a changed address/port as a reconnect to the previous host.
        if connectionState != .finished(.disconnected) {
            sessionEstablished = false
            showConnectionState(.finished(.disconnected))
            showStatus("Address or port changed. Connect will use the current fields.")
        }
    }

    @objc private func connect(_ sender: Any?) {
        if let session {
            desktop.releaseInput()
            session.stop()
            ready = false
            desktop.clearDesktop()
            updateZoomControls()
            sendButton.isEnabled = false
            showStatus("Disconnecting…")
            showConnectionState(.stopping(.disconnected))
            return
        }
        let recovering = connectionState.finished && connectionState != .finished(.disconnected)
        let target: ConnectionTarget
        var password = passwordField.stringValue
        do {
            target = try ConnectionTarget(host: hostField.stringValue, portText: portField.stringValue)
            if password.isEmpty, let profile = selectedProfile, let reference = profile.passwordReference {
                guard target == profile.target else {
                    showStatus("The address or port differs from the saved profile. Enter a password for this connection or edit the profile.")
                    focusConnectionPassword()
                    return
                }
                password = try ProfilePasswords.read(reference: reference, target: target)
            }
            if recovering && password.isEmpty {
                showStatus("Enter the VNC password to \(sessionEstablished ? "reconnect" : "retry") \(target.host):\(target.port). Typed passwords are not retained.")
                focusConnectionPassword()
                return
            }
            guard validVNCPassword(password) else { throw PasswordError.invalidPassword }
        } catch {
            showStatus(error.localizedDescription)
            focusConnectionPassword()
            return
        }
        ready = false
        sessionEstablished = false
        desktop.clearDesktop()
        updateZoomControls()
        let session = VNCSession(host: target.host, port: target.port, password: password)
        self.session = session
        desktop.session = session
        session.setClipboardSharing(clipboardButton.state == .on)
        passwordField.stringValue = ""
        hostField.isEnabled = false
        portField.isEnabled = false
        passwordField.isEnabled = false
        showStatus("Connecting to \(target.host):\(target.port)…")
        showConnectionState(.connecting)
        pasteboardChange = pasteboard.changeCount // Never export the old clipboard on connect.
        updateProfileControls()
        session.start()
        window.makeFirstResponder(desktop)
    }

    private func showStatus(_ message: String) {
        statusField.stringValue = message
        statusField.toolTip = message // Long errors remain available without widening the window.
    }

    private func showConnectionState(_ state: SessionState) {
        connectionState = state
        let title: String
        let symbol: String
        let color: NSColor
        let action: String
        switch state {
        case .connecting:
            title = "Connecting"; symbol = "circle.dotted"; color = .secondaryLabelColor; action = "Disconnect"
        case .connected:
            title = "Connected"; symbol = "circle.fill"; color = .systemGreen; action = "Disconnect"
        case .stopping:
            title = "Disconnecting"; symbol = "circle.dotted"; color = .secondaryLabelColor; action = "Disconnect"
        case .finished(.disconnected):
            title = "Not connected"; symbol = "circle"; color = .secondaryLabelColor; action = "Connect"
        case .finished:
            title = sessionEstablished ? "Connection lost" : "Connection failed"
            symbol = "exclamationmark.circle"; color = .systemOrange
            action = sessionEstablished ? "Reconnect" : "Retry"
        }
        connectionStateField.stringValue = title
        connectionStateImage.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        connectionStateImage.contentTintColor = color
        let recovery = state.finished && state != .finished(.disconnected)
        connectButton.title = action
        connectButton.image = NSImage(systemSymbolName: recovery ? "arrow.clockwise" : state.finished ? "arrow.up.right" : "xmark", accessibilityDescription: nil)
        connectButton.bezelColor = state.finished ? .controlAccentColor : nil
        if case .stopping = state { connectButton.isEnabled = false }
        else { connectButton.isEnabled = true }
        if recovery {
            connectButton.toolTip = "\(action) \(hostField.stringValue):\(portField.stringValue) with the current clipboard setting. Read an endpoint-matched Keychain password, or enter it again. No automatic retries."
        } else {
            connectButton.toolTip = state.finished ? "Connect to the address and port shown above." : "Disconnect or cancel this connection."
        }
    }

    private var selectedProfile: ConnectionProfile? {
        guard let id = profilePopup.selectedItem?.representedObject as? UUID else { return nil }
        return profileStore.profiles.first { $0.id == id }
    }

    private func refreshProfiles(selectedID: UUID?) {
        profilePopup.removeAllItems()
        profilePopup.addItem(withTitle: "Manual connection")
        for profile in profileStore.profiles {
            profilePopup.addItem(withTitle: profile.name)
            let item = profilePopup.lastItem!
            item.representedObject = profile.id
            item.toolTip = "\(profile.target.host):\(profile.target.port)"
            if profile.id == selectedID { profilePopup.select(item) }
        }
        updateProfileControls()
    }

    private func updateProfileControls() {
        let editable = session == nil && profileStore.loaded
        profilePopup.isEnabled = editable
        addProfileButton.isEnabled = editable
        editProfileButton.isEnabled = editable && selectedProfile != nil
        deleteProfileButton.isEnabled = editable && selectedProfile != nil
    }

    @objc private func profileChanged(_ sender: Any?) {
        guard session == nil else { return }
        sessionEstablished = false
        showConnectionState(.finished(.disconnected))
        let profile = selectedProfile
        hostField.stringValue = profile?.target.host ?? ""
        portField.stringValue = profile.map { String($0.target.port) } ?? "5901"
        passwordField.stringValue = ""
        passwordField.placeholderString = profile?.passwordReference != nil ? "Keychain password or override" : "VNC password"
        clipboardButton.state = profile?.shareClipboard == true ? .on : .off
        clipboardChanged(nil) // Selecting/enabling never exports the old clipboard.
        updateProfileControls()
        showStatus(profile?.passwordReference != nil
            ? "Profile selected. Connect will read its password from macOS Keychain."
            : "Enter the VNC password, then connect.")
        window.makeFirstResponder(profile?.passwordReference != nil ? connectButton : passwordField)
    }

    @objc private func addProfile(_ sender: Any?) { editProfile(nil) }
    @objc private func editSelectedProfile(_ sender: Any?) {
        guard let profile = selectedProfile else { return }
        editProfile(profile)
    }

    private func editProfile(_ existing: ConnectionProfile?) {
        guard session == nil, profileStore.loaded else { return }
        let editor = ProfileEditor(profile: existing, host: hostField.stringValue, port: portField.stringValue,
                                   shareClipboard: clipboardButton.state == .on)
        let guidance = editor.alert.informativeText
        defer { editor.passwordField.stringValue = "" }
        while editor.alert.runModal() == .alertFirstButtonReturn {
            var createdPassword: (reference: UUID, target: ConnectionTarget)?
            do {
                let target = try ConnectionTarget(host: editor.hostField.stringValue, portText: editor.portField.stringValue)
                let password = editor.passwordField.stringValue
                var reference: UUID?
                if editor.rememberButton.state == .on {
                    if password.isEmpty {
                        guard let previous = existing, previous.target == target, let saved = previous.passwordReference else {
                            throw PasswordError.invalidPassword
                        }
                        reference = saved
                    } else {
                        guard validVNCPassword(password) else { throw PasswordError.invalidPassword }
                        reference = UUID()
                    }
                }
                let profile = try ConnectionProfile(id: existing?.id ?? UUID(), name: editor.nameField.stringValue,
                                                    target: target, shareClipboard: editor.clipboardButton.state == .on,
                                                    passwordReference: reference)
                try profileStore.check(profile)
                if let reference, !password.isEmpty {
                    try ProfilePasswords.save(password, reference: reference, target: target)
                    createdPassword = (reference, target)
                }
                try profileStore.upsert(profile)
                // Once settings commit, the new reference belongs to the profile.
                createdPassword = nil
                refreshProfiles(selectedID: profile.id)
                profileChanged(nil)
                showStatus("Profile saved.")
                if let previous = existing, let old = previous.passwordReference, old != reference {
                    do { try ProfilePasswords.remove(reference: old, target: previous.target) }
                    catch {
                        showStatus("Profile saved, but its previous password could not be removed from Keychain. Remove the Sharedesk VNC item with account \(old.uuidString)@\(previous.target.host):\(previous.target.port) in Keychain Access. \(error.localizedDescription)")
                    }
                }
                return
            } catch {
                var message = error.localizedDescription
                if let createdPassword {
                    do { try ProfilePasswords.remove(reference: createdPassword.reference, target: createdPassword.target) }
                    catch { message += " The unused password could not be removed from Keychain; remove the Sharedesk VNC item with account \(createdPassword.reference.uuidString)@\(createdPassword.target.host):\(createdPassword.target.port) in Keychain Access. \(error.localizedDescription)" }
                }
                editor.alert.informativeText = guidance + "\n\n" + message
            }
        }
    }

    @objc private func deleteProfile(_ sender: Any?) {
        guard session == nil, let profile = selectedProfile else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \(profile.name)?"
        alert.informativeText = "Remove this profile from the Mac and remove its saved password from Keychain, if present. This does not change the host."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.buttons[0].hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try profileStore.remove(id: profile.id)
            refreshProfiles(selectedID: nil)
            profileChanged(nil)
            showStatus("Profile deleted.")
            if let reference = profile.passwordReference {
                do { try ProfilePasswords.remove(reference: reference, target: profile.target) }
                catch { showStatus("Profile deleted, but its password could not be removed from Keychain. Remove the Sharedesk VNC item with account \(reference.uuidString)@\(profile.target.host):\(profile.target.port) in Keychain Access. \(error.localizedDescription)") }
            }
        } catch { showStatus("Profile was not deleted: \(error.localizedDescription)") }
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
            if force { showStatus("No text is available on the Mac clipboard.") }
            return
        }
        guard let session else { return }
        showStatus(session.sendClipboard(text).message)
    }

    @objc private func poll(_ timer: Timer) {
        defer {
            if ProcessInfo.processInfo.systemUptime >= nextStatisticsRefresh { refreshStatistics() }
        }
        guard let session else { return }
        let update = session.poll()
        let wasReady = ready
        ready = update.state.ready
        sessionEstablished = update.established
        if wasReady && !ready { desktop.clearDesktop() }
        desktop.inputEnabled = ready
        if ready && !wasReady {
            pasteboardChange = pasteboard.changeCount
            window.makeFirstResponder(desktop)
        }
        if connectionState != update.state {
            showStatus(update.state.message)
            showConnectionState(update.state)
        }
        if ready, let frame = update.frame { desktop.showFrame(frame) }
        if ready, let cursor = update.cursor { desktop.showCursor(cursor) }
        if ready != wasReady || update.frame != nil { updateZoomControls() }
        if let data = update.clipboard, clipboardButton.state == .on, ready,
           let text = String(data: data, encoding: .utf8) {
            pasteboard.clearContents()
            let written = pasteboard.setString(text, forType: .string)
            pasteboardChange = pasteboard.changeCount // Suppress our own echo.
            showStatus(written ? "Ubuntu text received on the Mac clipboard." : "Could not write the received text to the Mac clipboard.")
        }
        if let error = update.clipboardError { showStatus(error) }
        clipboardButton.toolTip = update.clipboardUTF8 ?
            "UTF-8 clipboard support negotiated. Both sides must enable sharing; text transfers are limited to 1 MiB." :
            "Opt-in, two-way text sharing. This peer has not negotiated UTF-8; Latin-1 fallback only. The host must also enable sharing."
        sendButton.isEnabled = ready && clipboardButton.state == .on
        let now = ProcessInfo.processInfo.systemUptime
        if ready && NSApp.isActive && now >= nextClipboardPoll {
            nextClipboardPoll = now + 0.2
            syncClipboard(force: false)
        }
        if update.state.finished {
            desktop.clearDesktop()
            updateZoomControls()
            desktop.session = nil
            lastSessionStatistics = session.statistics() // Content-free summary after socket cleanup.
            if case .finished(let reason) = update.state { lastDisconnect = reason }
            nextStatisticsRefresh = 0
            self.session = nil
            ready = false
            sendButton.isEnabled = false
            hostField.isEnabled = true
            portField.isEnabled = true
            passwordField.isEnabled = true
            pasteboardChange = pasteboard.changeCount
            updateProfileControls()
            if case .finished(let reason) = update.state, reason != .disconnected {
                let title = sessionEstablished ? "Connection lost." : "Connection failed."
                showStatus("\(title) \(reason.message) Use \(connectButton.title) for \(hostField.stringValue):\(portField.stringValue) when ready. Nothing reconnects automatically.")
            }
            if terminating { NSApp.reply(toApplicationShouldTerminate: true) }
        }
    }

    func windowDidResignKey(_ notification: Notification) { desktop.releaseInput() }
    func windowWillClose(_ notification: Notification) {
        statisticsWindow?.close()
        desktop.releaseInput()
        session?.stop()
    }
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
