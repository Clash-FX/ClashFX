import Foundation
import XCTest

final class RuntimeConfigValidationTests: XCTestCase {
    private var temporaryDirectories = [URL]()

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testSuccessfulValidationUsesSnapshotAndOnlyCopiesGeodata() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let countryData = Data([0x43, 0x6f, 0x75, 0x6e, 0x74, 0x72, 0x79])
        let cacheData = Data("must stay out of staging".utf8)
        let config = root.appendingPathComponent("profile.yaml")
        let initialConfig = Data("mixed-port: 7890\n# initial snapshot\n".utf8)
        try countryData.write(to: resources.appendingPathComponent("Country.mmdb"))
        try cacheData.write(to: resources.appendingPathComponent("cache.db"))
        try initialConfig.write(to: config)

        let argumentRecord = root.appendingPathComponent("arguments.txt")
        let started = root.appendingPathComponent("started")
        let release = root.appendingPathComponent("release")
        let observedConfig = root.appendingPathComponent("observed-config.yaml")
        let observedCountry = root.appendingPathComponent("observed-country.mmdb")
        let observedCacheState = root.appendingPathComponent("observed-cache-state")
        let script = try makeScript(
            in: root,
            body: """
            printf '%s\\n' "$@" > \(shellQuoted(argumentRecord.path))
            touch \(shellQuoted(started.path))
            while [ ! -f \(shellQuoted(release.path)) ]; do /bin/sleep 0.01; done
            cat "$5" > \(shellQuoted(observedConfig.path))
            cat "$3/Country.mmdb" > \(shellQuoted(observedCountry.path))
            if [ -e "$3/cache.db" ]; then printf 'present' > \(shellQuoted(observedCacheState.path)); else printf 'absent' > \(shellQuoted(observedCacheState.path)); fi
            exit 0
            """
        )

        let runner = RuntimeConfigValidationRunner(binary: script, resourceDirectory: resources)
        let completed = expectation(description: "validation completion")
        var result: String? = "not completed"
        var callbackWasOnMainQueue = false
        let operation = runner.validate(file: config) { error in
            result = error
            callbackWasOnMainQueue = Thread.isMainThread
            completed.fulfill()
        }

        XCTAssertTrue(waitForFile(started, timeout: 3))
        let arguments = try String(contentsOf: argumentRecord, encoding: .utf8)
            .components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
        XCTAssertEqual(Array(arguments.prefix(2)), ["-t", "-d"])
        XCTAssertEqual(arguments.dropFirst(3).first, "-f")
        XCTAssertEqual(arguments.count, 5)
        let stagingDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
        let snapshot = URL(fileURLWithPath: arguments[4])
        XCTAssertTrue(snapshot.path.hasPrefix(stagingDirectory.path + "/"))
        XCTAssertEqual(snapshot.lastPathComponent, "config.yaml")

        try Data("mixed-port: 1\n# changed after spawn\n".utf8).write(to: config)
        try Data().write(to: release)
        wait(for: [completed], timeout: 4)

