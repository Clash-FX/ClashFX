import Darwin
import Foundation

/// One wall-clock budget covers connect, partial writes and fragmented reads.
/// In particular, SO_SNDTIMEO alone does not bound a TCP connect.
enum BoundedDNSProbe {
    static func query(host: String, port: Int, type: Int32, payload: [UInt8],
                      timeout: TimeInterval = 0.6) -> Data? {
        guard (1 ... 65535).contains(port), timeout > 0 else { return nil }
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        var noSignal: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size))
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        func waitFor(_ events: Int16) -> Bool {
            while ProcessInfo.processInfo.systemUptime < deadline {
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let remaining = deadline - ProcessInfo.processInfo.systemUptime
                let milliseconds = Int32(max(1, min(Double(Int32.max), ceil(remaining * 1000))))
                let result = poll(&descriptor, 1, milliseconds)
                if result > 0 {
                    return descriptor.revents & (events | Int16(POLLHUP) | Int16(POLLERR)) != 0
                }
                if result < 0, errno == EINTR { continue }
                return false
            }
            return false
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &address.sin_addr) == 1 else { return nil }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if connected != 0 {
            guard errno == EINPROGRESS, waitFor(Int16(POLLOUT)) else { return nil }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else { return nil }
        }
        var request = payload
        if type == SOCK_STREAM {
            guard payload.count <= 65535 else { return nil }
            request.insert(UInt8(payload.count & 0xff), at: 0)
            request.insert(UInt8((payload.count >> 8) & 0xff), at: 0)
        }
        let sent = request.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            var total = 0
            while total < raw.count, ProcessInfo.processInfo.systemUptime < deadline {
                let count = send(fd, base.advanced(by: total), raw.count - total, 0)
                if count > 0 {
                    if type == SOCK_DGRAM, count != raw.count { return false }
                    total += count
                } else if count < 0, errno == EINTR {
                    continue
                } else if count < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                    guard waitFor(Int16(POLLOUT)) else { return false }
                } else {
                    return false
                }
            }
            return total == raw.count
        }
        guard sent else { return nil }
        func receive(_ length: Int) -> Data? {
            while waitFor(Int16(POLLIN)) {
                var bytes = [UInt8](repeating: 0, count: length)
                let count = recv(fd, &bytes, length, 0)
                if count > 0 { return Data(bytes.prefix(count)) }
                if count < 0, errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK { continue }
                return nil
            }
            return nil
        }
        if type == SOCK_STREAM {
            return EnhancedModeDNSReadinessPolicy.readTCPMessage(readChunk: receive)
        }
        return receive(4096)
    }
}

/// Persist before changing system settings; JSON preserves explicit absent DNS
/// dictionaries without putting NSNull into a UserDefaults property list.
final class TunDNSSnapshotStore {
    private static let maximumJournalSize = 1_048_576
    private let defaults: UserDefaults
    private let journalURL: URL

    init(defaults: UserDefaults, journalURL: URL) {
        self.defaults = defaults
        self.journalURL = journalURL
    }

