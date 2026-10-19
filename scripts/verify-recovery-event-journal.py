#!/usr/bin/env python3
"""Exercise the Foundation recovery journal without launching ClashFX."""

from __future__ import annotations

import os
import pathlib
import shutil
import subprocess
import sys
import tempfile


SWIFT_HARNESS = r'''import Foundation
import Dispatch

@main
struct RecoveryEventJournalVerification {
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
    }

    static func lines(at url: URL) throws -> [String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    static func sequence(_ line: String) -> UInt64? {
        guard let token = line.split(separator: " ", maxSplits: 1).first,
              token.hasPrefix("seq=") else { return nil }
        return UInt64(token.dropFirst(4))
    }

    static func journalFiles(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let value = attributes[.posixPermissions] as? NSNumber else {
            fatalError("missing POSIX permissions at \(url.path)")
        }
        return value.intValue & 0o777
    }

    static func verifyOrderAndRestart(at root: URL) throws {
        let directory = root.appendingPathComponent("order/Recovery", isDirectory: true)
        let journal = RecoveryEventJournal(directory: directory)
        journal.append("event=first")
        journal.append("event=second")
        journal.flushForTesting()

        let restarted = RecoveryEventJournal(directory: directory)
        restarted.append("event=third")
        restarted.flushForTesting()

        let records = try lines(at: directory.appendingPathComponent("events.log"))
        check(records.count == 3, "flush did not persist all ordered records")
        let numbers = records.compactMap(sequence)
        check(numbers == [1, 2, 3], "sequence did not continue monotonically across journal instances")
        check(records.map { $0.components(separatedBy: " ").last ?? "" } == [
            "event=first", "event=second", "event=third",
        ], "records were reordered or altered")
        let directoryMode = try permissions(of: directory)
        let fileMode = try permissions(of: directory.appendingPathComponent("events.log"))
        check(directoryMode == 0o700, "journal directory is not mode 0700")
        check(fileMode == 0o600, "journal file is not mode 0600")
    }

    static func verifyConcurrentWrites(at root: URL) throws {
        let directory = root.appendingPathComponent("concurrent/Recovery", isDirectory: true)
        let journal = RecoveryEventJournal(directory: directory)
        let group = DispatchGroup()
        let writers = DispatchQueue.global(qos: .userInitiated)
        let writerCount = 8
        let recordsPerWriter = 30

        for writer in 0 ..< writerCount {
            group.enter()
            writers.async {
                for item in 0 ..< recordsPerWriter {
                    journal.append("event=concurrent writer=\(writer) item=\(item)")
                }
                group.leave()
            }
        }
        group.wait()
        journal.flushForTesting()

        let records = try lines(at: directory.appendingPathComponent("events.log"))
        let numbers = records.compactMap(sequence)
        check(records.count == writerCount * recordsPerWriter, "concurrent writes were lost")
        check(numbers == Array(1 ... UInt64(writerCount * recordsPerWriter)),
              "concurrent record order is not strictly monotonic")
        check(Set(records).count == records.count, "concurrent records were duplicated")
    }

    static func verifyBoundsAndRotation(at root: URL) throws {
        let directory = root.appendingPathComponent("rotation/Recovery", isDirectory: true)
        let journal = RecoveryEventJournal(directory: directory)
        let largePayload = String(repeating: "é", count: 8_000)
        for index in 0 ..< 100 {
            journal.append("event=rotation index=\(index) payload=\(largePayload)")
        }
        journal.flushForTesting()

        var files = try journalFiles(in: directory)
        check(files.map(\.lastPathComponent) == ["events.log", "events.previous.log"],
              "rotation did not retain exactly the current and one previous file")
        for file in files {
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = (attributes[.size] as? NSNumber)?.intValue ?? Int.max
            check(size <= RecoveryEventJournal.maximumFileSizeBytes, "rotated file exceeds 256 KiB")
            let mode = try permissions(of: file)
            check(mode == 0o600, "rotated file is not mode 0600")
        }

        let previous = try lines(at: directory.appendingPathComponent("events.previous.log"))
        let current = try lines(at: directory.appendingPathComponent("events.log"))
        let records = previous + current
        check(!previous.isEmpty && !current.isEmpty, "rotation left an empty journal file")
        check(records.allSatisfy { $0.utf8.count + 1 <= RecoveryEventJournal.maximumRecordSizeBytes },
              "a journal record exceeds 8 KiB")
        let numbers = records.compactMap(sequence)
        check(zip(numbers, numbers.dropFirst()).allSatisfy { $0.0 < $0.1 },
              "record sequence regressed across rotation")

        let lastSequence = numbers.last!
        journal.append("event=oversize payload=\(String(repeating: "x", count: 1_000_000))\nsecond-line=true")
        journal.flushForTesting()
        files = try journalFiles(in: directory)
        check(files.map(\.lastPathComponent) == ["events.log", "events.previous.log"],
              "oversize append created extra files")
        let allRecords = try lines(at: directory.appendingPathComponent("events.previous.log")) +
            lines(at: directory.appendingPathComponent("events.log"))
        let allNumbers = allRecords.compactMap(sequence)
        check(allNumbers.last == lastSequence + 1, "append after rotation did not continue the sequence")
        check(allRecords.allSatisfy { $0.utf8.count + 1 <= RecoveryEventJournal.maximumRecordSizeBytes },
              "oversize input escaped the record-size bound")
    }

    static func verifyUnavailableStorage(at root: URL) throws {
        let blocker = root.appendingPathComponent("not-a-directory")
        check(FileManager.default.createFile(atPath: blocker.path, contents: Data("sentinel".utf8)),
              "could not create failure fixture")
        let journal = RecoveryEventJournal(directory: blocker.appendingPathComponent("Recovery"))
        journal.append("event=storage-unavailable")
        journal.flushForTesting()
        let contents = try String(contentsOf: blocker, encoding: .utf8)
        check(contents == "sentinel", "unavailable storage changed its parent file")
    }

    static func verifyTrustedRecordSanitization() {
        let recoveryID = "12345678-1234-1234-1234-123456789abc"
        let automatic = "[Automatic Recovery] id=\(recoveryID) stage=capture trigger=cpu-watchdog " +
            "reason=private-reason https://alice:secret@example.test/?token=hidden " +
            "generation=42 outcome=blocked code=checkpoint-unavailable groups=3 source=profile-memory"
        let record = RecoveryJournalRecord.make(from: automatic, origin: .application)
        let expected = "event=automatic_recovery id=\(recoveryID) stage=capture trigger=cpu-watchdog " +
            "generation=42 groups=3 source=profile-memory outcome=blocked code=checkpoint-unavailable"
        check(record == expected, "automatic recovery fields were not safely retained: \(record ?? "nil")")
        check(!(record ?? "").contains("private-reason") && !(record ?? "").contains("https://") &&
              !(record ?? "").contains("hidden"), "free text or a URL entered the recovery journal")

        let request = "[Automatic Recovery] stage=request trigger=wake-or-network generation=8 " +
            "outcome=accepted code=explicit-scope-change"
        check(RecoveryJournalRecord.make(from: request, origin: .application) ==
              "event=automatic_recovery stage=request trigger=wake-or-network generation=8 " +
              "outcome=accepted code=explicit-scope-change",
              "new request/trigger/outcome/code fields were rejected")

        let captureFailure = "[Automatic Recovery] stage=capture blocked trigger=data-plane outcome=blocked " +
            "code=selection-mismatch diagnostic=https://secret.example/path"
        let failureRecord = RecoveryJournalRecord.make(from: captureFailure, origin: .application) ?? ""
        check(failureRecord.contains("stage=capture") && failureRecord.contains("trigger=data-plane") &&
              failureRecord.contains("outcome=blocked") && failureRecord.contains("code=selection-mismatch") &&
              !failureRecord.contains("diagnostic") && !failureRecord.contains("https://"),
              "capture failure classification was lost or free text was retained")

        let probe = "[mihomo_core] dns_listener_probe address=127.0.0.1 port=49634 " +
            "transport=udp result=unavailable error=secret https://user:pass@resolver.example"
        let ipv6Transition = "dns_listener_transition family=ipv6 source_port=53127 target_port=54001 bootstrap_references_retargeted=2 secret=https://private.example/token"
        check(RecoveryJournalRecord.make(from: ipv6Transition, origin: .core) ==
            "event=dns_listener_transition family=ipv6 source_port=53127 target_port=54001 bootstrap_references_retargeted=2",
            "IPv6 journal records must retain safe ports/counts and omit arbitrary data")
        let quotedIPv6 = "time=fixture level=info msg=\"dns_listener_transition family=ipv6 source_port=53127 target_port=54001 bootstrap_references_retargeted=2\""
        check(RecoveryJournalRecord.make(from: quotedIPv6, origin: .core) ==
            "event=dns_listener_transition family=ipv6 source_port=53127 target_port=54001 bootstrap_references_retargeted=2",
            "formatted IPv6 core lines must retain the transition")
        let probeRecord = RecoveryJournalRecord.make(from: probe, origin: .core)
        check(probeRecord == "event=dns_listener_probe address=127.0.0.1 port=49634 " +
              "transport=udp result=unavailable",
              "DNS probe fields were not sanitized")
        check(RecoveryJournalRecord.make(from: "benchmark dns_listener_probe address=127.0.0.1", origin: .application) == nil,
              "untrusted application text was journaled as a core event")
        check(RecoveryJournalRecord.make(from: "[mihomo_core] benchmark flood", origin: .core) == nil,
              "ordinary core flood entered the recovery journal")
    }

    static func main() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("recovery-journal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try verifyOrderAndRestart(at: root)
        try verifyConcurrentWrites(at: root)
        try verifyBoundsAndRotation(at: root)
        try verifyUnavailableStorage(at: root)
        verifyTrustedRecordSanitization()
        print("recovery event journal verification passed")
    }
}
'''


