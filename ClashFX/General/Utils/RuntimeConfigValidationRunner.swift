import Darwin
import Foundation

final class RuntimeConfigValidationOperation {
    private let cancellationHandler: () -> Void

    fileprivate init(cancellationHandler: @escaping () -> Void) {
        self.cancellationHandler = cancellationHandler
    }

    func cancel() {
        cancellationHandler()
    }
}

final class RuntimeConfigValidationRunner {
    private let binary: URL
    private let resourceDirectory: URL
    private let timeout: TimeInterval

    init(binary: URL, resourceDirectory: URL, timeout: TimeInterval = 10) {
        self.binary = binary
        self.resourceDirectory = resourceDirectory
        self.timeout = timeout.isFinite ? max(0, timeout) : 10
    }

    @discardableResult
    func validate(
        file: URL,
        completion: @escaping (String?) -> Void
    ) -> RuntimeConfigValidationOperation {
        let session = ValidationSession(
            binary: binary,
            resourceDirectory: resourceDirectory,
            timeout: timeout,
            file: file,
            completion: completion
        )
        let operation = RuntimeConfigValidationOperation { session.cancel() }
        session.start()
        return operation
    }
}

private final class ValidationSession {
    private static let maximumOutputBytes = 64 * 1024
    private static let resourceNames = [
        "Country.mmdb",
        "GeoSite.dat",
        "GeoIP.dat",
        "geoip.dat",
        "geosite.dat",
        "geoip.metadb",
        "GeoLite2-Country.mmdb",
        "GeoLite2-City.mmdb",
        "GeoLite2-ASN.mmdb"
    ]

    private let lock = NSLock()
    private let binary: URL
    private let resourceDirectory: URL
    private let timeout: TimeInterval
    private let sourceFile: URL
    private var completion: ((String?) -> Void)?
    private var hasFinished = false
    private var process: Process?
    private var timeoutWorkItem: DispatchWorkItem?

    init(
        binary: URL,
        resourceDirectory: URL,
        timeout: TimeInterval,
        file: URL,
        completion: @escaping (String?) -> Void
    ) {
        self.binary = binary
        self.resourceDirectory = resourceDirectory
        self.timeout = timeout
        self.sourceFile = file
        self.completion = completion
    }

    func start() {
        // Bound preparation as well as the child; slow resource I/O must not
        // leave a validation operation running after its caller times out.
        scheduleTimeout()
        DispatchQueue.global(qos: .utility).async { [self] in
            prepareAndLaunch()
        }
    }

    func cancel() {
        finish("Configuration validation was cancelled.", stopChild: true)
    }