        XCTAssertNil(result)
        XCTAssertTrue(callbackWasOnMainQueue)
        XCTAssertEqual(try Data(contentsOf: observedConfig), initialConfig)
        XCTAssertEqual(try Data(contentsOf: observedCountry), countryData)
        XCTAssertEqual(try String(contentsOf: observedCacheState, encoding: .utf8), "absent")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagingDirectory.path))
        XCTAssertEqual(try Data(contentsOf: resources.appendingPathComponent("Country.mmdb")), countryData)
        XCTAssertEqual(try Data(contentsOf: resources.appendingPathComponent("cache.db")), cacheData)
        _ = operation
    }

    func testCaseAliasedGeositeResourcesDoNotFailPrivateStaging() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let upperCaseSource = resources.appendingPathComponent("GeoSite.dat")
        let lowerCaseAlias = resources.appendingPathComponent("geosite.dat")
        try Data("private geosite data".utf8).write(to: upperCaseSource)

        let linkResult = Darwin.link(upperCaseSource.path, lowerCaseAlias.path)
        if linkResult != 0 {
            XCTAssertEqual(errno, EEXIST, "The case-insensitive alias should already name the source")
        }

        var upperCaseStatus = stat()
        var lowerCaseStatus = stat()
        XCTAssertEqual(Darwin.lstat(upperCaseSource.path, &upperCaseStatus), 0)
        XCTAssertEqual(Darwin.lstat(lowerCaseAlias.path, &lowerCaseStatus), 0)
        XCTAssertEqual(upperCaseStatus.st_dev, lowerCaseStatus.st_dev)
        XCTAssertEqual(upperCaseStatus.st_ino, lowerCaseStatus.st_ino)

        let config = root.appendingPathComponent("profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: config)
        let script = try makeScript(
            in: root,
            body: """
            test -f "$3/GeoSite.dat"
            test -f "$3/geosite.dat"
            cmp -s "$3/GeoSite.dat" "$3/geosite.dat"
            exit 0
            """
        )

        let result = validate(
            binary: script,
            resources: resources,
            config: config,
            timeout: 3
        )

        XCTAssertNil(result)
    }

    func testNonzeroExitReturnsUsefulSanitizedError() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let config = root.appendingPathComponent("profile.yaml")
        try Data("proxies: []\n".utf8).write(to: config)
        let script = try makeScript(
            in: root,
            body: """
            printf 'yaml: line 2: password: node-secret-must-not-escape\\n' >&2
            printf 'proxies:\\n  - password: node-secret-must-not-escape\\n' >&2
            exit 7
            """
        )

        for attempt in 0 ..< 12 {
            let startedAt = Date()
            let result = validate(
                binary: script,
                resources: resources,
                config: config,
                timeout: 3
            )

            XCTAssertNotNil(result, "Attempt \(attempt) should classify the nonzero exit")
            XCTAssertTrue(
                result?.localizedCaseInsensitiveContains("YAML") == true,
                "Attempt \(attempt) should retain stderr through process termination"
            )
            XCTAssertFalse(result?.contains("node-secret-must-not-escape") == true)
            XCTAssertFalse(result?.contains("proxies:") == true)
            XCTAssertLessThan(
                Date().timeIntervalSince(startedAt),
                3,
                "Attempt \(attempt) should finish before its existing timeout"
            )
        }
    }

    func testOutputReaderDrainsPendingBytesWhileWriterRemainsOpen() throws {
        let pipe = Pipe()
        defer { pipe.fileHandleForWriting.closeFile() }

        let outputLock = NSLock()
        var output = Data()
        let reader = try BoundedValidationOutputReader(handle: pipe.fileHandleForReading) { data in
            outputLock.lock()
            output.append(data)
            outputLock.unlock()
        }
        let pending = Data("pending stderr without EOF".utf8)
        pipe.fileHandleForWriting.write(pending)

        let stopped = expectation(description: "output reader stops while the writer remains open")
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: 8) { _ in
                reader.stopAndDrain()
            }
            stopped.fulfill()
        }
        wait(for: [stopped], timeout: 1)

        outputLock.lock()
        let drained = output
        outputLock.unlock()
        XCTAssertEqual(drained, pending)
    }

    func testQueuedOutputCallbackCannotReadAReusedDescriptor() throws {
        let pipe = Pipe()
        let readHandle = pipe.fileHandleForReading
        let oldDescriptor = readHandle.fileDescriptor
        let outputLock = NSLock()
        var drainedOutput = Data()
        let reader = try BoundedValidationOutputReader(handle: readHandle) { data in
            outputLock.lock()
            drainedOutput.append(data)
            outputLock.unlock()
        }
        reader.stopAndDrain()
        let closedReader = reader

        var retainedReplacementDescriptors = [Int32]()
        defer {
            for descriptor in retainedReplacementDescriptors {
                _ = Darwin.close(descriptor)
            }
            pipe.fileHandleForWriting.closeFile()
        }

        var replacementReadDescriptor: Int32?
        var replacementWriteDescriptor: Int32?
        let reuseDeadline = Date().addingTimeInterval(1)
        for _ in 0 ..< 64 where replacementReadDescriptor == nil && Date() < reuseDeadline {
            var descriptors = [Int32](repeating: 0, count: 2)
            let pipeResult = descriptors.withUnsafeMutableBufferPointer { buffer -> Int32 in
                guard let baseAddress = buffer.baseAddress else { return -1 }
                return Darwin.pipe(baseAddress)
            }
            guard pipeResult == 0 else {
                return XCTFail("Could not create a natural replacement pipe")
            }

            let readDescriptor = descriptors[0]
            let writeDescriptor = descriptors[1]
            if writeDescriptor == oldDescriptor {
                _ = Darwin.close(writeDescriptor)
                retainedReplacementDescriptors.append(readDescriptor)
            } else {
                retainedReplacementDescriptors.append(readDescriptor)
                retainedReplacementDescriptors.append(writeDescriptor)
                if readDescriptor == oldDescriptor {
                    replacementReadDescriptor = readDescriptor
                    replacementWriteDescriptor = writeDescriptor
                }
            }

            if replacementReadDescriptor == nil {
                Thread.sleep(forTimeInterval: 0.005)
            }
        }
        guard let replacementReadDescriptor,
              let replacementWriteDescriptor else {
            return XCTFail("The stopped reader's descriptor was not naturally reused within one second")
        }

        XCTAssertEqual(replacementReadDescriptor, oldDescriptor)
        let flags = Darwin.fcntl(replacementReadDescriptor, F_GETFL)
        XCTAssertGreaterThanOrEqual(flags, 0)
        XCTAssertGreaterThanOrEqual(
            Darwin.fcntl(replacementReadDescriptor, F_SETFL, flags | O_NONBLOCK),
            0
        )

        let pending = Data("replacement pipe data".utf8)
        let bytesWritten = pending.withUnsafeBytes { bytes -> Int in
            guard let baseAddress = bytes.baseAddress else { return 0 }
            return Darwin.write(replacementWriteDescriptor, baseAddress, bytes.count)
        }
        XCTAssertEqual(bytesWritten, pending.count)
        // Exercise late callbacks and repeated stops while the old descriptor is reused.
        let callbacksFinished = expectation(description: "late callbacks and repeated stops finish")
        DispatchQueue.global(qos: .utility).async {
            DispatchQueue.concurrentPerform(iterations: 8) { index in
                if index.isMultiple(of: 2) {
                    closedReader.stopAndDrain()
                } else {
                    closedReader.handleReadabilityNotification()
                }
            }
            callbacksFinished.fulfill()
        }
        wait(for: [callbacksFinished], timeout: 1)

        withExtendedLifetime((pipe, readHandle, closedReader)) {
            outputLock.lock()
            let callbackOutput = drainedOutput
            outputLock.unlock()
            XCTAssertTrue(callbackOutput.isEmpty, "A queued callback must not drain the replacement pipe")

            var descriptorStatus = stat()
            XCTAssertEqual(Darwin.fstat(oldDescriptor, &descriptorStatus), 0)
            var received = [UInt8](repeating: 0, count: pending.count)
            let bytesRead = received.withUnsafeMutableBytes { bytes -> Int in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return Darwin.read(oldDescriptor, baseAddress, bytes.count)
            }
            let readError = errno
            XCTAssertEqual(bytesRead, pending.count, "read errno: \(readError)")
            XCTAssertEqual(Data(received), pending)
        }
    }

    func testMissingGVisorCapabilityReportsActionableSanitizedError() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let config = root.appendingPathComponent("config.yaml")
        try Data("tun: {enable: true, stack: gvisor}".utf8).write(to: config)
        let script = try makeScript(in: root, body: "printf 'Core capability error: unsupported_tun_stack_build: node-secret-must-not-escape' >&2; exit 1")
        let result = validate(binary: script, resources: resources, config: config, timeout: 3)
        XCTAssertTrue(result?.contains("gVisor") == true)
        XCTAssertTrue(result?.contains("with_gvisor") == true)
        XCTAssertFalse(result?.contains("node-secret") == true)
    }

    func testMissingExecutableReturnsFailure() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let config = root.appendingPathComponent("profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: config)
        let missingBinary = root.appendingPathComponent("missing-mihomo")

        let result = validate(
            binary: missingBinary,
            resources: resources,
            config: config,
            timeout: 3
        )

        XCTAssertNotNil(result)
        XCTAssertTrue(result?.localizedCaseInsensitiveContains("executable") == true)
    }

    func testRelativeDependencyIsNotResolvedFromSourceDirectory() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let config = root.appendingPathComponent("profile.yaml")
        let sourceProvider = root.appendingPathComponent("provider.yaml")
        try Data("proxy-providers:\n  local:\n    path: ./provider.yaml\n".utf8).write(to: config)
        try Data("source-only provider".utf8).write(to: sourceProvider)
        let script = try makeScript(
            in: root,
            body: """
            if [ -e "$3/provider.yaml" ]; then exit 0; fi
            printf 'open ./provider.yaml: no such file or directory\\n' >&2
            exit 7
            """
        )

        let result = validate(
            binary: script,
            resources: resources,
            config: config,
            timeout: 3
        )

        XCTAssertTrue(result?.localizedCaseInsensitiveContains("local file") == true)
        XCTAssertEqual(try Data(contentsOf: sourceProvider), Data("source-only provider".utf8))
    }

    func testOutputFloodDoesNotDeadlockValidation() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let config = root.appendingPathComponent("profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: config)
        let script = try makeScript(
            in: root,
            body: """
            index=0
            while [ "$index" -lt 5000 ]; do
              printf 'stdout-flood-012345678901234567890123456789\\n'
              printf 'stderr-flood-012345678901234567890123456789\\n' >&2
              index=$((index + 1))
            done
            exit 0
            """
        )

        let result = validate(
            binary: script,
            resources: resources,
            config: config,
            timeout: 5
        )

        XCTAssertNil(result)
    }

    func testTimeoutStopsChildAndReportsOnlyOnce() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let config = root.appendingPathComponent("profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: config)
        let started = root.appendingPathComponent("timeout-started")
        let script = try makeScript(
            in: root,
            body: "echo $$ > \(shellQuoted(started.path))\nexec /bin/sleep 5\n"
        )
        let runner = RuntimeConfigValidationRunner(
            binary: script,
            resourceDirectory: resources,
            timeout: 0.5
        )
        let callback = expectation(description: "timeout callback")
        callback.assertForOverFulfill = true
        let observeLateCallback = expectation(description: "late callback observation")
        var callbackCount = 0
        var result: String?
        let operation = runner.validate(file: config) { error in
            callbackCount += 1
            result = error
            callback.fulfill()
        }
        // The deadline also covers staging: under load it can expire before
        // launch. If the child starts, verify its PID is gone after settlement.
        _ = waitForFile(started, timeout: 0.25)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            observeLateCallback.fulfill()
        }
        wait(for: [callback, observeLateCallback], timeout: 4)

        if let text = try? String(contentsOf: started, encoding: .utf8),
           let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            XCTAssertEqual(kill(pid, 0), -1)
            XCTAssertEqual(errno, ESRCH)
        }
        XCTAssertEqual(callbackCount, 1)
        XCTAssertTrue(result?.localizedCaseInsensitiveContains("timed out") == true)
        _ = operation
    }

    func testCancelStopsChildAndLateTerminationCannotReportSuccess() throws {
        let root = try makeTemporaryDirectory()
        let resources = root.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: false)
        let config = root.appendingPathComponent("profile.yaml")
        try Data("mixed-port: 7890\n".utf8).write(to: config)
        let started = root.appendingPathComponent("cancel-started")
        let script = try makeScript(
            in: root,
            body: "touch \(shellQuoted(started.path))\nexec /bin/sleep 5\n"
        )
        let runner = RuntimeConfigValidationRunner(binary: script, resourceDirectory: resources, timeout: 4)
        let callback = expectation(description: "cancel callback")
        callback.assertForOverFulfill = true
        let observeLateCallback = expectation(description: "late callback observation")
        var callbackCount = 0
        var result: String?
        let operation = runner.validate(file: config) { error in
            callbackCount += 1
            result = error
            callback.fulfill()
        }

        XCTAssertTrue(waitForFile(started, timeout: 3))
        operation.cancel()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            observeLateCallback.fulfill()
        }
        wait(for: [callback, observeLateCallback], timeout: 4)

        XCTAssertEqual(callbackCount, 1)
        XCTAssertTrue(result?.localizedCaseInsensitiveContains("cancelled") == true)
    }

    private func validate(
        binary: URL,
        resources: URL,
        config: URL,
        timeout: TimeInterval
    ) -> String? {
        let completed = expectation(description: "validation result")
        var result: String? = "not completed"
        let runner = RuntimeConfigValidationRunner(
            binary: binary,
            resourceDirectory: resources,
            timeout: timeout
        )
        let operation = runner.validate(file: config) { error in
            result = error
            completed.fulfill()
        }
        wait(for: [completed], timeout: max(4, timeout + 2))
        _ = operation
        return result
    }

    private func makeScript(in directory: URL, body: String) throws -> URL {
        let script = directory.appendingPathComponent("fake-mihomo-\(UUID().uuidString).sh")
        try Data(("#!/bin/sh\nset -eu\n" + body).utf8).write(to: script)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClashFX-RuntimeValidationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        temporaryDirectories.append(directory)
        return directory
    }

    private func waitForFile(_ file: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: file.path) { return true }
            if Thread.isMainThread {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            } else {
                Thread.sleep(forTimeInterval: 0.01)
            }
        }
        return FileManager.default.fileExists(atPath: file.path)
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

