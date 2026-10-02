import CoreGraphics
import Darwin
import Foundation
import SharedeskVNC

let clipboardLimit = 1 << 20

// Value snapshots cross the worker/UI boundary. Their Data owns its bytes;
// nothing in AppKit borrows the library's mutable framebuffer or callbacks.
struct PixelFrame: Sendable {
    let pixels: Data
    let width: Int
    let height: Int

    func image(alpha: CGImageAlphaInfo) -> CGImage? {
        guard width > 0, height > 0, pixels.count == width * height * 4,
              let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: [.byteOrder32Little, CGBitmapInfo(rawValue: alpha.rawValue)],
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

struct RemoteCursor: Sendable {
    let frame: PixelFrame
    let hotX: Int
    let hotY: Int
}

enum SessionEnd: Sendable, Equatable {
    case disconnected, setupFailed, connectionClosed, queueFull, timeout

    var message: String {
        switch self {
        case .disconnected: "Disconnected."
        case .setupFailed: "Connection or authentication failed. Check address, port and password."
        case .connectionClosed: "Connection closed or timed out."
        case .queueFull: "Input queue full; disconnected to avoid stuck input."
        case .timeout: "Network operation timed out; disconnected."
        }
    }
}

enum SessionState: Sendable, Equatable {
    case connecting, connected, stopping(SessionEnd), finished(SessionEnd)

    var ready: Bool { self == .connected }
    var finished: Bool { if case .finished = self { return true }; return false }
    var message: String {
        switch self {
        case .connecting: "Connecting…"
        case .connected: "Connected. Control = Ctrl; Command = Super. Terminal paste: Ctrl+Shift+V."
        case .stopping(let reason), .finished(let reason): reason.message
        }
    }
}

struct SessionUpdate: Sendable {
    let state: SessionState
    let frame: PixelFrame?
    let cursor: RemoteCursor?
    let clipboard: Data?
}

// The one unchecked Sendable boundary is audited here: every shared field is
// protected by lock. The opaque C client exists only as a local in run(), on
// one dedicated worker. No AppKit object or unsafe pointer crosses the lock.
final class VNCSession: @unchecked Sendable {
    private let host: String
    private let port: Int32
    private var password: String? // Worker-only after start; discarded after authentication.
    private let lock = NSLock()
    private var state: SessionState = .connecting
    private var stopReason: SessionEnd?
    private var cancelSocket: Int32 = -1 // Owned duplicate; shutdown cancels C I/O.
    private var ioDeadline: TimeInterval = 0
    private var clipboardEnabled = false
    private var packets: [Data] = []
    private var queuedBytes = 0
    private var pendingFrame: PixelFrame?
    private var pendingCursor: RemoteCursor?
    private var pendingClipboard: Data?

    init(host: String, port: Int, password: String) {
        self.host = host
        self.port = Int32(port)
        self.password = password
    }

    func start() {
        // Foundation keeps the started thread alive, and its closure keeps the
        // session alive through C callbacks, destruction and final publication.
        Thread { [self] in autoreleasepool { run() } }.start()
    }

    func stop() {
        lock.withLock {
            if stopReason == nil { stopReason = .disconnected }
            if cancelSocket >= 0 { _ = shutdown(cancelSocket, SHUT_RDWR) }
        }
    }

    func sendKey(_ symbol: UInt32, down: Bool) {
        var packet = Data([4, down ? 1 : 0, 0, 0])
        withUnsafeBytes(of: symbol.bigEndian) { packet.append(contentsOf: $0) }
        enqueue(packet)
    }

    func sendPointer(x: Int, y: Int, buttons: UInt8) {
        guard (0...65535).contains(x), (0...65535).contains(y) else { return }
        var packet = Data([5, buttons])
        withUnsafeBytes(of: UInt16(x).bigEndian) { packet.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(y).bigEndian) { packet.append(contentsOf: $0) }
        enqueue(packet)
    }

    func sendClipboard(_ text: Data) {
        guard text.count <= clipboardLimit, !text.contains(0) else { return }
        var packet = Data([6, 0, 0, 0])
        withUnsafeBytes(of: UInt32(text.count).bigEndian) { packet.append(contentsOf: $0) }
        packet.append(text)
        enqueue(packet)
    }

    private func enqueue(_ packet: Data) {
        lock.withLock {
            guard state.ready, stopReason == nil, packet.first != 6 || clipboardEnabled else { return }
            // Replace pointer motion, not transitions, wheel impulses, keys or text.
            if packet.count == 6, packet[0] == 5, packet[1] & 0x78 == 0,
               let last = packets.last, last.count == 6, last[0] == 5, last[1] == packet[1] {
                packets.removeLast()
                queuedBytes -= last.count
            }
            guard queuedBytes + packet.count <= 2 << 20, packets.count < 2048 else {
                stopReason = .queueFull
                if cancelSocket >= 0 { _ = shutdown(cancelSocket, SHUT_RDWR) }
                return
            }
            packets.append(packet)
            queuedBytes += packet.count
        }
    }

    func setClipboardSharing(_ enabled: Bool) {
        lock.withLock {
            clipboardEnabled = enabled
            pendingClipboard = nil
            if !enabled {
                packets.removeAll { packet in
                    if packet.first == 6 { queuedBytes -= packet.count; return true }
                    return false
                }
            }
        }
    }

    // Main thread calls this regularly, including during connect/cancel. The
    // caller drives the deadline check; an unchanged desktop has no idle timeout.
    func poll() -> SessionUpdate {
        lock.withLock {
            if stopReason == nil, ioDeadline > 0, ProcessInfo.processInfo.systemUptime >= ioDeadline {
                stopReason = .timeout
                state = .stopping(.timeout)
                FileHandle.standardError.write(Data("Sharedesk: network operation exceeded its elapsed-time deadline\n".utf8))
                if cancelSocket >= 0 { _ = shutdown(cancelSocket, SHUT_RDWR) }
            }
            let update = SessionUpdate(state: state, frame: pendingFrame, cursor: pendingCursor, clipboard: pendingClipboard)
            pendingFrame = nil
            pendingCursor = nil
            pendingClipboard = nil
            return update
        }
    }

    private func beginIO(timeout: TimeInterval) {
        lock.withLock { ioDeadline = ProcessInfo.processInfo.systemUptime + timeout }
    }

    private func endIO() {
        lock.withLock { ioDeadline = 0 }
    }

    private func run() {
        let callbacks = SDVNCCallbacks(frame: receiveFrame, cursor: receiveCursor, clipboard: receiveClipboard)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var connected = false
        if let client = sd_vnc_create(callbacks, context) {
            var healthy = host.withCString { sd_vnc_connect(client, $0, port, 3) }
            if healthy {
                healthy = lock.withLock {
                    cancelSocket = dup(sd_vnc_socket(client))
                    if stopReason != nil, cancelSocket >= 0 { _ = shutdown(cancelSocket, SHUT_RDWR) }
                    return cancelSocket >= 0 && stopReason == nil
                }
            }
            if healthy {
                beginIO(timeout: 5)
                healthy = (password ?? "").withCString { sd_vnc_authenticate(client, $0) }
                endIO()
            }
            password = nil
            if healthy {
                beginIO(timeout: 5)
                healthy = sd_vnc_initialize_framebuffer(client)
                endIO()
            }
            connected = lock.withLock {
                guard healthy, stopReason == nil else { return false }
                state = .connected
                return true
            }
            while healthy && connected {
                let batch: (stopping: Bool, packets: [Data]) = lock.withLock {
                    let batch = (stopReason != nil, packets)
                    packets = []
                    queuedBytes = 0
                    return batch
                }
                if batch.stopping { break }
                for packet in batch.packets {
                    let skip = lock.withLock { stopReason != nil || (packet.first == 6 && !clipboardEnabled) }
                    if skip { continue }
                    beginIO(timeout: 20)
                    healthy = packet.withUnsafeBytes { bytes in
                        sd_vnc_write(client, bytes.bindMemory(to: UInt8.self).baseAddress, bytes.count)
                    }
                    endIO()
                    if !healthy { break }
                }
                if !healthy { break }
                let ready = sd_vnc_wait(client, 10_000)
                if ready < 0 { healthy = false }
                else if ready > 0 {
                    beginIO(timeout: 20)
                    healthy = autoreleasepool { sd_vnc_process_message(client) }
                    endIO()
                }
            }
            lock.withLock {
                if cancelSocket >= 0 { _ = close(cancelSocket); cancelSocket = -1 }
            }
            sd_vnc_destroy(client)
        }
        password = nil
        lock.withLock {
            state = .finished(stopReason ?? (connected ? .connectionClosed : .setupFailed))
            packets = []
            queuedBytes = 0
            pendingFrame = nil
            pendingCursor = nil
            pendingClipboard = nil
        }
    }

    fileprivate func acceptFrame(_ pixels: UnsafePointer<UInt8>, width: Int, height: Int) {
        let frame = PixelFrame(pixels: Data(bytes: pixels, count: width * height * 4), width: width, height: height)
        lock.withLock { pendingFrame = frame } // Latest only; never an unbounded video queue.
    }

    fileprivate func acceptCursor(_ pixels: UnsafePointer<UInt8>, mask: UnsafePointer<UInt8>, width: Int, height: Int, hotX: Int, hotY: Int) {
        guard width > 0, height > 0, width <= 1024, height <= 1024,
              (0..<width).contains(hotX), (0..<height).contains(hotY) else { return }
        var data = Data(count: width * height * 4)
        data.withUnsafeMutableBytes { destination in
            for index in 0..<(width * height) {
                let rgb = UnsafeRawPointer(pixels).load(fromByteOffset: index * 4, as: UInt32.self)
                let argb = mask[index] != 0 ? rgb | 0xff000000 : 0
                destination.storeBytes(of: argb, toByteOffset: index * 4, as: UInt32.self)
            }
        }
        let cursor = RemoteCursor(frame: PixelFrame(pixels: data, width: width, height: height), hotX: hotX, hotY: hotY)
        lock.withLock { pendingCursor = cursor }
    }

    fileprivate func acceptClipboard(_ text: UnsafePointer<CChar>?, length: Int) {
        guard length >= 0, length <= clipboardLimit, length == 0 || text != nil else { return }
        lock.withLock {
            guard clipboardEnabled else { return }
            let data = length == 0 ? Data() : Data(bytes: text!, count: length)
            if !data.contains(0) { pendingClipboard = data }
        }
    }
}

// C callbacks cannot capture Swift closures. Their borrowed context refers to
// the session retained by the running thread until sd_vnc_destroy() completes.
private func receiveFrame(_ context: UnsafeMutableRawPointer?, _ pixels: UnsafePointer<UInt8>?, _ width: Int32, _ height: Int32) {
    guard let context, let pixels else { return }
    Unmanaged<VNCSession>.fromOpaque(context).takeUnretainedValue().acceptFrame(pixels, width: Int(width), height: Int(height))
}
private func receiveCursor(_ context: UnsafeMutableRawPointer?, _ pixels: UnsafePointer<UInt8>?, _ mask: UnsafePointer<UInt8>?, _ width: Int32, _ height: Int32, _ hotX: Int32, _ hotY: Int32) {
    guard let context, let pixels, let mask else { return }
    Unmanaged<VNCSession>.fromOpaque(context).takeUnretainedValue().acceptCursor(pixels, mask: mask, width: Int(width), height: Int(height), hotX: Int(hotX), hotY: Int(hotY))
}
private func receiveClipboard(_ context: UnsafeMutableRawPointer?, _ text: UnsafePointer<CChar>?, _ length: Int32) {
    guard let context else { return }
    Unmanaged<VNCSession>.fromOpaque(context).takeUnretainedValue().acceptClipboard(text, length: Int(length))
}
