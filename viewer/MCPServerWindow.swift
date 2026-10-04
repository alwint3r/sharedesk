import AppKit

// Closing this window stops access. Sign-in approval is native-only; the
// browser cannot grant it. The copied client configuration contains no secret.
@MainActor
final class MCPServerWindow: NSWindowController, NSWindowDelegate {
    let server: MCPServer
    private let copyLocal: (String) -> Bool

    private let statusField = NSTextField(wrappingLabelWithString: "")
    private let endpointField = NSTextField(labelWithString: "Not listening")
    private let copyStatus = NSTextField(wrappingLabelWithString: "")
    private let startButton = NSButton(title: "Start Server", target: nil, action: nil)
    private let configButton = NSButton(title: "Copy Client Config", target: nil, action: nil)
    private let revokeButton = NSButton(title: "Require Sign-In Again…", target: nil, action: nil)
    private let authorizationStatus = NSTextField(wrappingLabelWithString: "")
    private let approvalField = NSTextField(wrappingLabelWithString: "No pending sign-in.")
    private let approveButton = NSButton(title: "Approve Sign-In…", target: nil, action: nil)
    private let denyButton = NSButton(title: "Deny", target: nil, action: nil)
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
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 660),
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
        configButton.target = self
        configButton.action = #selector(copyConfig(_:))
        revokeButton.target = self
        revokeButton.action = #selector(requireSignInAgain(_:))
        approveButton.target = self
        approveButton.action = #selector(approveSignIn(_:))
        denyButton.target = self
        denyButton.action = #selector(denySignIn(_:))
        for button in [startButton, configButton, revokeButton, approveButton, denyButton] {
            button.bezelStyle = .glass
        }
        let buttons = NSStackView(views: [startButton, configButton, revokeButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10

        let approvalButtons = NSStackView(views: [approveButton, denyButton])
        approvalButtons.orientation = .horizontal
        approvalButtons.spacing = 10
        authorizationStatus.font = .systemFont(ofSize: 11)
        authorizationStatus.textColor = .secondaryLabelColor
        approvalField.font = .systemFont(ofSize: 12, weight: .medium)
        approvalField.setAccessibilityLabel("Pending MCP sign-in")

        let lifecycleNotice = NSTextField(wrappingLabelWithString:
            "Off each launch. Configure your MCP client once, then use its sign-in action. Compare the browser's " +
            "code here before approving. A public client ID does not verify the requesting application's identity.\n\n" +
            "Approvals are kept in Keychain for up to 30 days. Clients can refresh short-lived tokens automatically. " +
            "Stop or closing this window ends current access, but approved clients can return on the next Start. " +
            "Require Sign-In Again revokes remembered access without changing the URL."
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
            controlButton, controlStatus, lifecycleNotice, buttons, copyStatus,
            authorizationStatus, approvalField, approvalButtons
        ])
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        for field in [privacyNotice, statusField, controlStatus, lifecycleNotice, copyStatus, authorizationStatus, approvalField] {
            field.widthAnchor.constraint(equalToConstant: 580).isActive = true
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
        endpointField.stringValue = MCPAuthorization.resource + (server.endpoint == nil ? " · stopped" : "")
        startButton.title = server.active ? "Stop Server" : "Start Server"
        revokeButton.isEnabled = server.endpoint != nil
        authorizationStatus.stringValue = server.authorization.status
        let pendingCode = server.authorization.pendingApprovalCode
        approvalField.stringValue = pendingCode.map { "Pending sign-in code: \($0) — compare with your browser." } ?? "No pending sign-in."
        approveButton.isEnabled = pendingCode != nil
        denyButton.isEnabled = pendingCode != nil
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

    @objc private func approveSignIn(_ sender: Any?) {
        guard let code = server.authorization.pendingApprovalCode, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Authorize this sign-in for up to 30 days?"
        alert.informativeText = "Approve only if you started sign-in in your MCP client and the browser shows \(code). " +
            "The client can read screenshots whenever you start this server, including future VNC connections. " +
            "Screenshots may reach its AI provider. Input also requires Allow MCP Control."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Approve")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn {
                self?.server.authorization.decideApproval(code: code, allow: true)
            }
        }
    }

    @objc private func denySignIn(_ sender: Any?) {
        guard let code = server.authorization.pendingApprovalCode else { return }
        server.authorization.decideApproval(code: code, allow: false)
    }

    @objc private func requireSignInAgain(_ sender: Any?) {
        guard server.endpoint != nil, let window else { return }
        let alert = NSAlert()
        alert.messageText = "Revoke every remembered MCP sign-in?"
        alert.informativeText = "This turns control off, cancels unfinished MCP actions and invalidates all client credentials. " +
            "The VNC connection stays open. Sign in again from your MCP client. Its configuration does not change."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Revoke Sign-Ins")
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertSecondButtonReturn {
                self?.server.authorization.requireSignInAgain()
            }
        }
    }

    @objc private func copyConfig(_ sender: Any?) {
        let serverConfiguration: [String: Any] = [
            "type": "http",
            "url": MCPAuthorization.resource,
            "oauth": ["clientId": MCPAuthorization.clientID]
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
                "Copied client configuration; no secret included. Replace the old sharedesk entry in your MCP client."
        } else {
            copyStatus.stringValue = "Could not write to the Mac clipboard."
        }
    }

    func windowWillClose(_ notification: Notification) {
        server.stop()
    }
}
