//
//  PrivilegedHelperManager.swift
//  ClashX
//
//  Created by yicheng on 2020/4/21.
//  Copyright © 2020 west2online. All rights reserved.
//

import AppKit
import CommonCrypto
import Darwin
import RxCocoa
import RxSwift
import Security
import ServiceManagement

struct PrivilegedHelperTrustMaterial {
    let clientCDHash: String
    let approvedSourcePath: String
    let coreSHA256: String
    let helperSHA256: String
}

struct PrivilegedHelperTrustAssessment {
    let material: PrivilegedHelperTrustMaterial?
    let installedCoreSHA256: String?
    let hasApprovedInstalledCore: Bool
    let currentClientApproved: Bool
    let currentBuildApproved: Bool
    let currentClientUsesAdHocSignature: Bool
}

private enum PendingDNSRecoverySnapshot {
    case none
    case ready(base64: String)
    case invalid(String)
}

class PrivilegedHelperManager {
    let isHelperCheckFinished = BehaviorRelay<Bool>(value: false)
    private var cancelInstallCheck = false
    private var useLegacyInstall = false

    private var authRef: AuthorizationRef?
    private var connection: NSXPCConnection?
    private let connectionLock = NSLock()
    private let trustMaterialLock = NSLock()
    private var cachedTrustMaterial: PrivilegedHelperTrustMaterial?
    private var cachedTrustAssessment: PrivilegedHelperTrustAssessment?
    private var pendingDNSSnapshotJSONBase64: String?
    private var pendingDNSJournalError: String?
    private var activeTrustInstallRequestID: UUID?
    private var activeTrustInstallSettlement: ManagedOperationSettlement<String?>?
    static let machServiceName = "com.clashfx.app.Helper"
    static let shared = PrivilegedHelperManager()
    static let approvedCorePath = "/Library/PrivilegedHelperTools/com.clashfx.app.Helper.mihomo_core"
    static let trustReceiptPath = "/Library/PrivilegedHelperTools/com.clashfx.app.Helper.trust.plist"
    static let trustReceiptSchemaVersion = 1
    // Keep this longer than the helper's initial connection grace period so
    // the app cannot reinstall a helper that is still waiting for launchd to
    // deliver the XPC request.
    private static let installedHelperResponseTimeout: TimeInterval = 75
    private static let missingHelperResponseTimeout: TimeInterval = 5

    init() {
        initAuthorizationRef()
    }

    // MARK: - Public

