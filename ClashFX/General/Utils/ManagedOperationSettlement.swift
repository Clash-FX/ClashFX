//
//  ManagedOperationSettlement.swift
//  ClashFX
//

import Foundation

/// Keeps a small, private record of recovery diagnostics independently of the
/// rotating application log. Calls are ordered and all file I/O stays off the
/// caller's queue.
final class RecoveryEventJournal {
    static let maximumFileSizeBytes = 256 * 1024
    static let maximumRecordSizeBytes = 8 * 1024

    private enum JournalError: Error {
        case unexpectedFileType
        case fileCreationFailed
        case streamUnavailable
        case incompleteWrite
    }

    private let directoryURL: URL
    private let queue = DispatchQueue(label: "com.clashfx.recovery-event-journal", qos: .utility)
    private let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private var sequence: UInt64 = 0
    private var sequenceLoaded = false

    init(directory: URL) {
        directoryURL = directory.standardizedFileURL
    }

    /// Enqueues one already-filtered event. The content is bounded before it
    /// reaches the serial queue so a malformed caller cannot retain a huge log.
    func append(_ record: String) {
        let singleLine = record
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        let prefixReserve = "seq=\(UInt64.max) time=2000-01-01T00:00:00.000Z ".utf8.count
        let contentLimit = max(0, Self.maximumRecordSizeBytes - prefixReserve - 1)
        let boundedRecord = Self.utf8Prefix(singleLine, maximumBytes: contentLimit)
        queue.async {
            self.appendOnQueue(boundedRecord)
        }
    }

    /// Waits for earlier append requests. Intended for focused verification.
    func flushForTesting() {
        queue.sync {}
    }

    private var currentFileURL: URL {
        directoryURL.appendingPathComponent("events.log", isDirectory: false)
    }

    private var previousFileURL: URL {
        directoryURL.appendingPathComponent("events.previous.log", isDirectory: false)
    }

    private func appendOnQueue(_ record: String) {
        do {
            try prepareDirectory()
            if !sequenceLoaded {
                sequence = lastStoredSequence()
                sequenceLoaded = true
            }
            guard sequence < UInt64.max else { return }
            sequence += 1

            let timestamp = timestampFormatter.string(from: Date())
            let line = Data("seq=\(sequence) time=\(timestamp) \(record)\n".utf8)
            guard line.count <= Self.maximumRecordSizeBytes else { return }
            try ensureCurrentFile()

            var currentSize = try fileSize(at: currentFileURL)
            if currentSize > Self.maximumFileSizeBytes {
                try FileManager.default.removeItem(at: currentFileURL)
                try ensureCurrentFile()
                currentSize = 0
            }
            if currentSize + line.count > Self.maximumFileSizeBytes {
                try rotateCurrentFile()
            }
            try appendData(line, to: currentFileURL)
        } catch {
            // Logging must remain best-effort: filesystem errors never escape
            // onto application or recovery callbacks.
        }
    }

    private func prepareDirectory() throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: directoryURL.path) {
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
        let attributes = try fileManager.attributesOfItem(atPath: directoryURL.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else {
            throw JournalError.unexpectedFileType
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directoryURL.path)
    }

    private func ensureCurrentFile() throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: currentFileURL.path) {
            let attributes = try fileManager.attributesOfItem(atPath: currentFileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw JournalError.unexpectedFileType
            }
        } else if !fileManager.createFile(
            atPath: currentFileURL.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ) {
            throw JournalError.fileCreationFailed
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: currentFileURL.path)
    }

    private func rotateCurrentFile() throws {
        let fileManager = FileManager.default
        let previousExists = fileManager.fileExists(atPath: previousFileURL.path)
        if previousExists {
            let attributes = try fileManager.attributesOfItem(atPath: previousFileURL.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw JournalError.unexpectedFileType
            }
            try fileManager.removeItem(at: previousFileURL)
        }
        try fileManager.moveItem(at: currentFileURL, to: previousFileURL)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: previousFileURL.path)
        try ensureCurrentFile()
    }

    private func appendData(_ data: Data, to url: URL) throws {
        guard let stream = OutputStream(url: url, append: true) else {
            throw JournalError.streamUnavailable
        }
        stream.open()
        let bytes = [UInt8](data)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBufferPointer { buffer in
                stream.write(buffer.baseAddress!.advanced(by: offset), maxLength: bytes.count - offset)
            }
            guard written > 0 else {
                let streamError = stream.streamError
                stream.close()
                throw streamError ?? JournalError.incompleteWrite
            }
            offset += written
        }
        let streamError = stream.streamError
        stream.close()
        if let streamError {
            throw streamError
        }
        try synchronizeFile(at: url)
    }

    private func synchronizeFile(at url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        if #available(macOS 10.15, *) {
            do {
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } else {
            handle.synchronizeFile()
            handle.closeFile()
        }
    }

    private func fileSize(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue else {
            throw JournalError.unexpectedFileType
        }
        return size
    }

    private func lastStoredSequence() -> UInt64 {
        for url in [currentFileURL, previousFileURL] {
            guard let size = try? fileSize(at: url), size <= Self.maximumFileSizeBytes,
                  let data = try? Data(contentsOf: url),
                  let text = String(data: data, encoding: .utf8) else {
                continue
            }
            for line in text.split(whereSeparator: \.isNewline).reversed() {
                let fields = line.split(separator: " ", maxSplits: 1)
                guard let first = fields.first, first.hasPrefix("seq="),
                      let value = UInt64(first.dropFirst(4)) else {
                    continue
                }
                return value
            }
        }
        return 0
    }

    private static func utf8Prefix(_ value: String, maximumBytes: Int) -> String {
        let bytes = Array(value.utf8)
        guard bytes.count > maximumBytes else { return value }
        var end = maximumBytes
        while end > 0 && bytes[end] & 0xC0 == 0x80 {
            end -= 1
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }
}