final class RuntimeProxySelectionRestoreSequenceTests: XCTestCase {
    private struct RequestRecord {
        let path: String
        let method: String
        let body: [String: Any]?
    }

    func testManualSelectionSnapshotExcludesAutomaticAndCompatibilityFallbacks() throws {
        let policy = try XCTUnwrap(RuntimeProxySelectionPolicy(data: proxySnapshot(now: "Leaf")))

        XCTAssertEqual(policy.manualSelections, ["Manual": "Leaf"])
    }

    func testInlineRestoreRetainsSequenceThroughEncodedPutAndFreshVerification() {
        let completed = expectation(description: "restore finishes after verification")
        var requests = [RequestRecord]()
        var outcome: RuntimeProxySelectionRestoreSequence.Outcome?
        RuntimeProxySelectionRestoreSequence(
            records: ["Route/A group": "Leaf"],
            strict: true,
            operationTimeout: 2,
            isCurrent: { true },
            request: { path, method, body, _, callback in
                requests.append(RequestRecord(path: path, method: method, body: body))
                if method == "PUT" {
                    callback(nil, 204, nil)
                } else if requests.filter({ $0.method == "GET" }).count == 1 {
                    callback(self.proxySnapshot(now: "Old", groupName: "Route/A group"), 200, nil)
                } else {
                    callback(self.proxySnapshot(now: "Leaf", groupName: "Route/A group"), 200, nil)
                }
            },
            completion: { result in
                outcome = result
                completed.fulfill()
            }
        ).start()

        wait(for: [completed], timeout: 3)
        XCTAssertEqual(requests.map(\.method), ["GET", "PUT", "GET"])
        XCTAssertEqual(requests[1].path, "/proxies/Route%2FA%20group")
        XCTAssertEqual(requests[1].body?["name"] as? String, "Leaf")
        guard case .accepted? = outcome else {
            return XCTFail("Expected the fresh /proxies readback to confirm the selection")
        }
    }