    func checkInstall() {
        guard AppDelegate.shared.ownsRuntimeControl else { return }
        Logger.log("checkInstall", level: .debug)
        getHelperStatus { [weak self] status in
            Logger.log("check result: \(status)", level: .debug)
            guard let self = self else { return }
            switch status {
            case .noFound:
                if #available(macOS 13, *) {
                    let url = URL(string: "/Library/LaunchDaemons/\(PrivilegedHelperManager.machServiceName).plist")!
                    let status = SMAppService.statusForLegacyPlist(at: url)
                    if status == .requiresApproval {
                        let alert = NSAlert()
                        let notice = NSLocalizedString("ClashFX use a daemon helper to setup your system proxy. Please enable ClashFX in the Login Items under the Allow in the Background section and relaunch the app", comment: "")
                        let addition = NSLocalizedString("If you can not find ClashFX in the settings, you can try reset daemon", comment: "")
                        alert.messageText = notice + "\n" + addition
                        alert.addButton(withTitle: NSLocalizedString("Open System Login Item Setting", comment: ""))
                        alert.addButton(withTitle: NSLocalizedString("Reset Daemon", comment: ""))
                        if alert.runModal() == .alertFirstButtonReturn {
                            SMAppService.openSystemSettingsLoginItems()
                        } else {
                            self.removeInstallHelper()
                        }
                    }
                }
                fallthrough
            case .needUpdate:
                Logger.log("need to install helper", level: .debug)
                if Thread.isMainThread {
                    self.notifyInstall()
                } else {
                    DispatchQueue.main.async {
                        self.notifyInstall()
                    }
                }
            case .installed:
                self.isHelperCheckFinished.accept(true)
            case .unresponsive:
                // A lost reply does not prove the daemon or its core is gone.
                // Reinstalling here can strand the old core and its cache lock.
                self.resetConnection()
                Logger.log("Installed helper is not responding; leaving core ownership unchanged", level: .error)
            }
        }
    }

    func resetConnection() {
        connectionLock.lock()
        let staleConnection = connection
        connection = nil
        connectionLock.unlock()

        staleConnection?.invalidationHandler = nil
        staleConnection?.interruptionHandler = nil
        staleConnection?.invalidate()
    }

    /// Refresh a stale readiness hint without installing or stopping anything.
    /// Startup retries must ask the daemon again after an earlier lost reply.
    func refreshReadiness(timeout: TimeInterval, completion: @escaping (Bool) -> Void) {
        let settlement = ManagedOperationSettlement<Bool> { [weak self] ready in
            DispatchQueue.main.async {
                if ready {
                    self?.isHelperCheckFinished.accept(true)
                }
                completion(ready)
            }
        }
        let bundled = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LaunchServices/" + Self.machServiceName
        )
        let installed = "/Library/PrivilegedHelperTools/" + Self.machServiceName
        settlement.scheduleTimeout(after: timeout, outcome: { false })
        guard FileManager.default.fileExists(atPath: installed) else {
            _ = settlement.finish(false)
            return
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self,
                  FileManager.default.contentsEqual(atPath: bundled.path, andPath: installed),
                  self.installedTrustArtifactsMatchCurrentApp() else {
                _ = settlement.finish(false)
                return
            }
            DispatchQueue.main.async {
                guard let helper = self.helper(failture: { _ = settlement.finish(false) }) else {
                    _ = settlement.finish(false)
                    return
                }
                let invocation: Void? = helper.getHelperProtocolVersion? { version in
                    _ = settlement.finish(version == UInt(CLASHFX_HELPER_PROTOCOL_VERSION))
                }
                if invocation == nil {
                    _ = settlement.finish(false)
                }
            }
        }
    }

    private func initAuthorizationRef() {
        // Create an empty AuthorizationRef
        let status = AuthorizationCreate(nil, nil, AuthorizationFlags(), &authRef)
        if status != OSStatus(errAuthorizationSuccess) {
            Logger.log("initAuthorizationRef AuthorizationCreate failed", level: .error)
            return
        }
    }

    private func currentAppUsesAdHocSignature() -> Bool {
        currentProcessTrustIdentity()?.isAdHoc ?? false
    }

    private func currentProcessTrustIdentity() -> (clientCDHash: String, isAdHoc: Bool)? {
        guard let details = ClashFXCurrentProcessSigningDetails() as? [String: Any],
              let clientCDHash = details["CDHash"] as? String,
              Self.isLowercaseHexDigest(clientCDHash, length: 40),
              let isAdHoc = details["AdHoc"] as? NSNumber else {
            return nil
        }
        return (clientCDHash, isAdHoc.boolValue)
    }

    func trustMaterialForCurrentApp() -> PrivilegedHelperTrustMaterial? {
        let helperURL = Bundle.main.bundleURL.appendingPathComponent(
            "Contents/Library/LaunchServices/" + Self.machServiceName
        )
        guard let coreURL = Bundle.main.url(forResource: "mihomo_core", withExtension: nil),
              let processIdentity = currentProcessTrustIdentity(),
              let coreSHA256 = Self.sha256Hex(at: coreURL),
              let helperSHA256 = Self.sha256Hex(at: helperURL) else {
            return nil
        }
        let material = PrivilegedHelperTrustMaterial(
            clientCDHash: processIdentity.clientCDHash,
            approvedSourcePath: coreURL.standardizedFileURL.path,
            coreSHA256: coreSHA256,
            helperSHA256: helperSHA256
        )
        trustMaterialLock.lock()
        cachedTrustMaterial = material
        trustMaterialLock.unlock()
        return material
    }

    func cachedTrustMaterialForCurrentApp() -> PrivilegedHelperTrustMaterial? {
        trustMaterialLock.lock()
        defer { trustMaterialLock.unlock() }
        return cachedTrustMaterial
    }

    private func installedTrustArtifactsMatchCurrentApp() -> Bool {
        trustAssessmentForCurrentApp().currentBuildApproved
    }

    func trustAssessmentForCurrentApp() -> PrivilegedHelperTrustAssessment {
        let material = trustMaterialForCurrentApp()
        let adHocSignature = currentAppUsesAdHocSignature()
        var installedCoreHash: String?
        var approvedCore = false
        var clientApproved = false

        if Self.trustDirectoriesAreSafe(),
           Self.trustFileIsSafe(Self.approvedCorePath, executable: true),
           Self.trustFileIsSafe(Self.trustReceiptPath, executable: false),
           let coreHash = Self.sha256Hex(at: URL(fileURLWithPath: Self.approvedCorePath)),
           let receiptData = try? Data(contentsOf: URL(fileURLWithPath: Self.trustReceiptPath)),
           receiptData.count <= 64 * 1024,
           let receipt = (try? PropertyListSerialization.propertyList(
               from: receiptData,
               options: [],
               format: nil
           )) as? [String: Any],
           (receipt["SchemaVersion"] as? NSNumber)?.intValue == Self.trustReceiptSchemaVersion,
           let entries = receipt["ApprovedClients"] as? [[String: Any]] {
            installedCoreHash = coreHash
            approvedCore = entries.contains { entry in
                let sourcePath = entry["ApprovedSourcePath"] as? String
                return entry["BundleIdentifier"] as? String == "com.clashfx.app" &&
                    entry["CoreSHA256"] as? String == coreHash &&
                    Self.isLowercaseHexDigest(entry["CoreSHA256"] as? String, length: 64) &&
                    sourcePath?.hasPrefix("/") == true
            }
            if let material {
                clientApproved = entries.contains { entry in
                    entry["BundleIdentifier"] as? String == Bundle.main.bundleIdentifier &&
                        entry["ClientCDHash"] as? String == material.clientCDHash &&
                        entry["ApprovedSourcePath"] as? String == material.approvedSourcePath &&
                        entry["CoreSHA256"] as? String == coreHash
                }
            }
        }

        let assessment = PrivilegedHelperTrustAssessment(
            material: material,
            installedCoreSHA256: installedCoreHash,
            hasApprovedInstalledCore: approvedCore,
            currentClientApproved: clientApproved,
            currentBuildApproved: clientApproved && installedCoreHash == material?.coreSHA256,
            currentClientUsesAdHocSignature: adHocSignature
        )
        trustMaterialLock.lock()
        cachedTrustAssessment = assessment
        trustMaterialLock.unlock()
        return assessment
    }

    func cachedTrustAssessmentForCurrentApp() -> PrivilegedHelperTrustAssessment? {
        trustMaterialLock.lock()
        defer { trustMaterialLock.unlock() }
        return cachedTrustAssessment
    }

    private func loadPendingDNSRecoverySnapshot() -> PendingDNSRecoverySnapshot {
        let journalURL = URL(fileURLWithPath: kConfigFolderPath)
            .appendingPathComponent(".tun_dns_snapshot.json")
        let snapshot = TunDNSSnapshotStore(defaults: .standard, journalURL: journalURL).load()
        guard !snapshot.isEmpty else { return .none }
        if let error = snapshot["error"] as? String {
            return .invalid(error)
        }
        guard JSONSerialization.isValidJSONObject(snapshot),
              let data = try? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys]),
              data.count <= 1_048_576 else {
            return .invalid("DNS recovery snapshot cannot be safely passed to the helper installer")
        }
        return .ready(base64: data.base64EncodedString())
    }

    private func cachePendingDNSRecoverySnapshot(_ snapshot: PendingDNSRecoverySnapshot) {
        dispatchPrecondition(condition: .onQueue(.main))
        switch snapshot {
        case .none:
            pendingDNSSnapshotJSONBase64 = nil
            pendingDNSJournalError = nil
        case let .ready(base64):
            pendingDNSSnapshotJSONBase64 = base64
            pendingDNSJournalError = nil
        case let .invalid(error):
            pendingDNSSnapshotJSONBase64 = nil
            pendingDNSJournalError = error
        }
    }

    private static func hasPendingDNSSnapshot(_ snapshot: PendingDNSRecoverySnapshot) -> Bool {
        if case .ready = snapshot { return true }
        return false
    }

    private static func isLowercaseHexDigest(_ value: String?, length: Int) -> Bool {
        guard let value, value.count == length else { return false }
        return value.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 48 && scalar.value <= 57) || (scalar.value >= 97 && scalar.value <= 102)
        }
    }

    private static func sha256Hex(at url: URL) -> String? {
        guard let handle = FileHandle(forReadingAtPath: url.path) else { return nil }
        defer { handle.closeFile() }
        var context = CC_SHA256_CTX()
        guard CC_SHA256_Init(&context) == 1 else { return nil }
        while true {
            let data = handle.readData(ofLength: 64 * 1024)
            if data.isEmpty { break }
            let updateStatus = data.withUnsafeBytes { bytes -> Int32 in
                guard let baseAddress = bytes.baseAddress else { return 0 }
                return CC_SHA256_Update(&context, baseAddress, CC_LONG(data.count))
            }
            guard updateStatus == 1 else { return nil }
        }
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        guard CC_SHA256_Final(&digest, &context) == 1 else { return nil }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func trustDirectoriesAreSafe() -> Bool {
        ["/", "/Library", "/Library/PrivilegedHelperTools"].allSatisfy { path in
            var info = Darwin.stat()
            guard path.withCString({ lstat($0, &info) }) == 0 else { return false }
            return info.st_uid == 0 && info.st_gid == 0 &&
                (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) &&
                (info.st_mode & mode_t(S_IWGRP | S_IWOTH)) == 0
        }
    }

    private static func trustFileIsSafe(_ path: String, executable: Bool) -> Bool {
        var info = Darwin.stat()
        guard path.withCString({ lstat($0, &info) }) == 0 else { return false }
        let accessBit = executable ? mode_t(S_IXUSR) : mode_t(S_IRUSR)
        return info.st_uid == 0 && info.st_gid == 0 &&
            (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) &&
            (info.st_mode & mode_t(S_IWUSR | S_IWGRP | S_IWOTH)) == 0 &&
            (info.st_mode & accessBit) != 0 &&
            (info.st_flags & UInt32(UF_IMMUTABLE)) != 0
    }

    /// Install new helper daemon
    private func installHelperDaemon() -> DaemonInstallResult {
        guard AppDelegate.shared.ownsRuntimeControl else { return .authorizationFail }
        Logger.log("installHelperDaemon", level: .info)

        defer {
            resetConnection()
        }

        // Create authorization reference for the user
        var authRef: AuthorizationRef?
        var authStatus = AuthorizationCreate(nil, nil, [], &authRef)

        // Check if the reference is valid
        guard authStatus == errAuthorizationSuccess else {
            Logger.log("Authorization failed: \(authStatus)", level: .error)
            return .authorizationFail
        }

        // Ask user for the admin privileges to install the
        var authItem = AuthorizationItem(name: (kSMRightBlessPrivilegedHelper as NSString).utf8String!, valueLength: 0, value: nil, flags: 0)
        var authRights = withUnsafeMutablePointer(to: &authItem) { pointer in
            AuthorizationRights(count: 1, items: pointer)
        }
        let flags: AuthorizationFlags = [[], .interactionAllowed, .extendRights, .preAuthorize]
        authStatus = AuthorizationCreate(&authRights, nil, flags, &authRef)
        defer {
            if let ref = authRef {
                AuthorizationFree(ref, [])
            }
        }
        // Check if the authorization went succesfully
        guard authStatus == errAuthorizationSuccess else {
            Logger.log("Couldn't obtain admin privileges: \(authStatus)", level: .error)
            return .getAdminFail
        }

        // Launch the privileged helper using SMJobBless tool
        var error: Unmanaged<CFError>?
        if SMJobBless(kSMDomainSystemLaunchd, PrivilegedHelperManager.machServiceName as CFString, authRef, &error) == false {
            let blessError = error!.takeRetainedValue() as Error
            Logger.log("Bless Error: \(blessError)", level: .error)
            return .blessError((blessError as NSError).code)
        }

        Logger.log("\(PrivilegedHelperManager.machServiceName) installed successfully", level: .info)
        return .success
    }

    private func installApprovedCoreTrustArtifacts(completion: @escaping (String?) -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeTrustInstallRequestID == nil else {
            completion("An approved core trust installation is already in progress")
            return
        }
        resetConnection()
        let requestID = UUID()
        let settlement = ManagedOperationSettlement<String?> { [weak self] error in
            DispatchQueue.main.async {
                guard let self, self.activeTrustInstallRequestID == requestID else { return }
                self.activeTrustInstallRequestID = nil
                self.activeTrustInstallSettlement = nil
                completion(error)
            }
        }
        activeTrustInstallRequestID = requestID
        activeTrustInstallSettlement = settlement
        settlement.scheduleTimeout(
            after: 90,
            outcome: { "Timed out while installing the approved Mihomo core and trust receipt" }
        )
        guard let helper = helper(failture: {
            _ = settlement.finish("Installed helper did not accept the trust installation request")
        }) else {
            _ = settlement.finish("Installed helper is unavailable for trust installation")
            return
        }
        let invocation: Void? = helper.installApprovedMihomoCore? { error in
            _ = settlement.finish(error)
        }
        if invocation == nil {
            _ = settlement.finish("Installed helper does not support approved core installation")
        }
    }

    func helper(failture: (() -> Void)? = nil) -> ProxyConfigRemoteProcessProtocol? {
        guard AppDelegate.shared.ownsRuntimeControl else { failture?(); return nil }
        connectionLock.lock()
        let activeConnection: NSXPCConnection
        if let connection {
            activeConnection = connection
        } else {
            let newConnection = NSXPCConnection(
                machServiceName: PrivilegedHelperManager.machServiceName,
                options: .privileged
            )
            let remoteInterface = NSXPCInterface(with: ProxyConfigRemoteProcessProtocol.self)
            ClashFXConfigureHelperXPCInterface(remoteInterface)
            newConnection.remoteObjectInterface = remoteInterface
            connection = newConnection
            newConnection.invalidationHandler = { [weak self, weak newConnection] in
                Logger.log("XPC Connection Invalidated", level: .warning)
                self?.clearConnectionIfCurrent(newConnection)
            }
            newConnection.interruptionHandler = { [weak self, weak newConnection] in
                Logger.log("XPC Connection Interrupted", level: .warning)
                self?.clearConnectionIfCurrent(newConnection)
            }
            newConnection.resume()
            activeConnection = newConnection
        }
        connectionLock.unlock()

        guard let helper = activeConnection.remoteObjectProxyWithErrorHandler({
            [weak self, weak activeConnection] error in
            Logger.log("Helper connection was closed with error: \(error)", level: .warning)
            self?.clearConnectionIfCurrent(activeConnection)
            failture?()
        }) as? ProxyConfigRemoteProcessProtocol else {
            clearConnectionIfCurrent(activeConnection)
            activeConnection.invalidate()
            return nil
        }
        return helper
    }

    private func clearConnectionIfCurrent(_ candidate: NSXPCConnection?) {
        connectionLock.lock()
        guard connection === candidate else {
            connectionLock.unlock()
            return
        }
        connection = nil
        connectionLock.unlock()
    }

    var timer: Timer?

    enum HelperStatus {
        case installed
        case noFound
        case needUpdate
        case unresponsive
    }

    private static let firstHelperProtocolVersion = "1.0.38.1"

    private static func compareVersion(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let l = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let r = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0 ..< max(l.count, r.count) {
            let a = i < l.count ? l[i] : 0
            let b = i < r.count ? r[i] : 0
            if a < b { return .orderedAscending }
            if a > b { return .orderedDescending }
        }
        return .orderedSame
    }

    private func getHelperStatus(callback: @escaping ((HelperStatus) -> Void)) {
        let finishQueue = DispatchQueue(label: "com.clashfx.helper-status-finish")
        var finished = false
        let finish: ((HelperStatus) -> Void) = { [weak self] status in
            finishQueue.async {
                guard !finished else { return }
                finished = true
                DispatchQueue.main.async {
                    self?.timer?.invalidate()
                    self?.timer = nil
                    callback(status)
                }
            }
        }

        let helperURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Library/LaunchServices/" + PrivilegedHelperManager.machServiceName)
        guard
            let helperBundleInfo = CFBundleCopyInfoDictionaryForURL(helperURL as CFURL) as? [String: Any],
            let helperVersion = helperBundleInfo["CFBundleShortVersionString"] as? String else {
            Logger.log("check helper status fail")
            finish(.noFound)
            return
        }
        let installedHelperURL = URL(
            fileURLWithPath: "/Library/PrivilegedHelperTools/\(PrivilegedHelperManager.machServiceName)"
        )
        let helperFileExists = FileManager.default.fileExists(atPath: installedHelperURL.path)
        if !helperFileExists {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                _ = self?.trustAssessmentForCurrentApp()
                let dnsSnapshot = self?.loadPendingDNSRecoverySnapshot() ?? .none
                DispatchQueue.main.async {
                    self?.cachePendingDNSRecoverySnapshot(dnsSnapshot)
                    if case let .invalid(reason) = dnsSnapshot {
                        Logger.log("Cannot safely refresh helper with pending DNS recovery: \(reason)", level: .error)
                        finish(.unresponsive)
                    } else {
                        finish(.noFound)
                    }
                }
            }
            return
        }
        let timeout = helperFileExists
            ? Self.installedHelperResponseTimeout
            : Self.missingHelperResponseTimeout
        let scheduleTimeout = { [weak self] in
            self?.timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
                Logger.log("check helper timeout time: \(timeout)")
                finish(.unresponsive)
            }
        }
        if Thread.isMainThread {
            scheduleTimeout()
        } else {
            DispatchQueue.main.sync(execute: scheduleTimeout)
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else {
                finish(.unresponsive)
                return
            }
            let trustAssessment = self.trustAssessmentForCurrentApp()
            let dnsSnapshot = self.loadPendingDNSRecoverySnapshot()
            let needsBinaryUpdate = !FileManager.default.contentsEqual(
                atPath: helperURL.path,
                andPath: installedHelperURL.path
            )
            DispatchQueue.main.async {
                self.cachePendingDNSRecoverySnapshot(dnsSnapshot)
                if case let .invalid(reason) = dnsSnapshot {
                    Logger.log("Cannot safely refresh helper with pending DNS recovery: \(reason)", level: .error)
                    finish(.unresponsive)
                    return
                }
                guard trustAssessment.currentBuildApproved else {
                    Logger.log(
                        "Helper trust receipt or approved core is missing or outdated; requesting an authorized refresh",
                        level: .info
                    )
                    finish(.needUpdate)
                    return
                }
                self.checkInstalledHelper(
                    helperURL: helperURL,
                    installedHelperURL: installedHelperURL,
                    helperVersion: helperVersion,
                    needsBinaryUpdate: needsBinaryUpdate,
                    dnsSnapshotPending: Self.hasPendingDNSSnapshot(dnsSnapshot),
                    finish: finish
                )
            }
        }
    }

    private func checkInstalledHelper(
        helperURL: URL,
        installedHelperURL: URL,
        helperVersion: String,
        needsBinaryUpdate: Bool,
        dnsSnapshotPending: Bool,
        finish: @escaping (HelperStatus) -> Void
    ) {
        dispatchPrecondition(condition: .onQueue(.main))
        let time = Date()
        guard let helper = helper(failture: { finish(.unresponsive) }) else {
            finish(.unresponsive)
            return
        }
        let stopBeforeUpgrade = { [weak self] in
            if dnsSnapshotPending {
                Logger.log("Pending DNS recovery will run through the staged helper before replacement", level: .info)
                finish(.needUpdate)
                return
            }
            AppDelegate.shared.restoreDNSBeforePrivilegedHelperUpdate { dnsError in
                if let dnsError {
                    Logger.log("Failed to restore TUN DNS before helper upgrade: \(dnsError)", level: .warning)
                    finish(.unresponsive)
                    return
                }
                helper.stopMihomoCore { error in
                    if let error {
                        Logger.log("Failed to stop core before helper upgrade: \(error)", level: .warning)
                        finish(.unresponsive)
                        return
                    }
                    self?.resetConnection()
                    finish(.needUpdate)
                }
            }
        }
        helper.getVersion { installedHelperVersion in
            Logger.log("helper version \(installedHelperVersion ?? "nil") require version \(helperVersion)", level: .debug)
            Logger.log("check helper using time: \(Date().timeIntervalSince(time))")
            guard let installedHelperVersion else {
                finish(.unresponsive)
                return
            }
            let comparison = Self.compareVersion(installedHelperVersion, Self.firstHelperProtocolVersion)
            guard comparison != .orderedAscending else {
                Logger.log("old helper \(installedHelperVersion) predates protocol versioning; needUpdate", level: .debug)
                stopBeforeUpgrade()
                return
            }
            helper.getHelperProtocolVersion? { installedProtocolVersion in
                let expected = UInt(CLASHFX_HELPER_PROTOCOL_VERSION)
                Logger.log("helper protocol v\(installedProtocolVersion) expect v\(expected)", level: .debug)
                guard installedProtocolVersion != expected || needsBinaryUpdate else {
                    finish(.installed)
                    return
                }
                stopBeforeUpgrade()
            }
        }
    }
}