    private func prepareAndLaunch() {
        guard !isFinished else { return }
        guard binary.isFileURL, FileManager.default.isExecutableFile(atPath: binary.path) else {
            finish("Could not find an executable Mihomo validator.", stopChild: false)
            return
        }

        let stage = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClashFX-Config-Check-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: stage,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try prepareSnapshot(in: stage)
            guard !isFinished else {
                removeStage(stage)
                return
            }
            try copyLocalGeodata(into: stage)
            guard !isFinished else {
                removeStage(stage)
                return
            }
            try launch(in: stage)
        } catch is ValidationPreparationCancelled {
            removeStage(stage)
        } catch is ValidationOutputReaderSetupError {
            removeStage(stage)
            finish("Could not start the Mihomo validator.", stopChild: false)
        } catch let error as SnapshotReadError {
            removeStage(stage)
            finish(error.message, stopChild: false)
        } catch {
            removeStage(stage)
            finish("Could not prepare the isolated validation directory.", stopChild: false)
        }
    }

    private func prepareSnapshot(in stage: URL) throws {
        guard !isFinished else { throw ValidationPreparationCancelled() }
        let contents: Data
        do {
            contents = try Data(contentsOf: sourceFile)
        } catch {
            throw SnapshotReadError(message: "Could not read the configuration file.")
        }

        let snapshot = stage.appendingPathComponent("config.yaml", isDirectory: false)
        do {
            try contents.write(to: snapshot, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: snapshot.path
            )
            try FileManager.default.createDirectory(
                at: stage.appendingPathComponent("tmp", isDirectory: true),
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            throw SnapshotReadError(message: "Could not prepare the isolated validation directory.")
        }
    }

    private func copyLocalGeodata(into stage: URL) throws {
        for name in ValidationSession.resourceNames {
            guard !isFinished else { throw ValidationPreparationCancelled() }
            let source = resourceDirectory.appendingPathComponent(name, isDirectory: false)
            let destination = stage.appendingPathComponent(name, isDirectory: false)
            try copyRegularFileIfPresent(from: source, to: destination)
        }
    }

    private func copyRegularFileIfPresent(from source: URL, to destination: URL) throws {
        let inputDescriptor = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard inputDescriptor >= 0 else {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR {
                return
            }
            throw ValidationPreparationError()
        }
        defer { _ = Darwin.close(inputDescriptor) }

        var sourceStatus = stat()
        guard Darwin.fstat(inputDescriptor, &sourceStatus) == 0 else {
            throw ValidationPreparationError()
        }
        guard (sourceStatus.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            return
        }

        let outputDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR)
        )
        guard outputDescriptor >= 0 else {
            throw ValidationPreparationError()
        }
        defer { _ = Darwin.close(outputDescriptor) }

        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        do {
            while true {
                guard !isFinished else { throw ValidationPreparationCancelled() }
                let bytesRead = buffer.withUnsafeMutableBytes { bytes -> Int in
                    guard let baseAddress = bytes.baseAddress else { return 0 }
                    return Darwin.read(inputDescriptor, baseAddress, bytes.count)
                }
                if bytesRead == 0 { break }
                if bytesRead < 0 {
                    if errno == EINTR { continue }
                    throw ValidationPreparationError()
                }

                var offset = 0
                while offset < bytesRead {
                    let bytesWritten = buffer.withUnsafeBytes { bytes -> Int in
                        guard let baseAddress = bytes.baseAddress else { return -1 }
                        return Darwin.write(
                            outputDescriptor,
                            baseAddress.advanced(by: offset),
                            bytesRead - offset
                        )
                    }
                    if bytesWritten < 0 {
                        if errno == EINTR { continue }
                        throw ValidationPreparationError()
                    }
                    guard bytesWritten > 0 else { throw ValidationPreparationError() }
                    offset += bytesWritten
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: destination)
            throw error
        }
    }

    private func launch(in stage: URL) throws {
        guard !isFinished else {
            removeStage(stage)
            return
        }

        let output = BoundedOutputBuffer(limit: ValidationSession.maximumOutputBytes)
        let standardOutput = Pipe()
        let standardError = Pipe()
        let standardOutputReadHandle = standardOutput.fileHandleForReading
        let standardErrorReadHandle = standardError.fileHandleForReading
        let standardOutputWriteHandle = standardOutput.fileHandleForWriting
        let standardErrorWriteHandle = standardError.fileHandleForWriting
        var standardOutputReader: BoundedValidationOutputReader?
        var standardErrorReader: BoundedValidationOutputReader?
        do {
            standardOutputReader = try BoundedValidationOutputReader(
                handle: standardOutputReadHandle,
                append: { output.append($0) }
            )
            standardErrorReader = try BoundedValidationOutputReader(
                handle: standardErrorReadHandle,
                append: { output.append($0) }
            )
        } catch {
            if let standardOutputReader = standardOutputReader {
                standardOutputReader.stopAndDrain()
            } else {
                standardOutputReadHandle.closeFile()
            }
            if let standardErrorReader = standardErrorReader {
                standardErrorReader.stopAndDrain()
            } else {
                standardErrorReadHandle.closeFile()
            }
            standardOutputWriteHandle.closeFile()
            standardErrorWriteHandle.closeFile()
            throw ValidationOutputReaderSetupError()
        }
        guard let standardOutputReader = standardOutputReader,
              let standardErrorReader = standardErrorReader else {
            if let standardOutputReader = standardOutputReader {
                standardOutputReader.stopAndDrain()
            } else {
                standardOutputReadHandle.closeFile()
            }
            if let standardErrorReader = standardErrorReader {
                standardErrorReader.stopAndDrain()
            } else {
                standardErrorReadHandle.closeFile()
            }
            standardOutputWriteHandle.closeFile()
            standardErrorWriteHandle.closeFile()
            throw ValidationOutputReaderSetupError()
        }

        let temporaryDirectory = stage.appendingPathComponent("tmp", isDirectory: true)
        let child = Process()
        child.executableURL = binary
        child.arguments = [
            "-t",
            "-d", stage.path,
            "-f", stage.appendingPathComponent("config.yaml").path
        ]
        // Relative providers and data files resolve from this private home and working directory.
        child.currentDirectoryURL = stage
        child.environment = [
            "HOME": stage.path,
            "TMPDIR": temporaryDirectory.path,
            "TMP": temporaryDirectory.path,
            "TEMP": temporaryDirectory.path,
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            // -t never applies providers/listeners. Preserve the core's path
            // allowlist for existing absolute dashboard/provider references,
            // while HOME, cache.db and all generated state remain isolated.
            "SAFE_PATHS": resourceDirectory.standardizedFileURL.path,
            "LANG": "C",
            "LC_ALL": "C"
        ]
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = standardOutput
        child.standardError = standardError
        child.terminationHandler = { [self, standardOutputReader, standardErrorReader] terminatedChild in
            processDidTerminate(
                terminatedChild,
                stage: stage,
                output: output,
                standardOutputReader: standardOutputReader,
                standardErrorReader: standardErrorReader
            )
        }

        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            child.terminationHandler = nil
            standardOutputReader.stopAndDrain()
            standardErrorReader.stopAndDrain()
            standardOutputWriteHandle.closeFile()
            standardErrorWriteHandle.closeFile()
            removeStage(stage)
            return
        }
        process = child
        do {
            try child.run()
        } catch {
            process = nil
            child.terminationHandler = nil
            lock.unlock()
            standardOutputReader.stopAndDrain()
            standardErrorReader.stopAndDrain()
            standardOutputWriteHandle.closeFile()
            standardErrorWriteHandle.closeFile()
            finish("Could not start the Mihomo validator.", stopChild: false)
            removeStage(stage)
            return
        }
        lock.unlock()

        standardOutputWriteHandle.closeFile()
        standardErrorWriteHandle.closeFile()
    }

    private func processDidTerminate(
        _ child: Process,
        stage: URL,
        output: BoundedOutputBuffer,
        standardOutputReader: BoundedValidationOutputReader,
        standardErrorReader: BoundedValidationOutputReader
    ) {
        child.terminationHandler = nil
        standardOutputReader.stopAndDrain()
        standardErrorReader.stopAndDrain()
        removeStage(stage)

        lock.lock()
        if process === child {
            process = nil
        }
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        let callback = completion
        completion = nil
        let timeoutItem = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()

        timeoutItem?.cancel()
        let error = child.terminationStatus == 0
            ? nil
            : Self.describeFailure(exitCode: child.terminationStatus, output: output.string)
        dispatchCompletion(callback, error: error)
    }

    private func scheduleTimeout() {
        let item = DispatchWorkItem { [weak self] in
            self?.timeoutReached()
        }
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            item.cancel()
            return
        }
        timeoutWorkItem = item
        lock.unlock()
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + timeout,
            execute: item
        )
    }

    private func timeoutReached() {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        if let child = process, !child.isRunning {
            lock.unlock()
            return
        }
        lock.unlock()
        finish("Configuration validation timed out.", stopChild: true)
    }

    private func finish(_ error: String?, stopChild: Bool) {
        lock.lock()
        guard !hasFinished else {
            lock.unlock()
            return
        }
        hasFinished = true
        let callback = completion
        completion = nil
        let child = stopChild ? process : nil
        let timeoutItem = timeoutWorkItem
        timeoutWorkItem = nil
        lock.unlock()

        timeoutItem?.cancel()
        if let child {
            stop(child)
        }
        dispatchCompletion(callback, error: error)
    }

    private func stop(_ child: Process) {
        guard child.isRunning else { return }
        child.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.75) {
            guard child.isRunning else { return }
            let processIdentifier = child.processIdentifier
            guard processIdentifier > 0 else { return }
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    }

    private func dispatchCompletion(_ callback: ((String?) -> Void)?, error: String?) {
        guard let callback else { return }
        DispatchQueue.main.async {
            callback(error)
        }
    }

    private var isFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasFinished
    }

    private func removeStage(_ stage: URL) {
        try? FileManager.default.removeItem(at: stage)
    }

    private static func describeFailure(exitCode: Int32, output: String) -> String {
        let normalized = output.lowercased()
        if ["no such file", "file not found", "does not exist", "failed to open", "cannot open"]
            .contains(where: normalized.contains) {
            return "A local file referenced by the configuration is missing or unreadable."
        }
        if ["yaml", "syntax error", "unmarshal", "decode error"]
            .contains(where: normalized.contains) {
            return "The configuration contains invalid YAML."
        }
        if ["unknown field", "unsupported", "not supported", "invalid configuration"]
            .contains(where: normalized.contains) {
            return "The configuration contains invalid or unsupported settings."
        }
        if ["address already in use", "bind:", "listen tcp", "invalid port"]
            .contains(where: normalized.contains) {
            return "A configured listener address or port is unavailable."
        }
        return "Configuration validation failed (exit code \(exitCode))."
    }
}

