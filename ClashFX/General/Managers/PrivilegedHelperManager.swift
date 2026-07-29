//
//  PrivilegedHelperManager.swift
//  ClashX
//
//  Created by yicheng on 2020/4/21.
//  Copyright © 2020 west2online. All rights reserved.
//

import AppKit
import RxCocoa
import RxSwift
import Security
import ServiceManagement

class PrivilegedHelperManager {
    let isHelperCheckFinished = BehaviorRelay<Bool>(value: false)
    private var cancelInstallCheck = false
    private var useLegacyInstall = false

    private var authRef: AuthorizationRef?
    private var connection: NSXPCConnection?
    private let connectionLock = NSLock()
    static let machServiceName = "com.clashfx.app.Helper"
    static let shared = PrivilegedHelperManager()
    // Keep this longer than the helper's initial connection grace period so
    // the app cannot reinstall a helper that is still waiting for launchd to
    // deliver the XPC request.
    private static let installedHelperResponseTimeout: TimeInterval = 75
    private static let missingHelperResponseTimeout: TimeInterval = 5
    private static let adHocSignatureFlag: UInt32 = 0x2

    init() {
        initAuthorizationRef()
    }

    // MARK: - Public

    func checkInstall() {
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

    private func initAuthorizationRef() {
        // Create an empty AuthorizationRef
        let status = AuthorizationCreate(nil, nil, AuthorizationFlags(), &authRef)
        if status != OSStatus(errAuthorizationSuccess) {
            Logger.log("initAuthorizationRef AuthorizationCreate failed", level: .error)
            return
        }
    }

    private func currentAppUsesAdHocSignature() -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(
            Bundle.main.bundleURL as CFURL,
            [],
            &staticCode
        ) == errSecSuccess, let staticCode else {
            return false
        }

        var signingInfo: CFDictionary?
        guard SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &signingInfo
        ) == errSecSuccess,
            let info = signingInfo as? [String: Any],
            let flags = info[kSecCodeInfoFlags as String] as? NSNumber else {
            return false
        }

        return flags.uint32Value & Self.adHocSignatureFlag != 0
    }

    /// Install new helper daemon
    private func installHelperDaemon() -> DaemonInstallResult {
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

    func helper(failture: (() -> Void)? = nil) -> ProxyConfigRemoteProcessProtocol? {
        connectionLock.lock()
        let activeConnection: NSXPCConnection
        if let connection {
            activeConnection = connection
        } else {
            let newConnection = NSXPCConnection(
                machServiceName: PrivilegedHelperManager.machServiceName,
                options: .privileged
            )
            newConnection.remoteObjectInterface = NSXPCInterface(
                with: ProxyConfigRemoteProcessProtocol.self
            )
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
            finish(.noFound)
            return
        }
        if !FileManager.default.contentsEqual(
            atPath: helperURL.path,
            andPath: installedHelperURL.path
        ) {
            Logger.log("Installed helper differs from bundled helper; update required")
            finish(.needUpdate)
            return
        }
        let timeout = helperFileExists
            ? Self.installedHelperResponseTimeout
            : Self.missingHelperResponseTimeout
        let time = Date()

        timer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            Logger.log("check helper timeout time: \(timeout)")
            finish(.noFound)
        }

        guard let h = helper() else {
            finish(.noFound)
            return
        }
        h.getVersion { [weak self] installedHelperVersion in
            Logger.log("helper version \(installedHelperVersion ?? "nil") require version \(helperVersion)", level: .debug)
            Logger.log("check helper using time: \(Date().timeIntervalSince(time))")
            guard let installedHelperVersion else {
                finish(.needUpdate)
                return
            }
            let cmp = Self.compareVersion(installedHelperVersion, Self.firstHelperProtocolVersion)
            guard cmp != .orderedAscending else {
                Logger.log("old helper \(installedHelperVersion) predates protocol versioning; needUpdate", level: .debug)
                self?.resetConnection()
                finish(.needUpdate)
                return
            }
            h.getHelperProtocolVersion? { [weak self] installedProtocolVersion in
                let expected = UInt(CLASHFX_HELPER_PROTOCOL_VERSION)
                Logger.log("helper protocol v\(installedProtocolVersion) expect v\(expected)", level: .debug)
                guard installedProtocolVersion != expected else {
                    finish(.installed)
                    return
                }

                // A running legacy helper keeps its old executable and XPC
                // interface even after the on-disk tool is replaced. Stop its
                // managed core and release the connection before installing
                // the new protocol version so launchd can start the new helper.
                h.stopMihomoCore { error in
                    if let error {
                        Logger.log("Failed to stop core before helper upgrade: \(error)", level: .warning)
                    }
                    self?.resetConnection()
                    finish(.needUpdate)
                }
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

        if useLegacyInstall || currentAppUsesAdHocSignature() {
            useLegacyInstall = false
            Logger.log(
                "Using legacy helper installation for an ad-hoc signed app",
                level: .info
            )
            legacyInstallHelper()
            if !cancelInstallCheck {
                checkInstall()
            }
            return
        }

        let result = installHelperDaemon()
        if case .success = result {
            if !cancelInstallCheck {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                    self?.checkInstall()
                }
            }
            return
        }

        // If SMJobBless failed but legacy install is possible,
        // silently fall back without showing the error dialog.
        // User already consented to installation above.
        if result.shouldRetryLegacyWay() {
            Logger.log("SMJobBless failed, falling back to legacy install: \(result.alertContent)", level: .warning)
            legacyInstallHelper()
            if !cancelInstallCheck {
                checkInstall()
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
