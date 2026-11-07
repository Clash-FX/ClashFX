import Darwin
import Foundation

/// Elapsed-time markers for one Enhanced Mode close/handoff transaction, so a
/// failed port bind can be placed against the external core's stop request,
/// its reply and the built-in core's start.
final class HandoffTimeline {
    private let transactionID: String
    private let started: UInt64
    private let now: () -> UInt64
    private let emit: (String) -> Void

    init(transactionID: String,
         now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
         emit: @escaping (String) -> Void) {
        self.transactionID = transactionID
        self.now = now
        self.started = now()
        self.emit = emit
    }

    func mark(_ stage: String, detail: String = "") {
        let elapsedMs = (now() - started) / 1_000_000
        let suffix = detail.isEmpty ? "" : " \(detail)"
        emit("timeline transaction=\(transactionID) stage=\(stage) t+\(elapsedMs)ms\(suffix)")
    }
}

/// Extracts the ports a core start reports as already in use, from either a
/// classified `[port_conflict]` or a raw `bind: address already in use`.
enum PortConflictParser {
    static func ports(in error: String) -> [Int] {
        var ports: [Int] = []
        if error.hasPrefix("error:[port_conflict]"),
           let range = error.range(of: #"port=(\d+)"#, options: .regularExpression),
           let port = Int(error[range].dropFirst("port=".count)) {
            ports.append(port)
        }
        if let bindFailure = try? NSRegularExpression(pattern: #":(\d+): bind: address already in use"#) {
            let text = error as NSString
            for match in bindFailure.matches(in: error, range: NSRange(location: 0, length: text.length)) {
                if let port = Int(text.substring(with: match.range(at: 1))), !ports.contains(port) {
                    ports.append(port)
                }
            }
        }
        return ports
    }
}

/// Reports whether something still accepts connections on a loopback port.
/// The owner of a root-run core cannot be named by an unprivileged app, but
/// whether the listener is still there, and for how long after a failure, can.
enum PortListenProbe {
    static func isAccepting(port: Int, timeout: TimeInterval = 0.2) -> Bool {
        guard (1 ... 65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = UInt32(0x7F00_0001).bigEndian
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&descriptor, 1, Int32(timeout * 1000)) > 0 else { return false }
        var socketError: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
        return socketError == 0
    }

    /// Blocking; call off the main queue. Samples each port at the given
    /// offsets from the call so a lingering listener shows how long it stays.
    static func sample(ports: [Int],
                       offsets: [TimeInterval] = [0, 0.25, 1.0],
                       emit: (String) -> Void) {
        let start = DispatchTime.now().uptimeNanoseconds
        for offset in offsets {
            let target = start + UInt64(offset * 1_000_000_000)
            let current = DispatchTime.now().uptimeNanoseconds
            if target > current { usleep(UInt32((target - current) / 1000)) }
            let elapsedMs = (DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            for port in ports {
                emit("listener_probe port=\(port) t+\(elapsedMs)ms accepting=\(isAccepting(port: port))")
            }
        }
    }
}