    func load() -> [String: Any] {
        var pathInfo = stat()
        let pathStatus = journalURL.path.withCString { Darwin.lstat($0, &pathInfo) }
        guard pathStatus == 0 else {
            guard errno == ENOENT else {
                return ["error": "Cannot inspect the DNS recovery journal: \(String(cString: strerror(errno)))"]
            }
            return defaults.dictionary(forKey: "kSavedDNSInfo") ?? [:]
        }

        let flags = O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        let descriptor = journalURL.path.withCString { Darwin.open($0, flags) }
        guard descriptor >= 0 else {
            return ["error": "Cannot open the DNS recovery journal: \(String(cString: strerror(errno)))"]
        }
        defer { Darwin.close(descriptor) }

        var fileInfo = stat()
        guard Darwin.fstat(descriptor, &fileInfo) == 0 else {
            return ["error": "Cannot inspect the DNS recovery journal: \(String(cString: strerror(errno)))"]
        }
        guard (fileInfo.st_mode & S_IFMT) == S_IFREG else {
            return ["error": "The DNS recovery journal is not a regular file"]
        }
        guard fileInfo.st_size >= 0,
              UInt64(fileInfo.st_size) <= UInt64(Self.maximumJournalSize) else {
            return ["error": "The DNS recovery journal exceeds the 1 MiB size limit"]
        }

        var data = Data()
        let readLimit = Self.maximumJournalSize + 1
        let chunkSize = 64 * 1024
        data.reserveCapacity(chunkSize)
        var buffer = [UInt8](repeating: 0, count: chunkSize)
        while data.count < readLimit {
            let requested = min(buffer.count, readLimit - data.count)
            let count = buffer.withUnsafeMutableBufferPointer { bytes in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(descriptor, UnsafeMutableRawPointer(baseAddress), requested)
            }
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                break
            } else if errno != EINTR {
                return ["error": "Cannot read the DNS recovery journal: \(String(cString: strerror(errno)))"]
            }
        }
        guard data.count <= Self.maximumJournalSize else {
            return ["error": "The DNS recovery journal exceeds the 1 MiB size limit"]
        }
        do {
            guard let snapshot = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                return ["error": "The DNS recovery journal is not a dictionary"]
            }
            return snapshot
        } catch {
            return ["error": "Cannot read the DNS recovery journal: \(error.localizedDescription)"]
        }
    }

    @discardableResult
    func save(_ snapshot: [String: Any]) -> Bool {
        do {
            if snapshot.isEmpty {
                if FileManager.default.fileExists(atPath: journalURL.path) {
                    try FileManager.default.removeItem(at: journalURL)
                }
            } else {
                let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys])
                guard data.count <= Self.maximumJournalSize else { return false }
                try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true, attributes: nil)
                try data.write(to: journalURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
            }
            defaults.removeObject(forKey: "kSavedDNSInfo")
            return true
        } catch {
            return false
        }
    }
}

struct TunDNSHelperClient {
    let capture: (Bool, @escaping ([String: Any]) -> Void) -> Void
    let apply: ([String: Any], [String], @escaping (String?) -> Void) -> Void
    let restore: ([String: Any], @escaping (String?) -> Void) -> Void
    let flush: (@escaping (String?) -> Void) -> Void
}

/// Cancels a journal clear while it is queued, without reading controller state
/// from the I/O queue. Once mutation starts, later journal work remains ordered behind it.
private final class JournalMutationToken {
    enum TimeoutResult {
        case cancelledBeforeStart
        case inProgress
        case finished(succeeded: Bool)
    }

    private enum State {
        case queued
        case cancelled
        case running
        case finished(succeeded: Bool)
    }

    private let lock = NSLock()
    private var state = State.queued

    func begin() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .queued = state else { return false }
        state = .running
        return true
    }

    func finish(succeeded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard case .running = state else { return }
        state = .finished(succeeded: succeeded)
    }

    func cancelBeforeStartOrGetResult() -> TimeoutResult {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .queued:
            state = .cancelled
            return .cancelledBeforeStart
        case .cancelled:
            return .cancelledBeforeStart
        case .running:
            return .inProgress
        case let .finished(succeeded):
            return .finished(succeeded: succeeded)
        }
    }
}

/// Serializes whole operations, including asynchronous replies and deadlines.
/// A timeout retains recovery evidence. A late reply never clears a newer journal.
final class TunDNSTransactionController {
    private let operations = SerializedAsyncOperationQueue(queue: .main)
    // Every controller read/write is submitted to this serial queue. If an
    // operation times out while I/O is running, a later operation's journal
    // work stays behind it and observes or replaces its result in order.
    private let journalIOQueue = DispatchQueue(label: "com.clashfx.tun-dns-journal", qos: .utility)
    private let load: () -> [String: Any]
    private let save: ([String: Any]) -> Bool
    private let log: (String) -> Void
    private let journalClearTimeout: TimeInterval
    private static let maximumPredecessorTransactionIDs = 64
    private var activeOperationID: UUID?
    private var activeSettlement: ManagedOperationSettlement<String?>?
    private var cacheFlushSettlement: ManagedOperationSettlement<String?>?

