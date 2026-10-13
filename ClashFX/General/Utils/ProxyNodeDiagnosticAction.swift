import AppKit

/// Explicit, one-node probe. It shares benchmark cancellation and excludes
/// selection work, but never changes a policy group's selection itself.
final class ProxyNodeDiagnosticAction {
    static let shared = ProxyNodeDiagnosticAction()
    private var activeSession: ApiRequest.BenchmarkSession?
    private var snapshot: ClashProxyResp?

    func present() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard activeSession == nil,
              let session = AppDelegate.shared.beginSpeedTest(showNotifications: false) else { return }
        activeSession = session
        let config = ConfigManager.selectConfigName
        let endpoint = ConfigManager.apiUrl
        let remoteID = RemoteControlManager.selectConfig?.uuid
        let generation = AppDelegate.shared.proxySelectionGeneration
        let isCurrent: () -> Bool = {
            !session.isCancelled && AppDelegate.shared.isActiveBenchmarkSession(session)
                && ConfigManager.selectConfigName == config && ConfigManager.apiUrl == endpoint
                && RemoteControlManager.selectConfig?.uuid == remoteID
                && !AppDelegate.shared.isConfigUpdating
                && AppDelegate.shared.proxySelectionGeneration == generation
        }
        ApiRequest.getMergedProxyData(session: session, timeout: 10) { [weak self] response in
            guard let self else { return }
            guard isCurrent(), let response else {
                self.finish(session)
                if !session.isCancelled, !AppDelegate.shared.isTerminating {
                    NSAlert.alert(with: NSLocalizedString("Could not load nodes for a diagnostic probe.", comment: ""))
                }
                return
            }
            guard ApiRequest.prepareBenchmarkProbeDiagnostics(using: response, session: session) else {
                self.finish(session)
                return
            }
            self.snapshot = response
            let nodes = response.proxies.filter {
                $0.all == nil && !ClashProxyType.isProxyGroup($0)
                    && !ClashProxyType.isBuiltInProxy($0) && !ClashProxyType.isCompatibilityFallback($0)
            }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            guard !nodes.isEmpty else {
                self.finish(session)
                NSAlert.alert(with: NSLocalizedString("No testable proxy nodes", comment: ""))
                return
            }
            let picker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
            nodes.forEach { picker.addItem(withTitle: $0.name) }
            let urlField = NSTextField(string: Settings.benchMarkUrl)
            urlField.widthAnchor.constraint(equalToConstant: 420).isActive = true
            let modePicker = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 420, height: 26))
            modePicker.addItems(withTitles: [NSLocalizedString("Quick (2.5 s)", comment: ""),
                                           NSLocalizedString("Complete (5 s)", comment: "")])
            modePicker.selectItem(at: Settings.benchmarkMode == .quick ? 0 : 1)
            let stack = NSStackView(views: [
                NSTextField(labelWithString: NSLocalizedString("Node:", comment: "")), picker,
                NSTextField(labelWithString: NSLocalizedString("Benchmark URL:", comment: "")), urlField,
                NSTextField(labelWithString: NSLocalizedString("Probe timeout:", comment: "")), modePicker
            ])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 6
            stack.setFrameSize(stack.fittingSize)
            let alert = NSAlert()
            alert.messageText = NSLocalizedString("Single-node Benchmark Diagnostic", comment: "")
            alert.informativeText = NSLocalizedString("Test one node without setting manual priority. Automatic groups still follow the core.", comment: "")
            alert.accessoryView = stack
            alert.addButton(withTitle: NSLocalizedString("Run Diagnostic", comment: ""))
            alert.addButton(withTitle: NSLocalizedString("Cancel", comment: ""))
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn, isCurrent() else {
                self.finish(session)
                return
            }
            let url = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let components = URLComponents(string: url),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  components.host?.isEmpty == false,
                  components.url != nil else {
                self.finish(session)
                NSAlert.alert(with: NSLocalizedString("Enter a valid HTTP or HTTPS benchmark URL.", comment: ""))
                return
            }
            guard nodes.indices.contains(picker.indexOfSelectedItem) else {
                self.finish(session)
                return
            }
            let node = nodes[picker.indexOfSelectedItem]
            let timeout = modePicker.indexOfSelectedItem == 0 ? 2500 : 5000
            let identity = LeafProxyBenchmarkIdentity(proxy: node)
            let conditions = BenchmarkConditions(url: url)
            let completed: (ProxyDelayOutcome) -> Void = { outcome in
                guard isCurrent(), outcome != .cancelled else { self.finish(session); return }
                GlobalLeafBenchmarkPresentationStore.publish(.init(
                    identity: identity, benchmarkURL: url, sessionIdentifier: UUID(), rowState: outcome.rowState(name: node.name)
                ))
                let diagnostic = ApiRequest.latestBenchmarkProbeDiagnostic(for: node, conditions: conditions)
                self.finish(session)
                guard let diagnostic else {
                    NSAlert.alert(with: NSLocalizedString("The probe completed, but its diagnostic record could not be confirmed.", comment: ""))
                    return
                }
                self.showReport(diagnostic.localizedReport)
            }
            if let provider = node.enclosingProvider {
                ApiRequest.getProviderProxyDelayOutcome(providerName: provider.name, proxyName: node.name,
                    benchmarkURL: url, timeout: timeout, session: session, identity: identity, callback: completed)
            } else {
                ApiRequest.getProxyDelayOutcome(proxyName: node.name, benchmarkURL: url,
                    timeout: timeout, session: session, identity: identity, callback: completed)
            }
        }
    }

    private func finish(_ session: ApiRequest.BenchmarkSession) {
        if AppDelegate.shared.isActiveBenchmarkSession(session) {
            AppDelegate.shared.finishSpeedTest(session: session, showNotifications: false)
        }
        if activeSession === session { activeSession = nil; snapshot = nil }
    }

    private func showReport(_ report: String) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 280))
        text.isEditable = false
        text.isSelectable = true
        text.font = NSFont.userFixedPitchFont(ofSize: 12)
        text.autoresizingMask = [.width]
        text.isVerticallyResizable = true
        text.textContainer?.widthTracksTextView = true
        text.string = report
        text.textContainerInset = NSSize(width: 8, height: 8)
        let scroll = NSScrollView(frame: text.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = text
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Single-node Benchmark Diagnostic", comment: "")
        alert.accessoryView = scroll
        alert.addButton(withTitle: NSLocalizedString("OK", comment: ""))
        alert.addButton(withTitle: NSLocalizedString("Copy Diagnostic Report", comment: ""))
        if alert.runModal() == .alertSecondButtonReturn {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }
}