    func testForwardRestoreSkipsInvalidRecordsAndStrictRestoreRejectsBeforeWrites() {
        let forwardFinished = expectation(description: "forward restore finishes")
        var forwardRequests = [RequestRecord]()
        var forwardOutcome: RuntimeProxySelectionRestoreSequence.Outcome?
        let snapshot = proxySnapshot(now: "Old", includeInvalidGroups: true)
        RuntimeProxySelectionRestoreSequence(
            records: [
                "Manual": "Leaf",
                "Missing": "Leaf",
                "Automatic": "Leaf",
                "Fallback": "COMPATIBLE"
            ],
            strict: false,
            isCurrent: { true },
            request: { path, method, body, _, callback in
                forwardRequests.append(RequestRecord(path: path, method: method, body: body))
                if method == "PUT" {
                    callback(nil, 204, nil)
                } else if forwardRequests.filter({ $0.method == "GET" }).count == 1 {
                    callback(snapshot, 200, nil)
                } else {
                    callback(self.proxySnapshot(now: "Leaf", includeInvalidGroups: true), 200, nil)
                }
            },
            completion: { result in
                forwardOutcome = result
                forwardFinished.fulfill()
            }
        ).start()
        wait(for: [forwardFinished], timeout: 3)

        XCTAssertEqual(forwardRequests.filter { $0.method == "PUT" }.map(\.path), ["/proxies/Manual"])
        guard case .accepted? = forwardOutcome else {
            return XCTFail("Expected the valid forward record to complete")
        }

        let strictFinished = expectation(description: "strict restore rejects stale record")
        var strictRequests = [RequestRecord]()
        var strictOutcome: RuntimeProxySelectionRestoreSequence.Outcome?
        RuntimeProxySelectionRestoreSequence(
            records: ["Missing": "Leaf"],
            strict: true,
            isCurrent: { true },
            request: { path, method, body, _, callback in
                strictRequests.append(RequestRecord(path: path, method: method, body: body))
                callback(snapshot, 200, nil)
            },
            completion: { result in
                strictOutcome = result
                strictFinished.fulfill()
            }
        ).start()
        wait(for: [strictFinished], timeout: 3)

        XCTAssertEqual(strictRequests.map(\.method), ["GET"])
        guard case .rejected? = strictOutcome else {
            return XCTFail("Expected strict rollback to reject a missing selection before any PUT")
        }
    }

