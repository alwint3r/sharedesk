import AppKit

// This non-modal window owns only labels and one previous numeric sample.
// ViewerApplication drives refreshes with its existing main-thread timer.
@MainActor
final class ConnectionStatistics: NSWindowController, NSWindowDelegate {
    private let sessionField = NSTextField(labelWithString: "No session")
    private let resolutionField = NSTextField(labelWithString: "—")
    private let updatesField = NSTextField(labelWithString: "—")
    private let trafficField = NSTextField(labelWithString: "—")
    private let clipboardField = NSTextField(wrappingLabelWithString: "—")
    private let durationField = NSTextField(labelWithString: "—")
    private let disconnectField = NSTextField(wrappingLabelWithString: "None this launch")
    private var previousSample: SessionStatistics?

    init() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 500, height: 370),
                            styleMask: [.titled, .closable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Connection Statistics"
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        super.init(window: panel)
        panel.delegate = self
        let rows: [(String, NSTextField)] = [
            ("Session", sessionField), ("Remote resolution", resolutionField),
            ("Received updates", updatesField), ("Incoming VNC (TCP)", trafficField),
            ("Clipboard mode", clipboardField), ("Connected duration", durationField),
            ("Last disconnect", disconnectField)
        ]
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.distribution = .fill
        stack.alignment = .leading
        stack.spacing = 12
        for (title, value) in rows {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12)
            label.textColor = .secondaryLabelColor
            label.widthAnchor.constraint(equalToConstant: 146).isActive = true
            value.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
            value.isSelectable = true
            value.setAccessibilityLabel(title)
            value.widthAnchor.constraint(equalToConstant: 306).isActive = true
            let row = NSStackView(views: [label, value])
            row.orientation = .horizontal
            row.distribution = .fill
            row.alignment = .firstBaseline
            row.spacing = 8
            stack.addArrangedSubview(row)
        }
        updatesField.toolTip = "Completed framebuffer-update messages, including cursor/resize metadata. This is not displayed FPS."
        trafficField.toolTip = "Received TCP payload for this VNC socket, including control and clipboard traffic and possibly retransmissions. Excludes TCP/IP and Tailscale overhead. 1 KiB = 1024 bytes."
        durationField.toolTip = "Time since the connection became ready, measured with the session's monotonic clock. Setup time is excluded; the value freezes when the session ends."
        let note = NSTextField(wrappingLabelWithString:
            "Rates cover the latest sampling interval (about one second). Update rate is not displayed FPS; a quiet desktop can show zero. TCP bytes can arrive before decoding completes.\n\nNo latency estimate, content logging or saved statistics.")
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.widthAnchor.constraint(equalToConstant: 460).isActive = true
        stack.addArrangedSubview(note)
        stack.setCustomSpacing(20, after: stack.arrangedSubviews[rows.count - 1])
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = panel.contentView!
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20)
        ])
    }

    required init?(coder: NSCoder) { fatalError("ConnectionStatistics uses a programmatic window") }

    override func showWindow(_ sender: Any?) {
        if window?.isVisible != true { previousSample = nil }
        super.showWindow(sender)
    }

    func windowWillClose(_ notification: Notification) { previousSample = nil }

    func update(_ sample: SessionStatistics?, lastDisconnect: SessionEnd?) {
        disconnectField.stringValue = lastDisconnect?.message ?? "None this launch"
        disconnectField.toolTip = disconnectField.stringValue
        guard let sample else {
            sessionField.stringValue = "No session"
            for field in [resolutionField, updatesField, trafficField, clipboardField, durationField] { field.stringValue = "—" }
            previousSample = nil
            return
        }
        switch sample.state {
        case .connecting: sessionField.stringValue = "Connecting"
        case .connected: sessionField.stringValue = "Connected"
        case .stopping: sessionField.stringValue = "Disconnecting"
        case .finished: sessionField.stringValue = "Last session (ended)"
        }
        resolutionField.stringValue = sample.width > 0 && sample.height > 0 ? "\(sample.width) × \(sample.height) pixels" : "—"
        if sample.connectedAt != nil {
            clipboardField.stringValue = (sample.clipboardUTF8 ? "UTF-8 negotiated" : "Latin-1 fallback") +
                (sample.clipboardEnabled ? " · sharing on" : " · sharing off")
        } else { clipboardField.stringValue = "Not negotiated" }
        if let start = sample.connectedAt {
            let seconds = Int(max(0, (sample.endedAt ?? sample.sampledAt) - start))
            durationField.stringValue = String(format: "%02d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
        } else { durationField.stringValue = "Not established" }
        updatesField.stringValue = sample.state.ready ? "Sampling…" : "—"
        trafficField.stringValue = sample.state.ready ? (sample.receivedBytes == nil ? "Unavailable" : "Sampling…") : "—"
        if sample.state.ready, let previous = previousSample, previous.id == sample.id,
           previous.state.ready, sample.sampledAt > previous.sampledAt {
            let seconds = sample.sampledAt - previous.sampledAt
            if sample.framebufferUpdates >= previous.framebufferUpdates {
                updatesField.stringValue = String(format: "%.1f updates/s", Double(sample.framebufferUpdates - previous.framebufferUpdates) / seconds)
            }
            if let bytes = sample.receivedBytes, let before = previous.receivedBytes, bytes >= before {
                trafficField.stringValue = String(format: "%.1f KiB/s", Double(bytes - before) / seconds / 1024)
            }
        }
        previousSample = sample
    }
}