private final class BoundedOutputBuffer {
    private let lock = NSLock()
    private let limit: Int
    private var bytes = Data()

    init(limit: Int) {
        self.limit = limit
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let remaining = limit - bytes.count
        guard remaining > 0 else { return }
        bytes.append(contentsOf: data.prefix(remaining))
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: bytes, as: UTF8.self)
    }
}

final class BoundedValidationOutputReader {
    private static let maximumBytesPerDrain = 64 * 1024
    private static let readChunkSize = 16 * 1024

    private let lock = NSLock()
    private let stopLock = NSLock()
    private let handle: FileHandle
    private let fileDescriptor: Int32
    private let append: (Data) -> Void
    private var isClosed = false
    private var reachedEndOfFile = false

    init(handle: FileHandle, append: @escaping (Data) -> Void) throws {
        let descriptor = handle.fileDescriptor
        let flags = Darwin.fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              Darwin.fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw ValidationOutputReaderSetupError()
        }

        self.handle = handle
        self.fileDescriptor = descriptor
        self.append = append
        handle.readabilityHandler = { [weak self] _ in
            self?.handleReadabilityNotification()
        }
    }

    func stopAndDrain() {
        stopLock.lock()
        defer { stopLock.unlock() }

        lock.lock()
        let alreadyClosed = isClosed
        lock.unlock()
        guard !alreadyClosed else { return }

        // Remove the handler without holding the read lock. The final lock
        // below waits for any callback already draining the descriptor.
        handle.readabilityHandler = nil

        lock.lock()
        defer { lock.unlock() }
        guard !isClosed else { return }

        isClosed = true
        _ = drainAvailableLocked(maximumBytes: Self.maximumBytesPerDrain)
        handle.closeFile()
    }

    func handleReadabilityNotification() {
        lock.lock()
        guard !isClosed, !reachedEndOfFile else {
            lock.unlock()
            return
        }
        let reachedEndOfFile = drainAvailableLocked(maximumBytes: Self.maximumBytesPerDrain)
        if reachedEndOfFile {
            handle.readabilityHandler = nil
        }
        lock.unlock()
    }

    @discardableResult
    private func drainAvailableLocked(maximumBytes: Int) -> Bool {
        guard !reachedEndOfFile else { return true }
        var remaining = maximumBytes
        var drained = Data()

        while remaining > 0 {
            let chunkSize = min(Self.readChunkSize, remaining)
            var chunk = [UInt8](repeating: 0, count: chunkSize)
            let bytesRead = chunk.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(fileDescriptor, baseAddress, bytes.count)
            }

            if bytesRead > 0 {
                drained.append(contentsOf: chunk.prefix(bytesRead))
                remaining -= bytesRead
            } else if bytesRead == 0 {
                reachedEndOfFile = true
                break
            } else if errno == EINTR {
                continue
            } else if errno == EAGAIN || errno == EWOULDBLOCK {
                break
            } else {
                reachedEndOfFile = true
                break
            }
        }

        if !drained.isEmpty {
            append(drained)
        }
        return reachedEndOfFile
    }
}

private struct SnapshotReadError: Error {
    let message: String
}

private struct ValidationOutputReaderSetupError: Error {}
private struct ValidationPreparationError: Error {}
private struct ValidationPreparationCancelled: Error {}
