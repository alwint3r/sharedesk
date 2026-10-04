import AppKit

// Closing this window stops access. Credentials are never displayed in an
// editable/selectable field: all secret copies use the viewer's local-only path.
@MainActor
final class MCPServerWindow: NSWindowController, NSWindowDelegate {
    let server: MCPServer
    private let copyLocal: (String) -> Bool

    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let endpointField = NSTextField(labelWithString: "Not listening")
    private let copyStatus = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Start Server", target: nil, action: nil)
    private let tokenButton = NSButton(title: "Copy Token", target: nil, action: nil)
    private let configButton = NSButton(title: "Copy Client Config", target: nil, action: nil)
    private let controlButton = NSButton(checkboxWithTitle: "Allow MCP Control", target: nil, action: nil)
    private let controlStatus = NSTextField(wrappingLabelWithString: "Control off.")

    init(
        snapshot: @escaping () -> MCPDesktopSnapshot,
        submitInput: @escaping (VNCInputPlan) throws -> VNCInputHandle,
        copyLocal: @escaping (String) -> Bool
    ) {
        self.server = MCPServer(snapshot: snapshot, submitInput: submitInput)
        self.copyLocal = copyLocal

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 470),
            styleMask: [.titled, .closable, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "MCP Server · Experimental"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        super.init(window: panel)
        panel.delegate = self

        let heading = NSTextField(labelWithString: "Access to the remote desktop")
        heading.font = .systemFont(ofSize: 15, weight: .semibold)

        let privacyNotice = NSTextField(wrappingLabelWithString:
            "A trusted MCP client on this Mac can read connection status and take screenshots " +
            "of the current Ubuntu desktop. Screenshots may contain sensitive information. " +
            "The client may store them or send them to its AI provider.\n\n" +
            "Input is off by default. If enabled below, clients can act with your Ubuntu user's permissions, " +
            "including destructive actions. No clipboard or connection-control tools."
        )
        privacyNotice.font = .systemFont(ofSize: 12)
        statusField.font = .systemFont(ofSize: 12, weight: .medium)
        endpointField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        endpointField.isSelectable = true
        endpointField.setAccessibilityLabel("MCP endpoint")

        startButton.target = self
        startButton.action = #selector(toggleServer(_:))
        tokenButton.target = self
        tokenButton.action = #selector(copyToken(_:))
        configButton.target = self
        configButton.action = #selector(copyConfig(_:))
        for button in [startButton, tokenButton, configButton] {
            button.bezelStyle = .glass
        }
        let buttons = NSStackView(views: [startButton, tokenButton, configButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let lifecycleNotice = NSTextField(wrappingLabelWithString:
            "Off each launch. Start creates a new loopback URL and temporary bearer token. " +
            "Update your client's configuration after each restart. Stop, closing this window, " +
            "or quitting Sharedesk invalidates access.\n\n" +
            "Use the copy buttons below rather than copying credentials through the remote desktop. " +
            "Sharedesk blocks these copies from its Ubuntu clipboard sharing."
        )
        lifecycleNotice.font = .systemFont(ofSize: 11)
        lifecycleNotice.textColor = .secondaryLabelColor
        copyStatus.font = .systemFont(ofSize: 11)
        copyStatus.textColor = .secondaryLabelColor
        controlButton.target = self
        controlButton.action = #selector(changeControlPermission(_:))
        controlButton.toolTip = "Allow bounded mouse and keyboard actions for this connection only. Local clicks, scrolling or keys revoke control."
        controlStatus.font = .systemFont(ofSize: 11)
        controlStatus.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [
            heading, privacyNotice, statusField, endpointField,
            controlButton, controlStatus, lifecycleNotice, buttons, copyStatus
        ])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for field in [privacyNotice, statusField, controlStatus, lifecycleNotice, copyStatus] {
            field.widthAnchor.constraint(equalToConstant: 540).isActive = true
        }

        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])

        server.didChange = { [weak self] in
            self?.refresh()
        }
        refresh()
    }

    required init?(coder: NSCoder) {
        fatalError("MCPServerWindow uses a programmatic window")
    }

    private func refresh() {
        statusField.stringValue = server.status
        endpointField.stringValue = server.endpoint ?? "Not listening"
        startButton.title = server.active ? "Stop Server" : "Start Server"
        tokenButton.isEnabled = server.endpoint != nil
        configButton.isEnabled = server.endpoint != nil
        copyStatus.stringValue = ""
        controlButton.isEnabled = server.controlAvailable
        controlButton.state = server.controlEnabled ? .on : .off
        controlStatus.stringValue = server.controlStatus
    }

    @objc private func changeControlPermission(_ sender: Any?) {
        server.setControlEnabled(controlButton.state == .on)
    }

    @objc private func toggleServer(_ sender: Any?) {
        if server.active {
            server.stop()
        } else {
            server.start()
        }
    }

    @objc private func copyToken(_ sender: Any?) {
        guard server.endpoint != nil, let token = server.token else { return }
        showCopyResult(copyLocal(token))
    }

    @objc private func copyConfig(_ sender: Any?) {
        guard let endpoint = server.endpoint, let token = server.token else { return }

        let serverConfiguration: [String: Any] = [
            "type": "http",
            "url": endpoint,
            "headers": ["Authorization": "Bearer \(token)"]
        ]
        let configuration = ["mcpServers": ["sharedesk": serverConfiguration]]
        guard let data = try? JSONSerialization.data(
            withJSONObject: configuration,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        ), let text = String(data: data, encoding: .utf8) else {
            showCopyResult(false)
            return
        }
        showCopyResult(copyLocal(text))
    }

    private func showCopyResult(_ success: Bool) {
        if success {
            copyStatus.stringValue =
                "Copied locally. Paste only into a trusted MCP client; other Mac apps may read the clipboard."
        } else {
            copyStatus.stringValue = "Could not write to the Mac clipboard."
        }
    }

    func windowWillClose(_ notification: Notification) {
        server.stop()
    }
}
