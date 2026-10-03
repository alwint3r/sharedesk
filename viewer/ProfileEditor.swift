import AppKit

// The caller retains this form throughout its modal interaction. No Keychain
// password is read into the editor; an empty field can keep an existing item.
@MainActor
final class ProfileEditor: NSObject {
    let alert = NSAlert()
    let nameField: NSTextField
    let hostField: NSTextField
    let portField: NSTextField
    let passwordField = NSSecureTextField()
    let clipboardButton: NSButton
    let rememberButton: NSButton

    init(profile: ConnectionProfile?, host: String, port: String, shareClipboard: Bool) {
        nameField = NSTextField(string: profile?.name ?? "")
        nameField.placeholderString = "Ubuntu desktop"
        hostField = NSTextField(string: profile?.target.host ?? host)
        hostField.placeholderString = "Tailscale IPv4"
        portField = NSTextField(string: profile.map { String($0.target.port) } ?? port)
        clipboardButton = NSButton(checkboxWithTitle: "Share text clipboard (Latin-1)", target: nil, action: nil)
        clipboardButton.state = (profile?.shareClipboard ?? shareClipboard) ? .on : .off
        rememberButton = NSButton(checkboxWithTitle: "Remember password in macOS Keychain", target: nil, action: nil)
        rememberButton.state = profile?.passwordReference != nil ? .on : .off
        super.init()
        rememberButton.target = self
        rememberButton.action = #selector(rememberChanged(_:))
        passwordField.placeholderString = profile?.passwordReference != nil ? "Leave blank to keep the saved password" : "VNC password"
        passwordField.isEnabled = rememberButton.state == .on
        alert.messageText = profile == nil ? "Add Connection Profile" : "Edit Connection Profile"
        alert.informativeText = "Profile settings are saved on this Mac. Passwords are saved only in Keychain when enabled. Changing the address or port requires a new saved password."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let form = NSStackView(views: [
            NSTextField(labelWithString: "Name"), nameField,
            NSTextField(labelWithString: "Host"), hostField,
            NSTextField(labelWithString: "Port"), portField,
            clipboardButton, rememberButton,
            NSTextField(labelWithString: "Saved password"), passwordField
        ])
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 8
        for label in form.arrangedSubviews.compactMap({ $0 as? NSTextField }) where !label.isEditable {
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .labelColor
        }
        for (field, title) in [(nameField, "Profile name"), (hostField, "Host address"), (portField, "Port"), (passwordField, "Saved password")] {
            field.controlSize = .large
            field.font = .systemFont(ofSize: 13)
            field.setAccessibilityLabel(title)
            field.widthAnchor.constraint(equalToConstant: 440).isActive = true
        }
        form.setFrameSize(form.fittingSize)
        alert.accessoryView = form
        alert.window.initialFirstResponder = nameField
    }

    @objc private func rememberChanged(_ sender: Any?) {
        passwordField.isEnabled = rememberButton.state == .on
        if rememberButton.state != .on { passwordField.stringValue = "" }
    }
}
