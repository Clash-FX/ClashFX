import Darwin
import Foundation
import XCTest

final class RuntimeControlLeaseTests: XCTestCase {
    private var temporaryDirectories = [URL]()

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testLegacyOwnerPreflightDoesNotCreateLockDirectoryOrFile() throws {
        let root = try makeTemporaryDirectory()
        let lockDirectory = root.appendingPathComponent("not-created", isDirectory: true)
        let lease = RuntimeControlLease(
            lockURL: lockDirectory.appendingPathComponent("runtime-control.lock")
        )

        let result = lease.acquire { 4321 }
        guard case let .occupied(pid) = result else {
            return XCTFail("Expected the legacy runtime to block acquisition")
        }

        XCTAssertEqual(pid, 4321)
        XCTAssertFalse(lease.isHeld)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lockDirectory.path))
    }

    func testAcquireSerializesInstancesAndReleaseKeepsPersistentLockFile() throws {
        let root = try makeTemporaryDirectory()
        let lockURL = root.appendingPathComponent("ClashFX/runtime-control.lock")
        let first = RuntimeControlLease(lockURL: lockURL)
        let second = RuntimeControlLease(lockURL: lockURL)

        guard case .acquired = first.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the first lease to acquire the lock")
        }
        XCTAssertTrue(first.isHeld)

        guard case let .occupied(pid) = second.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the second lease to observe contention")
        }
        XCTAssertNil(pid)
        XCTAssertFalse(second.isHeld)

        let directoryPermissions = try filePermissions(at: lockURL.deletingLastPathComponent())
        let filePermissions = try filePermissions(at: lockURL)
        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertEqual(filePermissions, 0o600)

        first.release()
        XCTAssertFalse(first.isHeld)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))

        guard case .acquired = second.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected acquisition after release")
        }
        second.release()
    }

    func testLegacyOwnerFoundAfterFlockReleasesLeaseAndKeepsLockFile() throws {
        let root = try makeTemporaryDirectory()
        let lockURL = root.appendingPathComponent("ClashFX/runtime-control.lock")
        let lease = RuntimeControlLease(lockURL: lockURL)
        var discoveryCount = 0

        let result = lease.acquire {
            discoveryCount += 1
            return discoveryCount == 1 ? nil : 7654
        }

        guard case let .occupied(pid) = result else {
            return XCTFail("Expected the post-flock legacy check to release ownership")
        }
        XCTAssertEqual(pid, 7654)
        XCTAssertEqual(discoveryCount, 2)
        XCTAssertFalse(lease.isHeld)
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testSeparateBuildLocationsCanCoordinateThroughOneSharedFile() throws {
        let root = try makeTemporaryDirectory()
        let buildA = root.appendingPathComponent("Build A/ClashFX.app", isDirectory: true)
        let buildB = root.appendingPathComponent("Build B/ClashFX.app", isDirectory: true)
        XCTAssertNotEqual(buildA, buildB)

        // Each build uses the same per-user Application Support location.
        // The build paths are intentionally not part of the lock URL.
        let sharedLockURL = root
            .appendingPathComponent("User Library/Application Support/ClashFX", isDirectory: true)
            .appendingPathComponent("runtime-control.lock")
        let leaseA = RuntimeControlLease(lockURL: sharedLockURL)
        let leaseB = RuntimeControlLease(lockURL: sharedLockURL)

        guard case .acquired = leaseA.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the first build's lease to acquire")
        }
        guard case .occupied = leaseB.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the second build's lease to share the same lock")
        }

        leaseA.release()
        guard case .acquired = leaseB.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the second build to acquire after release")
        }
        leaseB.release()
    }

    func testProductionURLIsInSharedApplicationSupportLocation() throws {
        let applicationSupport = try XCTUnwrap(FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first)
        let expectedURL = applicationSupport
            .appendingPathComponent("ClashFX", isDirectory: true)
            .appendingPathComponent("runtime-control.lock")

        XCTAssertEqual(RuntimeControlLease.productionLockURL(), expectedURL)
    }

    func testSymlinkedDirectoryAndFileAreRefused() throws {
        let root = try makeTemporaryDirectory()
        let realDirectory = root.appendingPathComponent("real-directory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: realDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )

        let directoryLink = root.appendingPathComponent("directory-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: directoryLink, withDestinationURL: realDirectory)
        let directoryLease = RuntimeControlLease(
            lockURL: directoryLink.appendingPathComponent("runtime-control.lock")
        )
        assertUnavailable(directoryLease.acquire(existingOwner: { nil }))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: realDirectory.appendingPathComponent("runtime-control.lock").path
        ))

        let fileDirectory = root.appendingPathComponent("file-directory", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fileDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let protectedTarget = root.appendingPathComponent("protected-target")
        try Data("unchanged".utf8).write(to: protectedTarget)
        let lockURL = fileDirectory.appendingPathComponent("runtime-control.lock")
        try FileManager.default.createSymbolicLink(at: lockURL, withDestinationURL: protectedTarget)

        let fileLease = RuntimeControlLease(lockURL: lockURL)
        assertUnavailable(fileLease.acquire(existingOwner: { nil }))
        XCTAssertEqual(try String(contentsOf: protectedTarget, encoding: .utf8), "unchanged")
    }

    func testNonDirectoryParentIsRefused() throws {
        let root = try makeTemporaryDirectory()
        let regularFile = root.appendingPathComponent("regular-file")
        try Data("keep".utf8).write(to: regularFile)

        let lease = RuntimeControlLease(
            lockURL: regularFile.appendingPathComponent("runtime-control.lock")
        )
        assertUnavailable(lease.acquire(existingOwner: { nil }))
        XCTAssertEqual(try String(contentsOf: regularFile, encoding: .utf8), "keep")
    }

    func testIndependentProcessSeesContentionAndCanAcquireAfterRelease() throws {
        try requirePython3()
        let root = try makeTemporaryDirectory()
        let lockURL = root.appendingPathComponent("ClashFX/runtime-control.lock")
        let lease = RuntimeControlLease(lockURL: lockURL)

        guard case .acquired = lease.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the test process to acquire the lock")
        }
        let blockedChild = try runPythonLockHelper(mode: "try", lockURL: lockURL)
        XCTAssertEqual(blockedChild.output, "occupied\n")
        XCTAssertEqual(blockedChild.process.terminationStatus, 0)

        lease.release()
        let freeChild = try runPythonLockHelper(mode: "try", lockURL: lockURL)
        XCTAssertEqual(freeChild.output, "acquired\n")
        XCTAssertEqual(freeChild.process.terminationStatus, 0)
    }

    func testKernelReleasesLockWhenSeparateOwnerProcessDies() throws {
        try requirePython3()
        let root = try makeTemporaryDirectory()
        let lockURL = root.appendingPathComponent("ClashFX/runtime-control.lock")
        let lease = RuntimeControlLease(lockURL: lockURL)

        guard case .acquired = lease.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the test process to initialize the temporary lock path")
        }
        lease.release()

        let child = try startPythonLockHelper(mode: "hold", lockURL: lockURL)
        defer {
            if child.process.isRunning {
                child.process.terminate()
                child.process.waitUntilExit()
            }
        }

        let readiness = child.output.fileHandleForReading.availableData
        XCTAssertEqual(String(data: readiness, encoding: .utf8), "acquired\n")

        guard case .occupied = lease.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the test process to observe the helper's lock")
        }

        child.process.terminate()
        child.process.waitUntilExit()

        guard case .acquired = lease.acquire(existingOwner: { nil }) else {
            return XCTFail("Expected the kernel to release the lock after process death")
        }
        lease.release()
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("RuntimeControlLeaseTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func filePermissions(at url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap((attributes[.posixPermissions] as? NSNumber)?.intValue)
    }

    private func assertUnavailable(
        _ result: RuntimeControlLease.Acquisition,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        guard case .unavailable = result else {
            XCTFail("Expected acquisition to fail closed", file: file, line: line)
            return
        }
    }

    private func requirePython3() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", "pass"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            throw XCTSkip("python3 is required for the cross-process flock checks: \(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw XCTSkip("python3 is required for the cross-process flock checks")
        }
    }

    private func runPythonLockHelper(mode: String, lockURL: URL) throws -> (process: Process, output: String) {
        let child = try startPythonLockHelper(mode: mode, lockURL: lockURL)
        let data = child.output.fileHandleForReading.readDataToEndOfFile()
        child.process.waitUntilExit()
        return (child.process, String(data: data, encoding: .utf8) ?? "")
    }

    private func startPythonLockHelper(mode: String, lockURL: URL) throws -> (process: Process, output: Pipe) {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-c", Self.pythonLockScript, mode, lockURL.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        return (process, output)
    }

    private static let pythonLockScript = """
    import fcntl
    import os
    import sys
    import time

    mode, path = sys.argv[1], sys.argv[2]
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        print("occupied", flush=True)
        sys.exit(0)
    print("acquired", flush=True)
    if mode == "hold":
        while True:
            time.sleep(1)
    """
}