    init(load: @escaping () -> [String: Any], save: @escaping ([String: Any]) -> Bool,
         log: @escaping (String) -> Void, journalClearTimeout: TimeInterval = 1) {
        self.load = load
        self.save = save
        self.log = log
        self.journalClearTimeout = journalClearTimeout
    }

    static func merging(_ captured: [String: Any], previous: [String: Any], servers: [String]) -> [String: Any]? {
        guard (captured["version"] as? NSNumber)?.intValue == 2,
              let transactionID = captured["transactionID"] as? String, !transactionID.isEmpty,
              let capturedServices = captured["services"] as? [String: [String: Any]],
              !capturedServices.isEmpty else { return nil }
        guard let previousIDs = predecessorTransactionIDs(in: previous, excluding: transactionID) else { return nil }
        let previousServices = previous["services"] as? [String: [String: Any]] ?? [:]
        var services = previousServices
        for (serviceID, entry) in capturedServices {
            guard entry["original"] != nil else { return nil }
            let current = entry["original"] as? [String: Any]
            let previousEntry = previousServices[serviceID]
            let original = previousEntry?["original"] as? [String: Any] ?? [:]
            let previousServers = previous["expectedServers"] as? [String] ?? servers
            if let current, previousEntry != nil,
               current["ServerAddresses"] as? [String] == previousServers {
                // Keep user changes to search domains and other DNS fields
                // made while our resolver addresses were in place.
                var preserved = current
                if let addresses = original["ServerAddresses"] {
                    preserved["ServerAddresses"] = addresses
                } else {
                    preserved.removeValue(forKey: "ServerAddresses")
                }
                let baseline: Any = preserved.isEmpty && previousEntry?["original"] is NSNull
                    ? NSNull() : preserved
                services[serviceID] = ["original": baseline]
            } else {
                services[serviceID] = entry
            }
        }
        var snapshot = captured
        snapshot["services"] = services
        snapshot["applyServiceIDs"] = capturedServices.keys.sorted()
        snapshot["expectedServers"] = servers
        snapshot["previousTransactionIDs"] = previousIDs
        return snapshot
    }

    private static func predecessorTransactionIDs(in previous: [String: Any], excluding transactionID: String) -> [String]? {
        var identifiers: [String] = []
        var seen = Set<String>()
        if let rawIDs = previous["previousTransactionIDs"] {
            guard hasValidPredecessorHistory(in: previous), let previousIDs = rawIDs as? [String] else { return nil }
            for identifier in previousIDs where identifier != transactionID && seen.insert(identifier).inserted {
                identifiers.append(identifier)
            }
        }
        if let rawPreviousID = previous["transactionID"] {
            guard let previousID = rawPreviousID as? String, !previousID.isEmpty else { return nil }
            if previousID != transactionID, seen.insert(previousID).inserted {
                identifiers.append(previousID)
            }
        }
        guard identifiers.count <= maximumPredecessorTransactionIDs else { return nil }
        return identifiers
    }

    private static func hasValidPredecessorHistory(in snapshot: [String: Any]) -> Bool {
        guard let rawIDs = snapshot["previousTransactionIDs"] else { return true }
        guard let identifiers = rawIDs as? [String],
              identifiers.count <= maximumPredecessorTransactionIDs,
              identifiers.allSatisfy({ !$0.isEmpty }),
              Set(identifiers).count == identifiers.count else { return false }
        return true
    }

    private func loadJournal(completion: @escaping ([String: Any]) -> Void) {
        journalIOQueue.async { [load = self.load] in
            let snapshot = load()
            DispatchQueue.main.async { completion(snapshot) }
        }
    }