/// Serializes entire asynchronous operations, including their callbacks.
/// Merely dispatching their start onto a serial queue allows XPC writes to overlap.
final class SerializedAsyncOperationQueue {
    typealias Operation = (@escaping () -> Void) -> Void
    private let queue: DispatchQueue
    private var pending = [Operation]()
    private var running = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func enqueue(_ operation: @escaping Operation) {
        queue.async {
            self.pending.append(operation)
            self.startNext()
        }
    }

    private func startNext() {
        guard !running, !pending.isEmpty else { return }
        running = true
        let operation = pending.removeFirst()
        let settlement = ManagedOperationSettlement<Void> { _ in
            self.queue.async {
                self.running = false
                self.startNext()
            }
        }
        operation { _ = settlement.finish(()) }
    }
}

/// Resolves an asynchronous operation once, regardless of whether the first
/// terminal event is a result, an error, or a timeout.
final class ManagedOperationSettlement<Outcome> {
    private let lock = NSLock()
    private let completion: (Outcome) -> Void
    private var settled = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(completion: @escaping (Outcome) -> Void) {
        self.completion = completion
    }

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    @discardableResult
    func finish(_ outcome: Outcome) -> Bool {
        let completion: ((Outcome) -> Void)?
        lock.lock()
        if settled {
            completion = nil
        } else {
            settled = true
            timeoutWorkItem?.cancel()
            timeoutWorkItem = nil
            completion = self.completion
        }
        lock.unlock()

        completion?(outcome)
        return completion != nil
    }

    func scheduleTimeout(after delay: TimeInterval,
                         queue: DispatchQueue = .main,
                         outcome: @escaping () -> Outcome) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            _ = self.finish(outcome())
        }

        lock.lock()
        guard !settled else {
            lock.unlock()
            return
        }
        timeoutWorkItem?.cancel()
        timeoutWorkItem = workItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    func cancelTimeout() {
        lock.lock()
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        lock.unlock()
    }
}

struct TerminationCleanupObservation {
    let enhancedModeActive: Bool
    let proxyPortAutoSet: Bool
    let isProxySetByOther: Bool
    let currentSystemSetToClash: Bool
    let hasInterfaceProxySetToClash: Bool
    let preserveSystemProxyForFailClosed: Bool
}

struct TerminationCleanupPolicy: Equatable {
    let cleanEnhancedMode: Bool
    let cleanSystemProxy: Bool
    let forceDisableProxy: Bool

    var shouldWait: Bool {
        cleanEnhancedMode || cleanSystemProxy
    }

    static func make(observation: TerminationCleanupObservation) -> TerminationCleanupPolicy {
        let cleanSystemProxy = !observation.preserveSystemProxyForFailClosed && (
            (observation.proxyPortAutoSet && !observation.isProxySetByOther) ||
                observation.currentSystemSetToClash ||
                observation.hasInterfaceProxySetToClash
        )
        return TerminationCleanupPolicy(
            cleanEnhancedMode: observation.enhancedModeActive,
            cleanSystemProxy: cleanSystemProxy,
            // Restoring the captured settings remains the user's requested
            // behavior even when a transient network change marked them external.
            forceDisableProxy: false
        )
    }
}
