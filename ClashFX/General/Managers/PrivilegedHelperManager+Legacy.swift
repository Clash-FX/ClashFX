//
//  PrivilegedHelperManager+Legacy.swift
//  ClashX
//
//  Created by yicheng 2020/4/22.
//  Copyright © 2020 west2online. All rights reserved.
//

import Cocoa

extension PrivilegedHelperManager {
    func getInstallScript(dnsSnapshotJSONBase64: String? = nil) -> String {
        guard let trust = cachedTrustMaterialForCurrentApp() ?? trustMaterialForCurrentApp(),
              let appExecutablePath = Bundle.main.executableURL?.path,
              !trust.approvedSourcePath.contains("\n"),
              !trust.approvedSourcePath.contains("\r") else {
            Logger.log("Cannot prepare helper install without a valid client CDHash and bundled core", level: .error)
            return "#!/bin/bash\nset -euo pipefail\nexit 1\n"
        }

        let appPath = Bundle.main.bundlePath
        let helperLabel = Self.machServiceName
        let helperDestination = "/Library/PrivilegedHelperTools/\(helperLabel)"
        let helperCore = Self.approvedCorePath
        let trustReceipt = Self.trustReceiptPath
        let launchDaemon = "/Library/LaunchDaemons/\(helperLabel).plist"
        let dnsRestoreSnippet: String
        if let dnsSnapshotJSONBase64 {
            let maximumEncodedSize = ((1_048_576 + 2) / 3) * 4
            guard dnsSnapshotJSONBase64.utf8.count <= maximumEncodedSize,
                  Data(base64Encoded: dnsSnapshotJSONBase64) != nil else {
                Logger.log("Cannot prepare helper install with an invalid or oversized DNS recovery snapshot", level: .error)
                return "#!/bin/bash\nset -euo pipefail\nexit 1\n"
            }
            dnsRestoreSnippet = """
            dnsSnapshotBase64=\(shellQuoted(dnsSnapshotJSONBase64))
            printf '%s' "$dnsSnapshotBase64" | /usr/bin/base64 -D | /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin "$helperSource" --restore-dns-json-stdin
            """
        } else {
            dnsRestoreSnippet = ""
        }
        let receiptXML = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>SchemaVersion</key>
        <integer>1</integer>
        <key>ApprovedClients</key>
        <array>
        <dict>
        <key>BundleIdentifier</key>
        <string>com.clashfx.app</string>
        <key>ClientCDHash</key>
        <string>\(trust.clientCDHash)</string>
        <key>ApprovedSourcePath</key>
        <string>\(xmlEscaped(trust.approvedSourcePath))</string>
        <key>CoreSHA256</key>
        <string>\(trust.coreSHA256)</string>
        </dict>
        </array>
        </dict>
        </plist>
        """
        return """
        #!/bin/bash
        set -euo pipefail
        umask 077

        # Validate installer dependencies before touching DNS or the running daemon.
        for executable in /bin/bash /bin/rm /bin/ls /bin/chmod /bin/launchctl /usr/sbin/chown /usr/bin/install /usr/bin/stat /usr/bin/awk /usr/bin/mktemp /usr/bin/basename /usr/bin/ditto /usr/bin/perl /usr/bin/find /usr/bin/codesign /usr/bin/shasum /usr/bin/base64 /usr/bin/env /usr/bin/chflags; do
            if [ ! -x "$executable" ]; then
                printf 'Helper installer prerequisite missing: %s\\n' "$executable" >&2
                exit 1
            fi
        done

        appPath=\(shellQuoted(appPath))
        appExecutablePath=\(shellQuoted(appExecutablePath))
        expectedClientCDHash=\(shellQuoted(trust.clientCDHash))
        expectedCoreSHA256=\(shellQuoted(trust.coreSHA256))
        expectedHelperSHA256=\(shellQuoted(trust.helperSHA256))
        helperLabel=\(shellQuoted(helperLabel))
        helperDestination=\(shellQuoted(helperDestination))
        helperCore=\(shellQuoted(helperCore))
        trustReceipt=\(shellQuoted(trustReceipt))
        launchDaemon=\(shellQuoted(launchDaemon))
        receiptTemporary="${trustReceipt}.tmp.$$"
        stagingDirectory=""
        trap 'if [ -n "${stagingDirectory:-}" ]; then /bin/rm -rf "$stagingDirectory"; fi' EXIT

        assertRootDirectory() {
            trustedDirectory="$1"
            [ -d "$trustedDirectory" ] && [ ! -L "$trustedDirectory" ] || return 1
            metadata=$(/usr/bin/stat -f '%u %g %Lp' "$trustedDirectory")
            read -r owner group mode <<< "$metadata"
            [ "$owner" = "0" ] && [ "$group" = "0" ] || return 1
            permissionDigits="${mode: -3}"
            case "${permissionDigits:1:2}" in
                *2*|*3*|*6*|*7*) return 1 ;;
            esac
            permissions=$(/bin/ls -ld "$trustedDirectory" | /usr/bin/awk '{print $1}')
            case "$permissions" in *+*) return 1 ;; esac
        }
        assertRootDirectory "/" || exit 1
        assertRootDirectory "/Library" || exit 1
        assertRootDirectory "/Library/LaunchDaemons" || exit 1
        [ ! -L "/Library/PrivilegedHelperTools" ] || exit 1
        if [ ! -e "/Library/PrivilegedHelperTools" ]; then
            /usr/bin/install -d -o root -g wheel -m 0755 "/Library/PrivilegedHelperTools"
        fi
        assertRootDirectory "/Library/PrivilegedHelperTools" || exit 1

        stagingDirectory=$(/usr/bin/mktemp -d "/Library/PrivilegedHelperTools/.clashfx-install.XXXXXX")
        /usr/sbin/chown root:wheel "$stagingDirectory"
        /bin/chmod 0700 "$stagingDirectory"
        stagedApp="$stagingDirectory/$(/usr/bin/basename "$appPath")"
        /usr/bin/ditto "$appPath" "$stagedApp"
        [ -d "$stagedApp" ] && [ ! -L "$stagedApp" ] || exit 1
        /usr/sbin/chown root:wheel "$stagedApp"
        /bin/chmod 0700 "$stagedApp"

        stagedContents="$stagedApp/Contents"
        stagedResources="$stagedContents/Resources"
        stagedLibrary="$stagedContents/Library"
        stagedLaunchServices="$stagedLibrary/LaunchServices"
        for stagedDirectory in "$stagedApp" "$stagedContents" "$stagedResources" "$stagedLibrary" "$stagedLaunchServices"; do
            [ -d "$stagedDirectory" ] && [ ! -L "$stagedDirectory" ] || exit 1
        done
        while IFS= read -r -d '' stagedLink; do
            resolvedLink=$(/usr/bin/perl -MCwd=realpath -e 'print realpath($ARGV[0]) // ""' "$stagedLink")
            case "$resolvedLink" in "$stagingDirectory"/*) ;; *) exit 1 ;; esac
        done < <(/usr/bin/find "$stagedApp" -type l -print0)

        /usr/bin/codesign --verify --deep --strict "$stagedApp"
        observedClientCDHash=$(/usr/bin/codesign --display --verbose=4 "$stagedApp" 2>&1 | /usr/bin/awk -F= '/^CDHash=/{print tolower($2); exit}')
        [ "$observedClientCDHash" = "$expectedClientCDHash" ] || exit 1

        coreSource="$stagedResources/mihomo_core"
        helperSource="$stagedLaunchServices/$helperLabel"
        [ -f "$coreSource" ] && [ ! -L "$coreSource" ] || exit 1
        [ -f "$helperSource" ] && [ ! -L "$helperSource" ] || exit 1
        coreSourceResolved=$(/usr/bin/perl -MCwd=realpath -e 'print realpath($ARGV[0]) // ""' "$coreSource")
        helperSourceResolved=$(/usr/bin/perl -MCwd=realpath -e 'print realpath($ARGV[0]) // ""' "$helperSource")
        case "$coreSourceResolved" in "$stagingDirectory"/*) ;; *) exit 1 ;; esac
        case "$helperSourceResolved" in "$stagingDirectory"/*) ;; *) exit 1 ;; esac
        coreSource="$coreSourceResolved"
        helperSource="$helperSourceResolved"
        observedCoreSHA256=$(/usr/bin/shasum -a 256 "$coreSource" | /usr/bin/awk '{print tolower($1)}')
        [ "$observedCoreSHA256" = "$expectedCoreSHA256" ] || exit 1
        observedHelperSHA256=$(/usr/bin/shasum -a 256 "$helperSource" | /usr/bin/awk '{print tolower($1)}')
        [ "$observedHelperSHA256" = "$expectedHelperSHA256" ] || exit 1
        [ -x "$appExecutablePath" ] && [ -x "$helperSource" ] || exit 1

        # Check filesystem flag support while the existing service is still intact.
        flagsProbe="$stagingDirectory/.immutable-flags-probe"
        : > "$flagsProbe"
        /usr/bin/chflags uchg "$flagsProbe"
        /usr/bin/chflags nouchg "$flagsProbe"
        /bin/rm -f "$flagsProbe"

        \(dnsRestoreSnippet)

        if [ -e "$launchDaemon" ]; then
            /bin/launchctl unload -w "$launchDaemon" >/dev/null 2>&1 || true
        fi
        /bin/launchctl remove "$helperLabel" >/dev/null 2>&1 || true

        /usr/bin/chflags nouchg "$helperCore" 2>/dev/null || true
        /usr/bin/chflags nouchg "$trustReceipt" 2>/dev/null || true
        /bin/rm -f "$launchDaemon" "$helperDestination" "$helperCore" "$trustReceipt"

        /usr/bin/install -o root -g wheel -m 0555 "$coreSource" "$helperCore"
        installedCoreSHA256=$(/usr/bin/shasum -a 256 "$helperCore" | /usr/bin/awk '{print tolower($1)}')
        [ "$installedCoreSHA256" = "$expectedCoreSHA256" ] || exit 1

        cat > "$receiptTemporary" <<'CLASHFX_TRUST_RECEIPT'
        \(receiptXML)
        CLASHFX_TRUST_RECEIPT
        /usr/bin/install -o root -g wheel -m 0444 "$receiptTemporary" "$trustReceipt"
        /bin/rm -f "$receiptTemporary"
        /usr/bin/chflags uchg "$helperCore" "$trustReceipt"

        /usr/bin/install -o root -g wheel -m 0755 "$helperSource" "$helperDestination"
        installedHelperSHA256=$(/usr/bin/shasum -a 256 "$helperDestination" | /usr/bin/awk '{print tolower($1)}')
        [ "$installedHelperSHA256" = "$expectedHelperSHA256" ] || exit 1
        cat > "$launchDaemon" <<'CLASHFX_LAUNCHD_PLIST'
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Label</key>
        <string>\(xmlEscaped(helperLabel))</string>
        <key>MachServices</key>
        <dict>
        <key>\(xmlEscaped(helperLabel))</key>
        <true/>
        </dict>
        <key>Program</key>
        <string>\(xmlEscaped(helperDestination))</string>
        <key>ProgramArguments</key>
        <array>
        <string>\(xmlEscaped(helperDestination))</string>
        </array>
        </dict>
        </plist>
        CLASHFX_LAUNCHD_PLIST
        /usr/sbin/chown root:wheel "$launchDaemon"
        /bin/chmod 0644 "$launchDaemon"

        /bin/launchctl load -w "$launchDaemon"
        """
    }

    private func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func xmlEscaped(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    @discardableResult
    func runScriptWithRootPermission(script: String) -> Bool {
        let encodedScript = Data(script.utf8).base64EncodedString()
        let shellCommand = "/bin/bash -c \(shellQuoted("/usr/bin/printf '%s' \(shellQuoted(encodedScript)) | /usr/bin/base64 -D | /bin/bash"))"
        let escapedCommand = shellCommand
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = NSAppleScript(source:
            "do shell script \"\(escapedCommand)\" with administrator privileges")
        var error: NSDictionary?
        if appleScript?.executeAndReturnError(&error) == nil {
            Logger.log("legacy helper install script failed: \(String(describing: error))", level: .error)
            return false
        } else {
            Logger.log("legacy helper install script completed", level: .info)
            return true
        }
    }

    @discardableResult
    func legacyInstallHelper(dnsSnapshotJSONBase64: String? = nil) -> Bool {
        defer {
            resetConnection()
        }
        let script = getInstallScript(dnsSnapshotJSONBase64: dnsSnapshotJSONBase64)
        return runScriptWithRootPermission(script: script)
    }

    func removeInstallHelper() {
        defer {
            resetConnection()
            Thread.sleep(forTimeInterval: 5)
        }
        let script = """
        /bin/launchctl remove \(PrivilegedHelperManager.machServiceName) || true
        /usr/bin/killall -u root -9 \(PrivilegedHelperManager.machServiceName)
        /usr/bin/chflags nouchg \(shellQuoted(PrivilegedHelperManager.approvedCorePath)) \(shellQuoted(PrivilegedHelperManager.trustReceiptPath)) 2>/dev/null || true
        /bin/rm -f \(shellQuoted("/Library/LaunchDaemons/\(PrivilegedHelperManager.machServiceName).plist"))
        /bin/rm -f \(shellQuoted("/Library/PrivilegedHelperTools/\(PrivilegedHelperManager.machServiceName)")) \(shellQuoted(PrivilegedHelperManager.approvedCorePath)) \(shellQuoted(PrivilegedHelperManager.trustReceiptPath))
        """

        _ = runScriptWithRootPermission(script: script)
    }
}