    private func saveJournal(_ snapshot: [String: Any], mutationToken: JournalMutationToken? = nil,
                             completion: @escaping (Bool) -> Void) {
        journalIOQueue.async { [save = self.save] in
            if let mutationToken, !mutationToken.begin() {
                DispatchQueue.main.async { completion(false) }
                return
            }
            let succeeded = save(snapshot)
            mutationToken?.finish(succeeded: succeeded)
            DispatchQueue.main.async { completion(succeeded) }
        }
    }

    func apply(client: TunDNSHelperClient, servers: [String], filterInterface: Bool,
               timeout: TimeInterval, isCurrent: @escaping () -> Bool,
               completion: @escaping (String?) -> Void) {
        operations.enqueue { [weak self] done in
            guard let self else { completion("DNS operation cancelled"); done(); return }
            let operationID = UUID()
            self.activeOperationID = operationID
            let settlement = ManagedOperationSettlement<String?> { error in
                if self.activeOperationID == operationID {
                    self.activeSettlement = nil
                    self.cacheFlushSettlement = nil
                }
                completion(error)
                done()
            }
            self.activeSettlement = settlement
            settlement.scheduleTimeout(after: timeout, outcome: { "DNS apply timed out; recovery journal retained" })
            guard isCurrent() else { _ = settlement.finish("DNS operation superseded"); return }
            client.capture(filterInterface) { captured in
                DispatchQueue.main.async {
                    guard !settlement.isSettled, self.activeOperationID == operationID, isCurrent() else {
                        _ = settlement.finish("DNS operation superseded")
                        return
                    }
                    if let error = captured["error"] as? String {
                        _ = settlement.finish(error)
                        return
                    }
                    self.loadJournal { previous in
                        guard !settlement.isSettled, self.activeOperationID == operationID, isCurrent() else {
                            _ = settlement.finish("DNS operation superseded")
                            return
                        }
                        if let error = previous["error"] as? String {
                            _ = settlement.finish(error)
                            return
                        }
                        guard Self.hasValidPredecessorHistory(in: previous) else {
                            _ = settlement.finish(
                                "DNS recovery has too many or invalid pending predecessor transactions; restore the existing snapshot before applying again"
                            )
                            return
                        }
                        if !Self.isSupportedJournal(previous) {
                            _ = settlement.finish("Unsupported DNS journal version; recovery evidence retained")
                            return
                        }
                        guard previous.isEmpty || previous["services"] != nil else {
                            _ = settlement.finish("An earlier DNS snapshot must be restored before applying new settings")
                            return
                        }
                        if let transactionID = captured["transactionID"] as? String,
                           Self.predecessorTransactionIDs(in: previous, excluding: transactionID) == nil {
                            _ = settlement.finish(
                                "DNS recovery has too many or invalid pending predecessor transactions; restore the existing snapshot before applying again"
                            )
                            return
                        }
                        guard let snapshot = Self.merging(captured, previous: previous, servers: servers) else {
                            _ = settlement.finish("DNS capture did not identify any eligible network services")
                            return
                        }
                        self.saveJournal(snapshot) { saved in
                            guard !settlement.isSettled, self.activeOperationID == operationID, isCurrent() else {
                                _ = settlement.finish("DNS operation superseded; recovery journal retained")
                                return
                            }
                            guard saved else {
                                _ = settlement.finish("Cannot persist the DNS recovery journal; system DNS was not changed")
                                return
                            }
                            client.apply(snapshot, servers) { error in
                                DispatchQueue.main.async {
                                    guard !settlement.isSettled, self.activeOperationID == operationID, isCurrent() else {
                                        _ = settlement.finish("DNS operation superseded; recovery journal retained")
                                        return
                                    }
                                    if let error { _ = settlement.finish(error); return }
                                    let previousIDs = snapshot["previousTransactionIDs"] as? [String] ?? []
                                    guard !previousIDs.isEmpty else {
                                        self.flushAfterApply(client: client, operationID: operationID,
                                                             settlement: settlement, isCurrent: isCurrent)
                                        return
                                    }
                                    var compactedSnapshot = snapshot
                                    compactedSnapshot["previousTransactionIDs"] = [String]()
                                    self.prunePredecessorsAfterApply(snapshot: snapshot, compactedSnapshot: compactedSnapshot,
                                                                     client: client, operationID: operationID,
                                                                     settlement: settlement, isCurrent: isCurrent)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func prunePredecessorsAfterApply(snapshot: [String: Any], compactedSnapshot: [String: Any],
                                             client: TunDNSHelperClient, operationID: UUID,
                                             settlement: ManagedOperationSettlement<String?>,
                                             isCurrent: @escaping () -> Bool) {
        loadJournal { currentSnapshot in
            guard !settlement.isSettled, self.activeOperationID == operationID, isCurrent() else {
                _ = settlement.finish("DNS operation superseded; recovery journal retained")
                return
            }
            guard NSDictionary(dictionary: currentSnapshot).isEqual(to: snapshot) else {
                self.log("DNS apply succeeded, but its recovery journal changed before predecessor pruning; existing history retained")
                self.flushAfterApply(client: client, operationID: operationID,
                                     settlement: settlement, isCurrent: isCurrent)
                return
            }
            self.saveJournal(compactedSnapshot) { saved in
                guard !settlement.isSettled, self.activeOperationID == operationID, isCurrent() else {
                    _ = settlement.finish("DNS operation superseded; recovery journal retained")
                    return
                }
                if !saved {
                    self.log("DNS apply succeeded, but predecessor pruning failed; the existing recovery history was retained")
                }
                self.flushAfterApply(client: client, operationID: operationID,
                                     settlement: settlement, isCurrent: isCurrent)
            }
        }
    }

    private func flushAfterApply(client: TunDNSHelperClient, operationID: UUID,
                                 settlement: ManagedOperationSettlement<String?>,
                                 isCurrent: @escaping () -> Bool) {
        guard !settlement.isSettled, activeOperationID == operationID, isCurrent() else {
            _ = settlement.finish("DNS operation superseded")
            return
        }
        client.flush { error in
            DispatchQueue.main.async {
                guard !settlement.isSettled, self.activeOperationID == operationID, isCurrent() else {
                    _ = settlement.finish("DNS operation superseded")
                    return
                }
                _ = settlement.finish(error.map { "DNS applied, but cache refresh failed: \($0)" })
            }
        }
    }

    func restore(client: TunDNSHelperClient, timeout: TimeInterval,
                 isCurrent: @escaping () -> Bool = { true },
                 completion: @escaping (String?) -> Void) {
        operations.enqueue { [weak self] done in
            guard let self else { completion("DNS recovery cancelled"); done(); return }
            guard isCurrent() else { completion("DNS recovery superseded"); done(); return }
            let operationID = UUID()
            self.activeOperationID = operationID
            let settlement = ManagedOperationSettlement<String?> { error in
                if self.activeOperationID == operationID {
                    self.activeSettlement = nil
                    self.cacheFlushSettlement = nil
                }
                completion(error)
                done()
            }
            self.activeSettlement = settlement
            settlement.scheduleTimeout(after: timeout, outcome: { "DNS restore timed out; recovery journal retained" })
            self.loadJournal { snapshot in
                guard !settlement.isSettled, self.activeOperationID == operationID else { return }
                guard isCurrent() else { _ = settlement.finish("DNS recovery superseded; journal retained"); return }
                guard !snapshot.isEmpty else { _ = settlement.finish(nil); return }
                if let error = snapshot["error"] as? String { _ = settlement.finish(error); return }
                guard Self.isSupportedJournal(snapshot) else {
                    _ = settlement.finish("Unsupported DNS journal version; recovery evidence retained")
                    return
                }
                client.restore(snapshot) { error in
                    DispatchQueue.main.async {
                        guard !settlement.isSettled, self.activeOperationID == operationID else { return }
                        if let error { _ = settlement.finish(error); return }
                        guard isCurrent() else {
                            _ = settlement.finish("DNS recovery superseded; journal retained")
                            return
                        }
                        self.loadJournal { currentSnapshot in
                            guard !settlement.isSettled, self.activeOperationID == operationID else { return }
                            guard isCurrent() else {
                                _ = settlement.finish("DNS recovery superseded; journal retained")
                                return
                            }
                            guard NSDictionary(dictionary: currentSnapshot).isEqual(to: snapshot) else {
                                _ = settlement.finish("DNS recovery journal changed during restore; newer snapshot retained")
                                return
                            }
                            // The helper restore and snapshot comparison authorize
                            // the clear. Replace the restore timer with a bounded,
                            // cancellable clear deadline before enqueueing mutation.
                            settlement.cancelTimeout()
                            let clearToken = JournalMutationToken()
                            settlement.scheduleTimeout(after: self.journalClearTimeout, outcome: {
                                switch clearToken.cancelBeforeStartOrGetResult() {
                                case .cancelledBeforeStart:
                                    return "DNS restored, but recovery journal clear timed out before starting; journal retained"
                                case .inProgress:
                                    return "DNS restored, but recovery journal clear is still in progress"
                                case let .finished(succeeded):
                                    return succeeded ? nil : "DNS restored, but its recovery journal could not be cleared"
                                }
                            })
                            self.saveJournal([:], mutationToken: clearToken) { saved in
                                guard !settlement.isSettled, self.activeOperationID == operationID else { return }
                                guard saved else {
                                    _ = settlement.finish("DNS restored, but its recovery journal could not be cleared")
                                    return
                                }
                                settlement.cancelTimeout()
                                let flush = ManagedOperationSettlement<String?> { error in
                                    DispatchQueue.main.async {
                                        if let error {
                                            self.log("DNS settings restored and verified; cache refresh failed: \(error)")
                                        }
                                        // Restored DNS is safe even if a best-effort cache refresh fails.
                                        _ = settlement.finish(nil)
                                    }
                                }
                                self.cacheFlushSettlement = flush
                                flush.scheduleTimeout(after: min(1, timeout), outcome: { "cache refresh reply timed out" })
                                client.flush { error in _ = flush.finish(error) }
                            }
                        }
                    }
                }
            }
        }
    }

    private static func isSupportedJournal(_ snapshot: [String: Any]) -> Bool {
        guard hasValidPredecessorHistory(in: snapshot) else { return false }
        if let version = snapshot["version"] {
            return (version as? NSNumber)?.intValue == 2 && snapshot["services"] is [String: Any]
        }
        return snapshot["services"] == nil && snapshot["transactionID"] == nil
    }
}

final class StartupCoreRecoveryController {
    private(set) var attempts = 0
    private var deadline: TimeInterval = 0
    private var generation = 0
    private var pending: DispatchWorkItem?
    private let delays: [TimeInterval]

    init(delays: [TimeInterval] = [2, 4, 8, 16, 30]) {
        self.delays = delays
    }

    func begin(window: TimeInterval = 90, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        cancel()
        attempts = 0
        deadline = now + window
    }

    @discardableResult
    func schedule(now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                  action: @escaping () -> Void) -> Bool {
        guard pending == nil, attempts < delays.count, now + delays[attempts] < deadline else { return false }
        let token = generation
        let delay = delays[attempts]
        attempts += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self, token == self.generation else { return }
            self.pending = nil
            action()
        }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        return true
    }

    func cancelPending() {
        pending?.cancel(); pending = nil; generation += 1
    }

    func cancel() {
        cancelPending(); deadline = 0
    }
}

struct RuntimeEndpointSet: Equatable {
    let apiPort: Int
    let dnsPort: Int
    let proxyPorts: [Int]

    var validationError: String? {
        guard ([apiPort, dnsPort] + proxyPorts).allSatisfy({ (1 ... 65535).contains($0) }),
              !proxyPorts.isEmpty else { return "Runtime configuration contains invalid or missing listener ports" }
        guard apiPort != dnsPort, !proxyPorts.contains(apiPort), !proxyPorts.contains(dnsPort) else {
            return "Runtime API, DNS and proxy listeners must use distinct ports"
        }
        return nil
    }
}