extension PrivilegedHelperManager {
    private func notifyInstall() {
        guard showInstallHelperAlert() else { exit(0) }

        if cancelInstallCheck {
            return
        }

        if useLegacyInstall || currentAppUsesAdHocSignature() || pendingDNSSnapshotJSONBase64 != nil {
            useLegacyInstall = false
            Logger.log(
                pendingDNSSnapshotJSONBase64 == nil
                    ? "Using legacy helper installation for an ad-hoc signed app"
                    : "Using staged-helper DNS recovery before authorized helper replacement",
                level: .info
            )
            let installed = legacyInstallHelper(dnsSnapshotJSONBase64: pendingDNSSnapshotJSONBase64)
            if installed, !cancelInstallCheck {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.checkInstall()
                }
            } else if !installed {
                NSAlert.alert(with: NSLocalizedString("Helper installation failed. Please try again or check the logs.", comment: ""))
            }
            return
        }

        let result = installHelperDaemon()
        if case .success = result {
            installApprovedCoreTrustArtifacts { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, !self.cancelInstallCheck else { return }
                    if let error {
                        Logger.log("Failed to install approved helper core trust: \(error)", level: .error)
                        NSAlert.alert(with: error)
                        return
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self.checkInstall()
                    }
                }
            }
            return
        }

        // If SMJobBless failed but legacy install is possible,
        // silently fall back without showing the error dialog.
        // User already consented to installation above.
        if result.shouldRetryLegacyWay() {
            Logger.log("SMJobBless failed, falling back to legacy install: \(result.alertContent)", level: .warning)
            let installed = legacyInstallHelper(dnsSnapshotJSONBase64: pendingDNSSnapshotJSONBase64)
            if installed, !cancelInstallCheck {
                checkInstall()
            } else if !installed {
                NSAlert.alert(with: NSLocalizedString("Helper installation failed. Please try again or check the logs.", comment: ""))
            }
            return
        }

        result.alertAction()
        NSAlert.alert(with: result.alertContent)
        if !cancelInstallCheck {
            checkInstall()
        }
    }

    private func showInstallHelperAlert() -> Bool {
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("ClashFX needs to install/update a helper tool with administrator privileges, otherwise ClashFX won't be able to configure system proxy.", comment: "")
        alert.alertStyle = .warning
        if useLegacyInstall {
            alert.addButton(withTitle: NSLocalizedString("Legacy Install", comment: ""))
        } else {
            alert.addButton(withTitle: NSLocalizedString("Install", comment: ""))
        }
        alert.addButton(withTitle: NSLocalizedString("Quit", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return true
        case .alertThirdButtonReturn:
            cancelInstallCheck = true
            Logger.log("cancelInstallCheck = true", level: .error)
            return true
        default:
            return false
        }
    }
}