def main() -> int:
    root = pathlib.Path(__file__).resolve().parents[1]
    journal_source = root / "ClashFX" / "General" / "Utils" / "ManagedOperationSettlement.swift"
    logger_source = root / "ClashFX" / "Basic" / "Logger.swift"
    swiftc = shutil.which("swiftc")
    if swiftc is None:
        print("swiftc is required to verify RecoveryEventJournal", file=sys.stderr)
        return 2

    with tempfile.TemporaryDirectory(prefix="clashfx-recovery-journal-") as temporary_root:
        temp = pathlib.Path(temporary_root)
        harness = temp / "RecoveryEventJournalVerification.swift"
        executable = temp / "recovery-event-journal-verification"
        logger_text = logger_source.read_text(encoding="utf-8")
        formatter_start = logger_text.find("private enum RecoveryJournalOrigin {")
        formatter_end = logger_text.find("private final class ClashFXLogFileManager", formatter_start)
        if formatter_start < 0 or formatter_end < 0:
            print("could not locate the production recovery event sanitizer", file=sys.stderr)
            return 2
        formatter_source = logger_text[formatter_start:formatter_end]
        harness.write_text(formatter_source + "\n" + SWIFT_HARNESS, encoding="utf-8")
        compile_result = subprocess.run(
            [swiftc, "-parse-as-library", str(journal_source), str(harness), "-o", str(executable)],
            check=False,
        )
        if compile_result.returncode != 0:
            return compile_result.returncode
        environment = dict(os.environ, HOME=str(temp / "home"))
        pathlib.Path(environment["HOME"]).mkdir()
        return subprocess.run([str(executable)], env=environment, check=False).returncode


if __name__ == "__main__":
    sys.exit(main())
