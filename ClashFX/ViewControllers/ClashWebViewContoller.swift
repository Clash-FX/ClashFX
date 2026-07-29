//
//  ClashWebViewContoller.swift
//  ClashX
//
//  Created by yicheng on 2018/8/28.
//  Copyright © 2018年 west2online. All rights reserved.
//

import Cocoa
import RxCocoa
import RxSwift
import WebKit

enum WebCacheCleaner {
    static func clean() {
        DispatchQueue.global(qos: .utility).async {
            HTTPCookieStorage.shared.removeCookies(since: Date.distantPast)
            Logger.log("[WebCacheCleaner] All cookies deleted")
        }
        DispatchQueue.main.async {
            let store = WKWebsiteDataStore.default()
            store.fetchDataRecords(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes()) { records in
                for record in records {
                    store.removeData(ofTypes: record.dataTypes, for: [record], completionHandler: {})
                    Logger.log("[WebCacheCleaner] Record \(record) deleted")
                }
            }
        }
    }
}

class ClashWebViewContoller: NSViewController {
    let webview: CustomWKWebView = .init()
    var bridge: JSBridge?
    let disposeBag = DisposeBag()
    let minSize = NSSize(width: 920, height: 580)

    let effectView = NSVisualEffectView()

    private static let apiGuardJS: String = """
    (function() {
      var BLOCKED = ['/upgrade', '/restart'];
      var orig = window.fetch;
      window.fetch = function(input, init) {
        var url = (typeof input === 'string') ? input : (input.url || '');
        for (var i = 0; i < BLOCKED.length; i++) {
          if (url.indexOf(BLOCKED[i]) !== -1) {
            var method = ((init && init.method) || 'GET').toUpperCase();
            if (method === 'POST' || method === 'PUT' || method === 'PATCH') {
              return Promise.resolve(new Response(
                JSON.stringify({message: 'Managed by ClashFX'}),
                {status: 403, headers: {'Content-Type': 'application/json'}}
              ));
            }
          }
        }
        return orig.apply(this, arguments);
      };
      var origXHR = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(method, url) {
        for (var i = 0; i < BLOCKED.length; i++) {
          if (url.indexOf(BLOCKED[i]) !== -1 && /^(POST|PUT|PATCH)$/i.test(method)) {
            this._blocked = true;
          }
        }
        return origXHR.apply(this, arguments);
      };
      var origSend = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.send = function() {
        if (this._blocked) {
          Object.defineProperty(this, 'status', {get: function(){return 403}});
          Object.defineProperty(this, 'responseText', {get: function(){return '{"message":"Managed by ClashFX"}'}});
          if (typeof this.onload === 'function') this.onload();
          return;
        }
        return origSend.apply(this, arguments);
      };
    })();
    """