    func testTimeoutAndStaleScopePreventLateWritesAndCallbacks() {
        let timedOut = expectation(description: "write timeout")
        timedOut.assertForOverFulfill = true
        var delayedPut: RuntimeProxySelectionRestoreSequence.HTTPCompletion?
        var timeoutRequests = [RequestRecord]()
        var timeoutOutcome: RuntimeProxySelectionRestoreSequence.Outcome?
        var timeoutCallbackCount = 0
        RuntimeProxySelectionRestoreSequence(
            records: ["Manual": "Leaf"],
            strict: false,
            operationTimeout: 0.05,
            isCurrent: { true },
            request: { path, method, body, _, callback in
                timeoutRequests.append(RequestRecord(path: path, method: method, body: body))
                if method == "PUT" {
                    delayedPut = callback
                } else {
                    callback(self.proxySnapshot(now: "Old"), 200, nil)
                }
            },
            completion: { result in
                timeoutOutcome = result
                timeoutCallbackCount += 1
                timedOut.fulfill()
            }
        ).start()
        wait(for: [timedOut], timeout: 2)
        delayedPut?(nil, 204, nil)
        delayedPut?(nil, 204, nil)

        XCTAssertEqual(timeoutRequests.map(\.method), ["GET", "PUT"])
        XCTAssertEqual(timeoutCallbackCount, 1)
        guard case .uncertain? = timeoutOutcome else {
            return XCTFail("A timed-out issued write must be uncertain")
        }

        let staleFinished = expectation(description: "stale scope settles")
        var staleRequests = [RequestRecord]()
        var stalePut: RuntimeProxySelectionRestoreSequence.HTTPCompletion?
        var current = true
        var staleOutcome: RuntimeProxySelectionRestoreSequence.Outcome?
        RuntimeProxySelectionRestoreSequence(
            records: ["Manual": "Leaf"],
            strict: false,
            operationTimeout: 2,
            isCurrent: { current },
            request: { path, method, body, _, callback in
                staleRequests.append(RequestRecord(path: path, method: method, body: body))
                if method == "PUT" {
                    stalePut = callback
                } else {
                    callback(self.proxySnapshot(now: "Old"), 200, nil)
                }
            },
            completion: { result in
                staleOutcome = result
                staleFinished.fulfill()
            }
        ).start()
        current = false
        stalePut?(nil, 204, nil)
        wait(for: [staleFinished], timeout: 2)
        stalePut?(nil, 204, nil)
        XCTAssertEqual(staleRequests.map(\.method), ["GET", "PUT"])
        guard case .uncertain? = staleOutcome else {
            return XCTFail("A stale scope after a write must be uncertain")
        }
    }

    private func proxySnapshot(
        now: String,
        includeInvalidGroups: Bool = false,
        groupName: String = "Manual"
    ) -> Data {
        var proxies: [String: [String: Any]] = [
            groupName: ["name": groupName, "type": "Selector", "now": now, "all": ["Old", "Leaf"]],
            "Old": ["name": "Old", "type": "Direct"],
            "Leaf": ["name": "Leaf", "type": "Direct"],
            "Automatic": ["name": "Automatic", "type": "URLTest", "now": "Old", "all": ["Old", "Leaf"]],
            "Fallback": ["name": "Fallback", "type": "Selector", "now": "COMPATIBLE", "all": ["COMPATIBLE"]],
            "COMPATIBLE": ["name": "COMPATIBLE", "type": "Compatible"]
        ]
        if !includeInvalidGroups {
            proxies.removeValue(forKey: "Automatic")
            proxies.removeValue(forKey: "Fallback")
            proxies.removeValue(forKey: "COMPATIBLE")
        }
        return try! JSONSerialization.data(withJSONObject: ["proxies": proxies])
    }
}
