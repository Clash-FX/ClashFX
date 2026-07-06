import Foundation

let kConfigFolderPath = "\(NSHomeDirectory())/.config/clashfx/"
let kLegacyConfigFolderPath = "\(NSHomeDirectory())/.config/clash/"

let kDefaultConfigFilePath = "\(kConfigFolderPath)config.yaml"
let kProfileMixinFileName = ".profile_mixin.yaml"
let kICloudProfileMixinFileName = "Profile Mixin.yaml"
let kProfileMixinFilePath = "\(kConfigFolderPath)\(kProfileMixinFileName)"

enum Paths {
    static func localConfigPath(for name: String) -> String {
        return "\(kConfigFolderPath)\(configFileName(for: name))"
    }

    static func configFileName(for name: String) -> String {
        return "\(name).yaml"
    }

    static var profileMixinPath: String {
        if ICloudManager.shared.useiCloud.value,
           var url = FileManager.default.url(forUbiquityContainerIdentifier: nil) {
            url.appendPathComponent("Documents")
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
            return iCloudProfileMixinURL(in: url).path
        }
        return kProfileMixinFilePath
    }

    static func iCloudProfileMixinURL(in documentsURL: URL) -> URL {
        documentsURL.appendingPathComponent(kICloudProfileMixinFileName)
    }

    static func legacyICloudProfileMixinURL(in documentsURL: URL) -> URL {
        documentsURL.appendingPathComponent(kProfileMixinFileName)
    }

    static func isProfileMixinFileName(_ fileName: String) -> Bool {
        fileName == kProfileMixinFileName || fileName == kICloudProfileMixinFileName
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
