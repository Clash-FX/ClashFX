import Foundation

let kConfigFolderPath = "\(NSHomeDirectory())/.config/clashfx/"
let kLegacyConfigFolderPath = "\(NSHomeDirectory())/.config/clash/"

let kDefaultConfigFilePath = "\(kConfigFolderPath)config.yaml"
let kProfileMixinFilePath = "\(kConfigFolderPath).profile_mixin.yaml"

enum Paths {
    static func localConfigPath(for name: String) -> String {
        return "\(kConfigFolderPath)\(configFileName(for: name))"
    }

    static func configFileName(for name: String) -> String {
        return "\(name).yaml"
    }

    static var profileMixinPath: String {
        return kProfileMixinFilePath
    }

    static func migrateFromLegacyIfNeeded() {
        let fm = FileManager.default
        var isDir: ObjCBool = true

        guard !fm.fileExists(atPath: kConfigFolderPath, isDirectory: &isDir) else { return }
        guard fm.fileExists(atPath: kLegacyConfigFolderPath, isDirectory: &isDir), isDir.boolValue else { return }

        do {
            try fm.copyItem(atPath: kLegacyConfigFolderPath, toPath: kConfigFolderPath)
            NSLog("[ClashFX] Migrated config from %@ to %@", kLegacyConfigFolderPath, kConfigFolderPath)
        } catch {
            NSLog("[ClashFX] Config migration failed: %@", error.localizedDescription)
        }
    }
}
