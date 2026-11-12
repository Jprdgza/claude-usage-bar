import AppKit
import SwiftUI
import UsageCore
import WebKit

@main
struct ClaudeUsageBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    init() {
        // LSUIElement covers the bundled .app; this covers `swift run`.
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    var body: some Scene {
        MenuBarExtra {
            PopoverView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.scheduler)
        } label: {
            MenuBarLabel(model: model, settings: model.settings)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Opening the app again while it runs (Finder, Spotlight, `open`) shows Settings: the way in when
/// the menu-bar icon is hidden behind the notch or other icons.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static weak var model: AppModel?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { PowerManager.shared.shutdown() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Task { @MainActor in
            if let m = AppDelegate.model { WindowManager.shared.showSettings(model: m) }
        }
        return true
    }
}

/// Settings and login are plain NSWindows (not SwiftUI `Window` scenes), so nothing opens at
/// launch on macOS 14 and they come to the front from an accessory app.
@MainActor final class WindowManager {
    static let shared = WindowManager()
    private var windows: [String: NSWindow] = [:]

    func show<V: View>(_ id: String, title: String, size: NSSize, @ViewBuilder content: () -> V) {
        if let w = windows[id] {
            NSApp.activate(ignoringOtherApps: true)
            w.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = title
        w.isReleasedWhenClosed = false
        w.contentViewController = NSHostingController(rootView: content())
        w.setContentSize(size)
        w.center()
        windows[id] = w
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.windows[id] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    func close(_ id: String) { windows[id]?.close() }

    func showSettings(model: AppModel) {
        show("settings", title: "Claude Usage – Settings", size: NSSize(width: 560, height: 640)) {
            SettingsView().environmentObject(model).environmentObject(model.settings).environmentObject(model.log)
        }
    }

    func showDetails(model: AppModel) {
        show("details", title: "Claude Usage", size: NSSize(width: 720, height: 600)) {
            DetailsView().environmentObject(model).environmentObject(model.settings).environmentObject(model.scheduler)
        }
    }

    func showLogin(model: AppModel) {
        show("login", title: "Log in to Claude", size: NSSize(width: 520, height: 760)) {
            LoginView().environmentObject(model)
        }
    }
}

// MARK: Login

struct LoginView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            Text("Log in to claude.ai. The app keeps only your session cookie, in the macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary).padding(8)
            LoginWebView(model: model)
        }
    }
}

struct LoginWebView: NSViewRepresentable {
    let model: AppModel

    func makeCoordinator() -> Coordinator { Coordinator(model: model) }

    func makeNSView(context: Context) -> WKWebView {
        let v = model.web.makeLoginWebView()
        context.coordinator.attach(v)
        return v
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    @MainActor final class Coordinator: NSObject, WKHTTPCookieStoreObserver, WKNavigationDelegate, WKUIDelegate {
        let model: AppModel
        private var done = false
        private var popups: [NSWindow] = []
        init(model: AppModel) { self.model = model }

        func attach(_ v: WKWebView) {
            v.navigationDelegate = self
            v.uiDelegate = self
            model.web.dataStore.httpCookieStore.add(self)
            model.log.add("Login: user agent suffix \(WebSession.applicationNameForUserAgent)")
        }

        /// Host + path only: login URLs carry tokens in their query strings.
        private func describe(_ url: URL?) -> String {
            guard let url else { return "(none)" }
            return "\(url.host ?? url.scheme ?? "?")\(url.path)"
        }

        // MARK: Navigation logging

        func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse) async -> WKNavigationResponsePolicy {
            if navigationResponse.isForMainFrame, let r = navigationResponse.response as? HTTPURLResponse {
                model.log.add("Login: \(r.statusCode) \(describe(r.url))")
            }
            return .allow
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            model.log.add("Login: navigation failed: \(error.localizedDescription)")
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            model.log.add("Login: load failed: \(error.localizedDescription)")
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            model.log.add("Login: web content process crashed; reloading")
            webView.reload()
        }

        // MARK: Pop-ups ("Continue with Google" / Apple open one)

        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                     for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            model.log.add("Login: pop-up requested for \(describe(navigationAction.request.url))")
            let popup = WKWebView(frame: NSRect(x: 0, y: 0, width: 500, height: 640), configuration: configuration)
            popup.navigationDelegate = self
            popup.uiDelegate = self
            let w = NSWindow(contentRect: popup.frame, styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            w.title = "Sign in"
            w.isReleasedWhenClosed = false
            w.contentView = popup
            w.center()
            w.makeKeyAndOrderFront(nil)
            popups.append(w)
            return popup
        }

        func webViewDidClose(_ webView: WKWebView) {
            model.log.add("Login: pop-up closed")
            popups.removeAll { w in
                guard w.contentView === webView else { return false }
                w.close(); return true
            }
        }

        // MARK: Session cookie

        nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            Task { @MainActor in await self.check() }
        }

        private func check() async {
            guard !done else { return }
            let cookies = await model.web.cookies()
            guard !done else { return } // several cookie changes can be in flight at once
            let domain = model.config.cookies.domain
            let onDomain = cookies.filter { $0.domain == domain || $0.domain.hasSuffix("." + domain) }
            guard let session = onDomain.first(where: { $0.name == model.config.cookies.session })?.value, !session.isEmpty else { return }
            done = true
            let org = onDomain.first(where: { $0.name == model.config.cookies.org })?.value
            model.web.dataStore.httpCookieStore.remove(self)
            popups.forEach { $0.close() }; popups = []
            model.loginCompleted(sessionKey: session, orgId: org)
            WindowManager.shared.close("login")
        }
    }
}
