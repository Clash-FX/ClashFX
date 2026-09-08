import Foundation

/// Pure ownership rules for the saved system-proxy snapshot.  The privileged
/// helper deliberately receives only property-list dictionaries; this type
/// keeps the decision about whether a dictionary belongs to ClashFX in the
/// unprivileged app, before it can replace the user's original settings.
struct SystemProxyOperationPolicy {
    static let savedSnapshotKey = "kSavedProxyInfo"
    static let savedSnapshotValidityKey = "kSavedProxyInfoValid"
    static let captureErrorKey = "__ClashFXProxyCaptureError"
    static let capturedServiceIDsKey = "__ClashFXCapturedServiceIDs"

    private(set) var activeGeneration: UInt64 = 0

    mutating func beginTransition() -> UInt64 {
        activeGeneration &+= 1
        if activeGeneration == 0 {
            activeGeneration = 1
        }
        return activeGeneration
    }

    func acceptsCallback(for generation: UInt64) -> Bool {
        return generation == activeGeneration
    }

    static func isValidPropertyListSnapshot(_ snapshot: [String: Any]) -> Bool {
        return PropertyListSerialization.propertyList(snapshot, isValidFor: .binary)
    }

    static func captureError(in snapshot: [String: Any]) -> String? {
        return snapshot[captureErrorKey] as? String
    }

    static func restoredSnapshotMatches(expected: [String: Any], actual: [String: Any]) -> Bool {
        guard captureError(in: actual) == nil,
              let currentServices = actual[capturedServiceIDsKey] as? [String] else { return false }
        let capturedServices = Set(expected[capturedServiceIDsKey] as? [String] ?? [])
        for serviceID in currentServices {
            if let saved = expected[serviceID] as? [String: Any] {
                guard let current = actual[serviceID] as? [String: Any],
                      NSDictionary(dictionary: saved).isEqual(to: current) else { return false }
            } else if capturedServices.contains(serviceID), actual[serviceID] != nil {
                return false
            }
        }
        // Removed services cannot be restored; new, uncaptured services are left alone.
        return true
    }

    /// Old releases persisted only the dictionary, not its ownership marker.
    /// It can be promoted exactly once, but only while the live system still
    /// points at ClashFX and the dictionary is demonstrably a non-ClashFX,
    /// property-list snapshot. Otherwise a fresh capture is safer.
    static func shouldMigrateLegacySnapshot(
        _ snapshot: [String: Any],
        validityMarker: Bool,
        liveSystemPointsToClashFX: Bool,
        httpPort: Int,
        socksPort: Int
    ) -> Bool {
        guard !validityMarker,
              liveSystemPointsToClashFX,
              !snapshot.isEmpty,
              captureError(in: snapshot) == nil,
              isValidPropertyListSnapshot(snapshot),
              snapshot.contains(where: { key, value in
                  !key.hasPrefix("__ClashFX") && value is [String: Any]
              }),
              !isClashFXOwnedSnapshot(snapshot, httpPort: httpPort, socksPort: socksPort) else {
            return false
        }
        return true
    }

    /// A snapshot is considered ClashFX-owned only when one of its service
    /// dictionaries fully matches the loopback proxy shape we write.  A
    /// partial proxy or PAC-only setup must never be treated as owned merely
    /// because it happens to use localhost.
    static func isClashFXOwnedSnapshot(_ snapshot: [String: Any], httpPort: Int, socksPort: Int) -> Bool {
        for (serviceID, rawValue) in snapshot where !serviceID.hasPrefix("__ClashFX") {
            guard let value = rawValue as? [String: Any],
                  bool(value["HTTPEnable"]),
                  bool(value["HTTPSEnable"]),
                  bool(value["SOCKSEnable"]),
                  value["HTTPProxy"] as? String == "127.0.0.1",
                  value["HTTPSProxy"] as? String == "127.0.0.1",
                  value["SOCKSProxy"] as? String == "127.0.0.1",
                  integer(value["HTTPPort"]) == httpPort,
                  integer(value["HTTPSPort"]) == httpPort,
                  integer(value["SOCKSPort"]) == socksPort else {
                continue
            }
            return true
        }
        return false
    }

    private static func bool(_ value: Any?) -> Bool {
        return (value as? NSNumber)?.boolValue ?? false
    }

    private static func integer(_ value: Any?) -> Int {
        return (value as? NSNumber)?.intValue ?? 0
    }
}
