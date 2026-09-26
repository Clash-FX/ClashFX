import Cocoa
import WebKit
import XCTest

final class DashboardContrastIntegrationTests: XCTestCase, WKNavigationDelegate {
    private var loaded: XCTestExpectation?
    private var views = [WKWebView]()
    private var root: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    override func tearDown() {
        views.forEach { $0.stopLoading(); $0.navigationDelegate = nil }
        views.removeAll()
        loaded = nil
        super.tearDown()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded?.fulfill()
        loaded = nil
    }

    private func load(legacy: Bool = true) throws -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        // This is fault injection, not an assertion that modern WebKit emulates
        // every old WebKit bug. Force only the rendered capability probe to fail.
        // Timers stand in for rAF because offscreen WKWebViews throttle frames.
        var harness = "window.requestAnimationFrame = function (callback) { return setTimeout(callback, 0); };\n"
        if legacy {
            harness += """
            (function () {
              var original = window.getComputedStyle;
              window.getComputedStyle = function (element, pseudo) {
                if (element.style && element.style.getPropertyValue('--clashfx-probe-color')) {
                  return { backgroundColor: 'rgba(0, 0, 0, 0)' };
                }
                return original.call(window, element, pseudo);
              };
            })();
            """
        }
        config.userContentController.addUserScript(WKUserScript(source: harness, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let source = try String(contentsOf: root.appendingPathComponent("ClashFX/Resources/DashboardCompatibility/clashfx-compat.js"), encoding: .utf8)
        config.userContentController.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let cssDir = root.appendingPathComponent("ClashFX/Resources/dashboard/_nuxt")
        let entries = try FileManager.default.contentsOfDirectory(at: cssDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("entry.") && $0.pathExtension == "css" }
        XCTAssertEqual(entries.count, 1, "Use the actual bundled entry CSS")
        let css = try String(contentsOf: XCTUnwrap(entries.first), encoding: .utf8)
        let template = try String(contentsOf: root.appendingPathComponent("ClashFXTests/Fixtures/dashboard-legacy-contrast.html"), encoding: .utf8)
        let html = template.replacingOccurrences(of: "/* DASHBOARD_CSS */", with: css)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 920, height: 875), configuration: config)
        views.append(view)
        view.navigationDelegate = self
        let loadFinished = expectation(description: "isolated dashboard fixture")
        loaded = loadFinished
        view.loadHTMLString(html, baseURL: nil)
        wait(for: [loadFinished], timeout: 15)
        return view
    }

    @discardableResult
    private func js(_ view: WKWebView, _ source: String) throws -> Any? {
        let done = expectation(description: "evaluate rendered fixture")
        var result: Any?
        var failure: Error?
        view.evaluateJavaScript(source) { value, error in result = value; failure = error; done.fulfill() }
        wait(for: [done], timeout: 5)
        if let failure { throw failure }
        return result
    }

    private func eventually(_ view: WKWebView, _ expression: String) {
        let done = expectation(description: expression)
        var stopped = false
        func poll() {
            guard !stopped else { return }
            view.evaluateJavaScript(expression) { value, error in
                guard !stopped else { return }
                if let error { XCTFail("\(error)"); done.fulfill(); return }
                if value as? Bool == true { done.fulfill(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02, execute: poll)
            }
        }
        poll()
        wait(for: [done], timeout: 5)
        stopped = true
    }

    private func sample(_ view: WKWebView, _ id: String) throws -> [String: Any] {
        let source = """
        (function () {
          var element = document.getElementById('\(id)'), style = getComputedStyle(element);
          return { color: style.color, background: style.backgroundColor, opacity: Number(style.opacity),
                   width: element.getBoundingClientRect().width };
        })()
        """
        return try XCTUnwrap(js(view, source) as? [String: Any])
    }

    private func channels(_ value: String) -> [Double] {
        let numbers = value.replacingOccurrences(of: "rgba(", with: "").replacingOccurrences(of: "rgb(", with: "")
            .replacingOccurrences(of: ")", with: "").split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        XCTAssertGreaterThanOrEqual(numbers.count, 3, value)
        return numbers.count == 3 ? numbers + [1] : numbers
    }

    private func contrast(_ foreground: String, _ background: String, opacity: Double = 1) -> Double {
        let fg = channels(foreground), bg = channels(background)
        guard fg.count == 4, bg.count == 4 else { return 0 }
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.prefix(3).map { value -> Double in
                let c = value / 255
                return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let alpha = fg[3] * opacity
        let composite = (0 ..< 3).map { fg[$0] * alpha + bg[$0] * (1 - alpha) }
        let first = luminance(composite), second = luminance(bg)
        return (max(first, second) + 0.05) / (min(first, second) + 0.05)
    }

    func testNavigationAndMutedTextAcrossDarkAndLightThemes() throws {
        let view = try load()
        XCTAssertEqual(try js(view, "window.__CLASHFX_DASHBOARD_COMPAT__.fallbackInstalled") as? Bool, true)
        for theme in ["black", "dark", "night", "coffee", "dracula", "dim", "light", "nord"] {
            var ratios = [Double]()
            let before = try XCTUnwrap(js(view, "window.__CLASHFX_DASHBOARD_COMPAT__.styleRebuilds") as? Int)
            try js(view, "document.documentElement.setAttribute('data-theme', '\(theme)'); 0")
            eventually(view, "window.__CLASHFX_DASHBOARD_COMPAT__.styleRebuilds > \(before)")
            let nav = try sample(view, "nav-surface")
            let background = try XCTUnwrap(nav["background"] as? String)
            XCTAssertEqual(channels(background).last, 1, theme)
            XCTAssertGreaterThan(nav["width"] as? Double ?? 0, 0)
            for id in ["inactive-label", "active-label", "more-label"] {
                let element = try sample(view, id)
                let ratio = try contrast(XCTUnwrap(element["color"] as? String), background, opacity: XCTUnwrap(element["opacity"] as? Double))
                ratios.append(ratio)
                XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(theme)/\(id): \(ratio)")
            }
            let tag = try sample(view, "tag"), card = try sample(view, "card")
            XCTAssertGreaterThanOrEqual(try contrast(XCTUnwrap(tag["color"] as? String), XCTUnwrap(card["background"] as? String)), 4.5, theme)
            let popup = try sample(view, "popup"), link = try sample(view, "popup-link")
            XCTAssertGreaterThanOrEqual(try contrast(XCTUnwrap(link["color"] as? String), XCTUnwrap(popup["background"] as? String)), 4.5, theme)
            let minimum = try XCTUnwrap(ratios.min())
            print("Dashboard fixture \(theme): minimum navigation contrast \(String(format: "%.2f", minimum)):1")
        }
    }

    func testClassMutationAndInsertedContentAreBatchedWithoutObserverLoop() throws {
        let view = try load()
        let before = try XCTUnwrap(js(view, "window.__CLASHFX_DASHBOARD_COMPAT__.styleRebuilds") as? Int)
        let mutations = """
        document.getElementById('tag').className = 'text-base-content/43';
        for (var i=0;i<100;i++) {
          var node=document.createElement('span'); node.className='text-base-content/37'; node.textContent='new';
          document.querySelector('main').appendChild(node);
        }
        0
        """
        try js(view, mutations)
        eventually(view, "window.__CLASHFX_DASHBOARD_COMPAT__.styleRebuilds > \(before)")
        XCTAssertEqual(try js(view, "document.getElementById('clashfx-legacy-color-fallbacks').textContent.indexOf('text-base-content/43') >= 0") as? Bool, true)
        let after = try XCTUnwrap(js(view, "window.__CLASHFX_DASHBOARD_COMPAT__.styleRebuilds") as? Int)
        XCTAssertLessThanOrEqual(after - before, 2)
        let done = expectation(description: "observers settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(try js(view, "window.__CLASHFX_DASHBOARD_COMPAT__.styleRebuilds") as? Int, after)
    }

    func testSelectedStateMoreButtonAndDecorativeOpacityRemainCorrect() throws {
        let view = try load()
        let mutations = """
        document.getElementById('inactive').className='text-primary';
        document.getElementById('more').className='bg-primary text-primary-content';
        0
        """
        try js(view, mutations)
        let more = try sample(view, "more")
        XCTAssertGreaterThanOrEqual(try contrast(XCTUnwrap(more["color"] as? String), XCTUnwrap(more["background"] as? String)), 4.5)
        let nav = try sample(view, "nav-surface"), active = try sample(view, "inactive-label")
        XCTAssertGreaterThanOrEqual(try contrast(XCTUnwrap(active["color"] as? String), XCTUnwrap(nav["background"] as? String)), 4.5)
        XCTAssertEqual(try sample(view, "disabled")["opacity"] as? Double, 0.3)
        let chartColor = try XCTUnwrap(sample(view, "chart")["color"] as? String)
        XCTAssertEqual(try XCTUnwrap(channels(chartColor).last), 0.5, accuracy: 0.01)
    }

    func testModernWebKitKeepsUpstreamStylesUntouched() throws {
        let view = try load(legacy: false)
        XCTAssertEqual(try js(view, "window.__CLASHFX_DASHBOARD_COMPAT__.renderedProbe") as? Bool, true)
        XCTAssertEqual(try js(view, "window.__CLASHFX_DASHBOARD_COMPAT__.fallbackInstalled") as? Bool, false)
        XCTAssertEqual(try js(view, "document.getElementById('clashfx-legacy-color-fallbacks') === null") as? Bool, true)
        XCTAssertEqual(try sample(view, "inactive-label")["opacity"] as? Double, 0.8)
    }
}
