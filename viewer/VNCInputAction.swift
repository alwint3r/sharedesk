import Foundation

// All coordinates are full remote-framebuffer pixels, not local view or PNG
// pixels. A plan is bound to one connection and one framebuffer size.
struct VNCInputTarget: Sendable {
    let connectionID: UUID
    let width: Int
    let height: Int
}

enum VNCInputEvent: Sendable {
    case key(UInt32, down: Bool)
    case pointer(x: Int, y: Int, buttons: UInt8)

    // Callers validate coordinates before encoding. Both local input and
    // automated actions use the same ordinary VNC packet representation.
    var packet: Data {
        switch self {
        case .key(let symbol, let down):
            var data = Data([4, down ? 1 : 0, 0, 0])
            withUnsafeBytes(of: symbol.bigEndian) { data.append(contentsOf: $0) }
            return data
        case .pointer(let x, let y, let buttons):
            var data = Data([5, buttons])
            withUnsafeBytes(of: UInt16(x).bigEndian) { data.append(contentsOf: $0) }
            withUnsafeBytes(of: UInt16(y).bigEndian) { data.append(contentsOf: $0) }
            return data
        }
    }
}

struct VNCInputStep: Sendable {
    let events: [VNCInputEvent]
    let delayAfter: TimeInterval
}

struct VNCInputPlan: Sendable {
    let target: VNCInputTarget
    let steps: [VNCInputStep]
}

struct VNCInputError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum VNCInputOutcome: Sendable {
    case sent
    case cancelled(String)
    case desktopChanged
    case timedOut
    case connectionEnded

    var message: String {
        switch self {
        case .sent:
            "Input messages, including key/button releases, were sent. Application acceptance is not confirmed."
        case .cancelled(let reason):
            "Action cancelled: \(reason) Some input may already have been sent."
        case .desktopChanged:
            "The framebuffer size changed. Remaining input was cancelled; some input may already have been sent."
        case .timedOut:
            "The input action timed out. Some input may already have been sent."
        case .connectionEnded:
            "The connection ended before input completion. Some input may already have been sent."
        }
    }
}

// A handle retains its session only while the caller observes completion.
// These methods acquire the session lock, never call VNC, and never wait for
// network I/O. The existing viewer poll drives network-operation deadlines.
struct VNCInputHandle: Sendable {
    let id: UUID
    let session: VNCSession

    func cancel(reason: String) { session.cancelInputAction(id: id, reason: reason) }
    func outcome() -> VNCInputOutcome? { session.inputOutcome(id: id) }
}

// Owned by VNCSession and accessed only under its lock. The worker retains
// only the current plan and held input needed to release it on cancellation.
struct VNCInputAction {
    let id = UUID()
    let target: VNCInputTarget
    var steps: [VNCInputStep]
    var nextStep = 0
    var nextStepAt: TimeInterval = 0
    var deadline: TimeInterval
    var heldKeys: [UInt32] = []
    var pointerX = 0
    var pointerY = 0
    var buttons: UInt8 = 0
    var cancellationReason: String?
    var outcome: VNCInputOutcome?
}
