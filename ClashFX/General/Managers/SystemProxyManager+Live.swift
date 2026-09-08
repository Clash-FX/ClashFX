import Foundation

/// App-only wiring. This source is deliberately excluded from the unhosted tests.
extension SystemProxyManager {
    static let shared = SystemProxyManager(dependencies: SystemProxyDependencies(
        defaults: .standard,
        helper: { failure in
            guard let remote = PrivilegedHelperManager.shared.helper(failture: failure) else { return nil }
            return SystemProxyHelperClient(
                getCurrentProxySetting: { reply in remote.getCurrentProxySetting { reply($0) } },
                enable: { port, socks, filter, ignore, reply in
                    remote.enableProxy(withPort: port, socksPort: socks, pac: nil,
                                       filterInterface: filter, ignoreList: ignore, error: reply)
                },
                disable: { filter, reply in remote.disableProxy(withFilterInterface: filter, reply: reply) },
                restore: { port, socks, info, filter, reply in
                    remote.restoreProxy(withCurrentPort: port, socksPort: socks, info: info,
                                        filterInterface: filter, error: reply)
                }
            )
        },
        currentPorts: {
            (ConfigManager.shared.currentConfig?.usedHttpPort ?? 0,
             ConfigManager.shared.currentConfig?.usedSocksPort ?? 0)
        },
        shouldSuspend: { SSIDSuspendTool.shared.shouldSuspend() },
        disableRestoreProxy: { Settings.disableRestoreProxy },
        filterInterface: { Settings.filterInterface },
        proxyIgnoreList: { Settings.proxyIgnoreList },
        liveSystemPointsToClashFX: { NetworkChangeNotifier.isCurrentSystemSetToClash() }
    ))
}
