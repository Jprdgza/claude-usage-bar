import Foundation
import WebKit
import UsageCore

/// Owns the app's WebKit state: an ephemeral (non-persistent) data store, so the only place the
/// session survives a relaunch is the Keychain. Used for:
///  - the login window (user signs in on claude.ai; we read the `sessionKey` cookie), and
///  - a hidden fetch view, used only if plain URLSession requests get an HTML page back
///    (Cloudflare challenge). It runs `fetch()` on a claude.ai page, so Cloudflare and cookies
///    behave exactly as in a browser.
@MainActor final class WebSession: NSObject, WKNavigationDelegate {
    let dataStore = WKWebsiteDataStore.nonPersistent()
    private let config: AppConfig
    private let log: DebugLog
    private var fetchView: WKWebView?
    private var fetchReady = false
    private var loadWaiters: [CheckedContinuation<Void, Error>] = []

    init(config: AppConfig, log: DebugLog) {
        self.config = config; self.log = log
    }

    func setSessionCookie(_ sessionKey: String) async {
        let props: [HTTPCookiePropertyKey: Any] = [
            .name: config.cookies.session, .value: sessionKey, .domain: ".\(config.cookies.domain)", .path: "/",
            .secure: "TRUE", .expires: Date().addingTimeInterval(30 * 86400),
        ]
        if let c = HTTPCookie(properties: props) { await dataStore.httpCookieStore.setCookie(c) }
    }

    func cookies() async -> [HTTPCookie] { await dataStore.httpCookieStore.allCookies() }

    func clearAll() async {
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
        fetchView = nil; fetchReady = false
    }

    /// A bare WKWebView's user agent lacks Safari's `Version/x Safari/y` token, which Cloudflare's
    /// bot check and Google sign-in treat as an unsupported embedded browser. This *is* WebKit, so
    /// identify as the Safari installed on this Mac.
    static let applicationNameForUserAgent: String = {
        let plist = URL(fileURLWithPath: "/Applications/Safari.app/Contents/Info.plist")
        let version = (try? Data(contentsOf: plist))
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["CFBundleShortVersionString"] as? String
        return "Version/\(version ?? "18.0") Safari/605.1.15"
    }()

    func makeConfiguration() -> WKWebViewConfiguration {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = dataStore
        cfg.applicationNameForUserAgent = Self.applicationNameForUserAgent
        cfg.preferences.javaScriptCanOpenWindowsAutomatically = true
        return cfg
    }

    func makeLoginWebView() -> WKWebView {
        let v = WKWebView(frame: .init(x: 0, y: 0, width: 480, height: 700), configuration: makeConfiguration())
        if #available(macOS 13.3, *) { v.isInspectable = true } // right-click → Inspect Element, for debugging logins
        if let url = config.url(config.endpoints.login) { v.load(URLRequest(url: url)) }
        return v
    }

    // MARK: Fetch view

    private func ensureFetchView() async throws {
        if fetchReady, fetchView != nil { return }
        guard let origin = config.url(config.webTransportOriginPath) else { throw ClaudeAPIError.badURL("origin") }
        try NetworkPolicy(allowedHosts: config.allowedHosts).check(origin)
        let v = WKWebView(frame: .zero, configuration: makeConfiguration())
        v.navigationDelegate = self
        fetchView = v
        log.add("Web transport: loading \(origin.path) to get a claude.ai origin")
        v.load(URLRequest(url: origin))
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in loadWaiters.append(c) }
        fetchReady = true
    }

    func fetch(_ request: URLRequest) async throws -> HTTPResponse {
        guard let url = request.url else { throw ClaudeAPIError.badURL("nil") }
        try NetworkPolicy(allowedHosts: config.allowedHosts).check(url)
        try await ensureFetchView()
        // Same request inside a claude.ai page; the browser adds the cookies itself.
        var headers = request.allHTTPHeaderFields ?? [:]
        headers.removeValue(forKey: "Cookie")
        let js = """
        const init = { method, credentials: 'include', headers };
        if (body) init.body = body;
        const r = await fetch(url, init);
        const buf = new Uint8Array(await r.arrayBuffer());
        let s = '';
        for (let i = 0; i < buf.length; i += 32768) s += String.fromCharCode.apply(null, buf.subarray(i, i + 32768));
        return { status: r.status, type: r.headers.get('content-type') || '', body: btoa(s) };
        """
        guard let view = fetchView else { throw ClaudeAPIError.badURL("no fetch view") }
        let args: [String: Any] = ["url": url.absoluteString, "method": request.httpMethod ?? "GET", "headers": headers,
                                   "body": request.httpBody.map { String(decoding: $0, as: UTF8.self) } ?? ""]
        let result = try await view.callAsyncJavaScript(js, arguments: args, contentWorld: .defaultClient)
        guard let dict = result as? [String: Any] else { throw ClaudeAPIError.invalidJSON(snippet: "web fetch returned nothing") }
        let body = Data(base64Encoded: dict["body"] as? String ?? "") ?? Data()
        return HTTPResponse(status: (dict["status"] as? NSNumber)?.intValue ?? 0, body: body, contentType: dict["type"] as? String)
    }

    // MARK: WKNavigationDelegate (fetch view only)

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        // The hidden view may only ever be on an allowed host (Cloudflare's challenge runs on claude.ai).
        guard let url = navigationAction.request.url else { return .cancel }
        if url.scheme == "about" { return .allow }
        return (try? NetworkPolicy(allowedHosts: config.allowedHosts).check(url)) != nil ? .allow : .cancel
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let w = loadWaiters; loadWaiters = []
        w.forEach { $0.resume() }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failWaiters(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failWaiters(error) }

    private func failWaiters(_ error: Error) {
        fetchView = nil; fetchReady = false
        let w = loadWaiters; loadWaiters = []
        w.forEach { $0.resume(throwing: error) }
    }
}

/// Tries URLSession first; if claude.ai answers with HTML (a Cloudflare challenge), switches to the
/// WebKit fetch for the rest of the run.
final class HybridTransport: HTTPTransport, @unchecked Sendable {
    let primary = URLSessionTransport()
    let web: WebSession
    let onSwitch: @Sendable () -> Void
    private let lock = NSLock()
    private var _useWeb = false
    var useWeb: Bool { lock.withLock { _useWeb } }

    init(web: WebSession, onSwitch: @escaping @Sendable () -> Void) { self.web = web; self.onSwitch = onSwitch }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let isClaude = request.url?.host == "claude.ai"
        if isClaude, useWeb { return try await web.fetch(request) }
        let r = try await primary.send(request)
        if isClaude, r.looksLikeHTML {
            lock.withLock { _useWeb = true }
            onSwitch()
            return try await web.fetch(request)
        }
        return r
    }
}