    private static func dashboardUpgradePolicyJS(managedMessage: String) -> String {
        let escapedManagedMessage = managedMessage
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
          var MANAGED_MESSAGE = '\(escapedManagedMessage)';
          var VERSION_PATTERN = /^v?\\d+\\.\\d+\\.\\d+(?:[-+][0-9A-Za-z.-]+)?$/;
          var HIDE_LABELS = ['GEO Databases', 'Dashboard UI', 'Restart', 'Upgrade'];
          function hideItems(root) {
            var labels = root.querySelectorAll('div');
            for (var i = 0; i < labels.length; i++) {
              var el = labels[i];
              if (el.children.length > 0) continue;
              var txt = el.textContent.trim();
              for (var j = 0; j < HIDE_LABELS.length; j++) {
                if (txt.indexOf(HIDE_LABELS[j]) !== -1) {
                  var row = el.parentElement;
                  if (row) row.style.display = 'none';
                  break;
                }
              }
            }
          }
          function removeUpdateIndicator(button) {
            var candidates = button.querySelectorAll('span');
            for (var i = candidates.length - 1; i >= 0; i--) {
              var candidate = candidates[i];
              if (candidate.querySelector('.animate-ping')) {
                candidate.remove();
              }
            }
          }
          function manageVersionButtons(root) {
            var buttons = root.querySelectorAll('button');
            var containers = [];
            for (var i = 0; i < buttons.length; i++) {
              var button = buttons[i];
              var text = button.textContent.trim();
              var collapsedTitle = button.getAttribute('title') || '';
              var isExpandedVersion = VERSION_PATTERN.test(text);
              var isCollapsedVersions = /^UI\\s+v?\\d+\\.\\d+\\.\\d+.*Core\\s+v?\\d+\\.\\d+\\.\\d+/.test(collapsedTitle);
              if (!isExpandedVersion && !isCollapsedVersions) continue;
              removeUpdateIndicator(button);
              button.dataset.clashfxManagedVersion = 'true';
              button.style.cursor = 'default';
              button.style.pointerEvents = 'none';
              var versionText = isCollapsedVersions ? collapsedTitle.split(' — ')[0] : text;
              button.setAttribute('title', versionText + ' — ' + MANAGED_MESSAGE);
              button.setAttribute('aria-label', versionText + ' — ' + MANAGED_MESSAGE);
              if (isExpandedVersion && button.parentElement &&
                  containers.indexOf(button.parentElement) === -1) {
                containers.push(button.parentElement);
              }
            }
            for (var j = 0; j < containers.length; j++) {
              var container = containers[j];
              var versionButtons = container.querySelectorAll('button[data-clashfx-managed-version="true"]');
              if (versionButtons.length < 2 ||
                  container.querySelector('[data-clashfx-managed-note="true"]')) {
                continue;
              }
              var note = document.createElement('div');
              note.dataset.clashfxManagedNote = 'true';
              note.textContent = MANAGED_MESSAGE;
              note.style.fontSize = '11px';
              note.style.lineHeight = '1.25';
              note.style.textAlign = 'center';
              note.style.opacity = '0.6';
              note.style.padding = '2px 4px 0';
              container.appendChild(note);
            }
          }
          function applyPolicy() {
            hideItems(document);
            manageVersionButtons(document);
          }
          var mo = new MutationObserver(applyPolicy);
          mo.observe(document.documentElement, {childList: true, subtree: true});
          document.addEventListener('DOMContentLoaded', applyPolicy);
          applyPolicy();
        })();
        """
    }

    private static func metaCubeXDConfigJS(port: String, secret: String) -> String {
        let backendURL = "http://127.0.0.1:\(port)"
        let escapedBackendURL = backendURL.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        let escapedSecret = secret.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
        return """
        window.__METACUBEXD_CONFIG__ = {
          defaultBackendURL: '\(escapedBackendURL)',
          defaultBackendSecret: '\(escapedSecret)'
        };
        """
    }

    private static func dashboardRulesSnapshotJS(port: String, staleMessage: String) -> String {
        let backendURL = "http://127.0.0.1:\(port)"
        let escapedBackendURL = backendURL
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let escapedStaleMessage = staleMessage
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")
        return """
        (function() {
          var BACKEND_ORIGIN = '\(escapedBackendURL)';
          var STALE_MESSAGE = '\(escapedStaleMessage)';
          var BANNER_ID = 'clashfx-stale-rules-banner';
          var rulesSnapshot = null;
          var originalFetch = window.fetch;

          function isRulesRequest(input, init) {
            var method = ((init && init.method) ||
              (typeof input !== 'string' && input.method) || 'GET').toUpperCase();
            if (method !== 'GET') return false;
            var rawURL = (typeof input === 'string') ? input : (input.url || '');
            try {
              var url = new URL(rawURL, window.location.href);
              return url.origin === BACKEND_ORIGIN && url.pathname === '/rules';
            } catch (_) {
              return false;
            }
          }

          function showStaleBanner() {
            if (document.getElementById(BANNER_ID)) return;
            var banner = document.createElement('div');
            banner.id = BANNER_ID;
            banner.textContent = STALE_MESSAGE;
            banner.style.position = 'fixed';
            banner.style.top = '10px';
            banner.style.left = '50%';
            banner.style.transform = 'translateX(-50%)';
            banner.style.zIndex = '2147483647';
            banner.style.padding = '7px 12px';
            banner.style.borderRadius = '8px';
            banner.style.background = 'rgba(154, 87, 0, 0.94)';
            banner.style.color = '#fff';
            banner.style.font = '12px -apple-system, BlinkMacSystemFont, sans-serif';
            banner.style.boxShadow = '0 2px 8px rgba(0, 0, 0, 0.22)';
            banner.style.pointerEvents = 'none';
            (document.body || document.documentElement).appendChild(banner);
          }

          function hideStaleBanner() {
            var banner = document.getElementById(BANNER_ID);
            if (banner) banner.remove();
          }

          function rememberRules(response) {
            response.clone().text().then(function(text) {
              try {
                var payload = JSON.parse(text);
                if (!Array.isArray(payload.rules)) return;
                rulesSnapshot = text;
                hideStaleBanner();
              } catch (_) {}
            });
          }

          function staleRulesResponse() {
            showStaleBanner();
            console.warn('[ClashFX] Core unavailable; serving the last valid rules snapshot');
            return new Response(rulesSnapshot, {
              status: 200,
              headers: {
                'Content-Type': 'application/json',
                'X-ClashFX-Stale-Snapshot': 'rules'
              }
            });
          }

          window.fetch = function(input, init) {
            if (!isRulesRequest(input, init)) {
              return originalFetch.apply(this, arguments);
            }
            var receiver = this;
            var args = arguments;
            return originalFetch.apply(receiver, args).then(function(response) {
              if (response && response.ok) {
                rememberRules(response);
                return response;
              }
              if (rulesSnapshot && response && response.status >= 500) {
                return staleRulesResponse();
              }
              return response;
            }).catch(function(error) {
              if (rulesSnapshot) return staleRulesResponse();
              throw error;
            });
          };
        })();
        """
    }

    private static func metaCubeXDSetupURL(port: String, secret: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=+")

        var setupURL = "http://127.0.0.1:\(port)/ui/#/setup?hostname=127.0.0.1&port=\(port)&http=true"
        if !secret.isEmpty {
            let escapedSecret = secret.addingPercentEncoding(withAllowedCharacters: allowed) ?? secret
            setupURL += "&secret=\(escapedSecret)"
        }
        return URL(string: setupURL)
    }

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: minSize))
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupView()
        webview.uiDelegate = self
        webview.navigationDelegate = self

        webview.customUserAgent = "ClashFX Runtime"
        if #available(macOS 13.3, *) {
            webview.isInspectable = true
        }
        let port = ConfigManager.shared.apiPort
        let secret = ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret
        let metaCubeXDConfigScript = WKUserScript(source: Self.metaCubeXDConfigJS(port: port, secret: secret), injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let guardScript = WKUserScript(source: Self.apiGuardJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        let staleRulesMessage = NSLocalizedString(
            "Core temporarily unavailable; showing the last valid rules snapshot",
            comment: ""
        )
        let rulesSnapshotScript = WKUserScript(
            source: Self.dashboardRulesSnapshotJS(port: port, staleMessage: staleRulesMessage),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        let managedMessage = NSLocalizedString(
            "Dashboard and core updates are managed by ClashFX",
            comment: ""
        )
        let hideScript = WKUserScript(
            source: Self.dashboardUpgradePolicyJS(managedMessage: managedMessage),
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true
        )
        webview.configuration.userContentController.addUserScript(metaCubeXDConfigScript)
        webview.configuration.userContentController.addUserScript(guardScript)
        webview.configuration.userContentController.addUserScript(rulesSnapshotScript)
        webview.configuration.userContentController.addUserScript(hideScript)

        bridge = JsBridgeUtil.initJSbridge(webview: webview, delegate: self)

        webview.configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")

        NotificationCenter.default.rx.notification(.reloadDashboard).bind {
            [weak self] _ in
            self?.webview.reload()
        }.disposed(by: disposeBag)

        loadWebRecourses()
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        configureWindowAppearance()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        configureWindowAppearance()
    }

    private func configureWindowAppearance() {
        guard let window = view.window else { return }
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = false
        window.styleMask.remove(.fullSizeContentView)
        window.toolbar = nil
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.minSize = minSize

        view.wantsLayer = true
        view.layer?.cornerRadius = 0
    }

    func setupView() {
        view.addSubview(effectView)
        view.addSubview(webview)
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        effectView.frame = view.bounds
        webview.frame = view.bounds
    }

    func loadWebRecourses() {
        WKWebsiteDataStore.default().removeData(
            ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
            modifiedSince: Date(timeIntervalSince1970: 0),
            completionHandler: {}
        )
        // defaults write com.clashfx.app webviewUrl "your url"
        if let userDefineUrl = UserDefaults.standard.string(forKey: "webviewUrl"), let url = URL(string: userDefineUrl) {
            Logger.log("get user define url: \(url)")
            webview.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 0))
            return
        }
        let port = ConfigManager.shared.apiPort
        let secret = ConfigManager.shared.overrideSecret ?? ConfigManager.shared.apiSecret
        if let url = Self.metaCubeXDSetupURL(port: port, secret: secret) {
            Logger.log("dashboard url:http://127.0.0.1:\(port)/ui/#/setup")
            webview.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 0))
            return
        }
        Logger.log("load dashboard url fail", level: .error)
    }

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping () -> Void) {
        NSAlert.alert(with: message)
        completionHandler()
    }
}

extension ClashWebViewContoller: WKUIDelegate, WKNavigationDelegate {
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        Logger.log("[dashboard] webview crashed", level: .error)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {}

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        Logger.log("[dashboard] load request \(String(describing: navigationAction.request.url?.absoluteString))", level: .debug)
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Logger.log("[dashboard] didFinish \(String(describing: navigation))", level: .info)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Logger.log("[dashboard] \(String(describing: navigation)) error: \(error)", level: .error)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil {
            webView.load(navigationAction.request)
        }
        return nil
    }
}

class CustomWKWebView: WKWebView {
    var dragableAreaHeight: CGFloat = 30
    let alwaysDragableLeftAreaWidth: CGFloat = 150

    private func isInDargArea(with event: NSEvent?) -> Bool {
        guard let event = event else { return false }
        let x = event.locationInWindow.x
        let y = (window?.frame.size.height ?? 0) - event.locationInWindow.y
        return x < alwaysDragableLeftAreaWidth || y < dragableAreaHeight
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        if isInDargArea(with: event) {
            return true
        }
        return super.acceptsFirstMouse(for: event)
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        if isInDargArea(with: event) {
            window?.performDrag(with: event)
        }
    }
}
