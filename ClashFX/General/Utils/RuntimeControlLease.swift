import Darwin
import Foundation

/// A per-user, cross-process lease for controlling the embedded runtime.
///
/// The lock file is deliberately persistent. Its existence does not indicate
/// ownership; the kernel flock held by this instance is the only authority.
final class RuntimeControlLease {
    enum Acquisition {
        case acquired
        case occupied(pid: Int32?)
        case unavailable(reason: String)
    }

    private let lockURL: URL
    private let stateLock = NSRecursiveLock()
    private var lockFileDescriptor: Int32 = -1

    init(lockURL: URL) {
        self.lockURL = lockURL
    }

    /// The common per-user location used by all builds of ClashFX.
    /// This only constructs a URL; it does not create or inspect anything.
    static func productionLockURL() -> URL? {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first else {
            return nil
        }

        return applicationSupport
            .appendingPathComponent("ClashFX", isDirectory: true)
            .appendingPathComponent("runtime-control.lock", isDirectory: false)
    }

    var isHeld: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return lockFileDescriptor >= 0
    }

    /// Attempts to own the runtime, consulting legacy-process discovery both
    /// before touching the lock path and again after obtaining the flock.
    func acquire(existingOwner: () -> Int32?) -> Acquisition {
        stateLock.lock()
        defer { stateLock.unlock() }

        if lockFileDescriptor >= 0 {
            return .acquired
        }

        // A legacy owner may not know about this lock file. Do not create or
        // modify anything when discovery already found one.
        if let pid = existingOwner() {
            return .occupied(pid: pid)
        }

        guard lockURL.isFileURL else {
            return .unavailable(reason: "The runtime lock URL is not a local file URL.")
        }

        let standardizedURL = lockURL.standardizedFileURL
        let directoryURL = standardizedURL.deletingLastPathComponent()
        let fileName = standardizedURL.lastPathComponent
        guard directoryURL.path != "/" else {
            return .unavailable(reason: "The filesystem root cannot be used as the runtime lock directory.")
        }
        guard !fileName.isEmpty, fileName != ".", fileName != ".." else {
            return .unavailable(reason: "The runtime lock URL has no valid file name.")
        }

        do {
            try Self.ensureDirectoryExists(atPath: directoryURL.path)
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }

        let directoryDescriptor: Int32 = directoryURL.path.withCString { path in
            open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard directoryDescriptor >= 0 else {
            return .unavailable(reason: Self.systemError("Could not open the runtime lock directory"))
        }
        defer { _ = close(directoryDescriptor) }

        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0 else {
            return .unavailable(reason: Self.systemError("Could not inspect the runtime lock directory"))
        }
        guard directoryInfo.st_uid == getuid() else {
            return .unavailable(reason: "The runtime lock directory is not owned by the current user.")
        }
        if fchmod(directoryDescriptor, mode_t(0o700)) != 0 {
            return .unavailable(reason: Self.systemError("Could not secure the runtime lock directory"))
        }

        let existingFileStatus = fileName.withCString { name in
            var info = stat()
            let result = fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW)
            let error = result == 0 ? 0 : errno
            return (result, info, error)
        }
        if existingFileStatus.0 == 0 {
            guard (existingFileStatus.1.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
                return .unavailable(reason: "The runtime lock path is not a regular file.")
            }
            guard existingFileStatus.1.st_uid == getuid() else {
                return .unavailable(reason: "The runtime lock file is not owned by the current user.")
            }
        } else if existingFileStatus.2 != ENOENT {
            return .unavailable(reason: Self.systemError(
                "Could not inspect the runtime lock file",
                code: existingFileStatus.2
            ))
        }

        let fileDescriptor: Int32 = fileName.withCString { name in
            openat(
                directoryDescriptor,
                name,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK,
                mode_t(0o600)
            )
        }
        guard fileDescriptor >= 0 else {
            return .unavailable(reason: Self.systemError("Could not open the runtime lock file"))
        }

        var fileInfo = stat()
        guard fstat(fileDescriptor, &fileInfo) == 0 else {
            let reason = Self.systemError("Could not inspect the opened runtime lock file")
            _ = close(fileDescriptor)
            return .unavailable(reason: reason)
        }
        guard (fileInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            _ = close(fileDescriptor)
            return .unavailable(reason: "The runtime lock path is not a regular file.")
        }
        guard fileInfo.st_uid == getuid() else {
            _ = close(fileDescriptor)
            return .unavailable(reason: "The runtime lock file is not owned by the current user.")
        }
        guard fchmod(fileDescriptor, mode_t(0o600)) == 0 else {
            let reason = Self.systemError("Could not secure the runtime lock file")
            _ = close(fileDescriptor)
            return .unavailable(reason: reason)
        }

        let descriptorFlags = fcntl(fileDescriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(fileDescriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0 else {
            let reason = Self.systemError("Could not mark the runtime lock descriptor close-on-exec")
            _ = close(fileDescriptor)
            return .unavailable(reason: reason)
        }

        if flock(fileDescriptor, LOCK_EX | LOCK_NB) != 0 {
            let lockError = errno
            _ = close(fileDescriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return .occupied(pid: nil)
            }
            return .unavailable(reason: Self.systemError("Could not acquire the runtime lock", code: lockError))
        }

        if let pid = existingOwner() {
            _ = flock(fileDescriptor, LOCK_UN)
            _ = close(fileDescriptor)
            return .occupied(pid: pid)
        }

        lockFileDescriptor = fileDescriptor
        return .acquired
    }

    /// Releases the kernel lock and descriptor. The persistent lock file stays
    /// in place so all builds continue to coordinate on the same inode.
    func release() {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard lockFileDescriptor >= 0 else { return }
        let descriptor = lockFileDescriptor
        lockFileDescriptor = -1
        _ = flock(descriptor, LOCK_UN)
        _ = close(descriptor)
    }

    deinit {
        release()
    }

    private static func ensureDirectoryExists(atPath path: String) throws {
        if mkdir(path, mode_t(0o700)) == 0 {
            return
        }

        let creationError = errno
        if creationError == EEXIST {
            return
        }
        guard creationError == ENOENT else {
            throw directoryError("Could not create the runtime lock directory", code: creationError)
        }

        let parentPath = (path as NSString).deletingLastPathComponent
        guard !parentPath.isEmpty, parentPath != path else {
            throw directoryError("Could not create the runtime lock directory", code: creationError)
        }
        try ensureDirectoryExists(atPath: parentPath)
        if mkdir(path, mode_t(0o700)) != 0 && errno != EEXIST {
            throw directoryError("Could not create the runtime lock directory", code: errno)
        }
    }

    private static func directoryError(_ message: String, code: Int32) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(message): \(String(cString: strerror(code)))."]
        )
    }

    private static func systemError(_ message: String, code: Int32 = errno) -> String {
        "\(message): \(String(cString: strerror(code)))."
    }
}
