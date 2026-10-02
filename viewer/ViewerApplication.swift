import AppKit
import Darwin

@MainActor
final class ViewerApplication: NSObject, NSApplicationDelegate, NSWindowDelegate {
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
        profilePopup = NSPopUpButton()
        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        profilePopup.widthAnchor.constraint(equalToConstant: 280).isActive = true
        addProfileButton = NSButton(title: "Add…", target: self, action: #selector(addProfile(_:)))
        editProfileButton = NSButton(title: "Edit…", target: self, action: #selector(editSelectedProfile(_:)))
        deleteProfileButton = NSButton(title: "Delete…", target: self, action: #selector(deleteProfile(_:)))
        let profileRow = NSStackView(views: [NSTextField(labelWithString: "Profile"), profilePopup,
                                            addProfileButton, editProfileButton, deleteProfileButton])
        profileRow.orientation = .horizontal
        profileRow.spacing = 8
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
        statusField = NSTextField(labelWithString: "Private VNC connection. Clipboard is opt-in. Saved passwords use macOS Keychain.")
        statusField.font = .systemFont(ofSize: 11)
        statusField.lineBreakMode = .byTruncatingTail
        let stack = NSStackView(views: [profileRow, connection, options, desktop, statusField])
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
            statusField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            desktop.heightAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
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

    @objc private func connect(_ sender: Any?) {
        if let session {
            desktop.releaseInput()
            session.stop()
            connectButton.isEnabled = false
            return
        }
        let target: ConnectionTarget
        var password = passwordField.stringValue
        do {
            target = try ConnectionTarget(host: hostField.stringValue, portText: portField.stringValue)
            if password.isEmpty, let profile = selectedProfile, let reference = profile.passwordReference {
                guard target == profile.target else {
                    showStatus("The address or port differs from the saved profile. Enter a password for this connection or edit the profile.")
                    window.makeFirstResponder(passwordField)
                    return
                }
                password = try ProfilePasswords.read(reference: reference, target: target)
            }
            guard validVNCPassword(password) else { throw PasswordError.invalidPassword }
        } catch {
            showStatus(error.localizedDescription)
            window.makeFirstResponder(passwordField)
            return
        }
        desktop.clearDesktop()
        let session = VNCSession(host: target.host, port: target.port, password: password)
        self.session = session
        desktop.session = session
        session.setClipboardSharing(clipboardButton.state == .on)
        passwordField.stringValue = ""
        hostField.isEnabled = false
        portField.isEnabled = false
        passwordField.isEnabled = false
        connectButton.title = "Disconnect"
        showStatus("Connecting…")
        pasteboardChange = pasteboard.changeCount // Never export the old clipboard on connect.
        updateProfileControls()
        session.start()
        window.makeFirstResponder(desktop)
    }

    private func showStatus(_ message: String) {
        statusField.stringValue = message
        statusField.toolTip = message // Long errors remain available without widening the window.
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
        guard let data = text.data(using: .isoLatin1, allowLossyConversion: false),
              data.count <= clipboardLimit, !data.contains(0) else {
            showStatus("Clipboard was not sent: use Latin-1 text up to 1 MiB, without NUL bytes.")
            return
        }
        session?.sendClipboard(data)
        showStatus("Mac clipboard queued for Ubuntu. Paste there with the application's Ubuntu shortcut.")
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
        if ready != wasReady || update.state.finished { showStatus(update.state.message) }
        if let frame = update.frame { desktop.showFrame(frame) }
        if let cursor = update.cursor { desktop.showCursor(cursor) }
        if let data = update.clipboard, clipboardButton.state == .on, ready,
           let text = String(data: data, encoding: .isoLatin1) {
            pasteboard.clearContents()
            let written = pasteboard.setString(text, forType: .string)
            pasteboardChange = pasteboard.changeCount // Suppress our own echo.
            showStatus(written ? "Ubuntu text received on the Mac clipboard." : "Could not write the received text to the Mac clipboard.")
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
            updateProfileControls()
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