private enum AppAuthorizationRights {
    static let rightName: NSString = "\(PrivilegedHelperManager.machServiceName).config" as NSString
    static let rightDefaultRule: Dictionary = adminRightsRule
    static let rightDescription: CFString = "ProxyConfigHelper wants to configure your proxy setting'" as CFString
    static var adminRightsRule: [String: Any] = ["class": "user",
                                                 "group": "admin",
                                                 "timeout": 0,
                                                 "version": 1]
}

private enum DaemonInstallResult {
    case success
    case authorizationFail
    case getAdminFail
    case blessError(Int)

    var alertContent: String {
        switch self {
        case .success:
            return ""
        case .authorizationFail: return "Failed to create authorization!"
        case .getAdminFail: return "Failed to get admin authorization!"
        case let .blessError(code):
            switch code {
            case kSMErrorInternalFailure: return "blessError: kSMErrorInternalFailure"
            case kSMErrorInvalidSignature: return "blessError: kSMErrorInvalidSignature"
            case kSMErrorAuthorizationFailure: return "blessError: kSMErrorAuthorizationFailure"
            case kSMErrorToolNotValid: return "blessError: kSMErrorToolNotValid"
            case kSMErrorJobNotFound: return "blessError: kSMErrorJobNotFound"
            case kSMErrorServiceUnavailable: return "blessError: kSMErrorServiceUnavailable"
            case kSMErrorJobMustBeEnabled: return "ClashFX Helper is disabled by other process. Please run \"sudo launchctl enable system/\(PrivilegedHelperManager.machServiceName)\" in your terminal. The command has been copied to your pasteboard"
            case kSMErrorInvalidPlist: return "blessError: kSMErrorInvalidPlist"
            default:
                return "bless unknown error:\(code)"
            }
        }
    }

    func shouldRetryLegacyWay() -> Bool {
        switch self {
        case .success: return false
        case let .blessError(code):
            switch code {
            case kSMErrorJobMustBeEnabled:
                return false
            default:
                return true
            }
        default:
            return true
        }
    }

    func alertAction() {
        switch self {
        case let .blessError(code):
            switch code {
            case kSMErrorJobMustBeEnabled:
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("sudo launchctl enable system/\(PrivilegedHelperManager.machServiceName)", forType: .string)
            default:
                break
            }
        default:
            break
        }
    }
}
