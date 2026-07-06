import AppKit
import Foundation
import OsaurusToolSecurity
import WebKit

/// Visible login window that lets the user sign in to a site using the same
/// `WKWebsiteDataStore` as the headless browser. Cookies / localStorage set
/// here are immediately visible to subsequent headless `browser_navigate`
/// calls because both webviews share the same data store identifier.
///
/// The window is intentionally minimal — title bar with the agent's profile id
/// (so the user knows which agent they're signing in for), a small toolbar with
/// back / forward / reload / current URL, and the WKWebView. No tabs, no
/// extensions, no autofill. For sites that need richer browser support, the
/// future `osaurus.chrome` plugin will provide it.
@MainActor
final class LoginWindow: NSObject, NSWindowDelegate, WKNavigationDelegate {
    private let profileId: UUID
    private let initialURL: URL?

    private var window: NSWindow!
    private var webView: WKWebView!
    private var urlField: NSTextField!
    private var backButton: NSButton!
    private var forwardButton: NSButton!
    private var reloadButton: NSButton!

    private var continuation: CheckedContinuation<LoginResult, Never>?
    private var didResume = false
    private var timeoutWorkItem: DispatchWorkItem?

    struct LoginResult {
        let closedAt: Date
        let finalURL: String?
        let timedOut: Bool
    }

    init(profileId: UUID, initialURL: URL?) {
        self.profileId = profileId
        self.initialURL = initialURL
        super.init()
    }

    /// Presents the window and returns when the user closes it (or the
    /// timeout fires). Always invoked on the main thread.
    func present(timeoutSeconds: TimeInterval) async -> LoginResult {
        return await withCheckedContinuation { (cont: CheckedContinuation<LoginResult, Never>) in
            self.continuation = cont
            buildWindowIfNeeded()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)

            let work = DispatchWorkItem { [weak self] in
                self?.finish(timedOut: true)
            }
            self.timeoutWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: work)
        }
    }

    private func buildWindowIfNeeded() {
        guard window == nil else { return }

        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore(forIdentifier: profileId)
        // Make the helper window look like a normal browser to the page so
        // login flows and risk-based 2FA behave consistently with what the
        // headless instance reports later.
        config.applicationNameForUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        let contentRect = NSRect(x: 0, y: 0, width: 1100, height: 760)
        let win = NSWindow(
            contentRect: contentRect,
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        win.title = "Sign in — Osaurus Browser (\(profileId.uuidString.prefix(8)))"
        win.center()
        win.isReleasedWhenClosed = false
        win.delegate = self

        let toolbarHeight: CGFloat = 36
        let container = NSView(frame: contentRect)
        container.translatesAutoresizingMaskIntoConstraints = false

        backButton = NSButton(title: "◀", target: self, action: #selector(goBack))
        backButton.bezelStyle = .rounded
        forwardButton = NSButton(title: "▶", target: self, action: #selector(goForward))
        forwardButton.bezelStyle = .rounded
        reloadButton = NSButton(title: "⟳", target: self, action: #selector(reload))
        reloadButton.bezelStyle = .rounded

        urlField = NSTextField(string: initialURL?.absoluteString ?? "")
        urlField.placeholderString = "Enter URL and press Return"
        urlField.target = self
        urlField.action = #selector(urlFieldEntered)
        urlField.usesSingleLineMode = true
        urlField.cell?.wraps = false
        urlField.cell?.isScrollable = true

        let toolbar = NSStackView(views: [backButton, forwardButton, reloadButton, urlField])
        toolbar.orientation = .horizontal
        toolbar.spacing = 6
        toolbar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        toolbar.translatesAutoresizingMaskIntoConstraints = false

        webView = WKWebView(
            frame: NSRect(
                x: 0, y: 0,
                width: contentRect.width,
                height: contentRect.height - toolbarHeight),
            configuration: config
        )
        webView.navigationDelegate = self
        webView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(toolbar)
        container.addSubview(webView)
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: container.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),

            webView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        win.contentView = container
        self.window = win

        if let url = initialURL {
            loadAfterPolicyValidation(url)
        } else {
            webView.loadHTMLString(
                """
                <html><body style="font-family:-apple-system;padding:40px;color:#333;">
                <h2>Sign in to a site</h2>
                <p>Type a URL in the address bar above and press Return. Sign in to as many sites
                as you like — cookies are saved per-agent and your headless browser sessions will
                inherit them automatically.</p>
                <p>Close this window when you're done.</p>
                </body></html>
                """,
                baseURL: nil
            )
        }

        updateNavButtons()
    }

    private func updateNavButtons() {
        backButton?.isEnabled = webView?.canGoBack ?? false
        forwardButton?.isEnabled = webView?.canGoForward ?? false
        if let urlString = webView?.url?.absoluteString {
            urlField?.stringValue = urlString
        }
    }

    @objc private func goBack() { webView?.goBack() }
    @objc private func goForward() { webView?.goForward() }
    @objc private func reload() { webView?.reload() }

    @objc private func urlFieldEntered() {
        let raw = urlField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return }
        let normalized: String
        if raw.contains("://") {
            normalized = raw
        } else if raw.contains(".") && !raw.contains(" ") {
            normalized = "https://" + raw
        } else {
            normalized =
                "https://www.google.com/search?q="
                + (raw.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? raw)
        }
        guard let url = URL(string: normalized) else { return }
        loadAfterPolicyValidation(url)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let targetURL = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        switch validateBrowserNavigationURL(targetURL, resolveHostnames: false) {
        case .success:
            decisionHandler(.allow)
        case .failure(let failure):
            decisionHandler(.cancel)
            DispatchQueue.main.async { [weak self] in
                self?.renderBlockedNavigation(failure.message)
            }
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        updateNavButtons()
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        updateNavButtons()
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        updateNavButtons()
    }

    // MARK: - NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        finish(timedOut: false)
    }

    private func finish(timedOut: Bool) {
        guard !didResume else { return }
        didResume = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil

        let result = LoginResult(
            closedAt: Date(),
            finalURL: webView?.url?.absoluteString,
            timedOut: timedOut
        )
        if timedOut {
            window?.orderOut(nil)
            window?.close()
        }
        let cont = continuation
        continuation = nil
        cont?.resume(returning: result)
    }

    private func renderBlockedNavigation(_ message: String) {
        webView.loadHTMLString(
            """
            <html><body style="font-family:-apple-system;padding:40px;color:#333;">
            <h2>Navigation blocked</h2>
            <p>\(Self.escapeHTML(message))</p>
            </body></html>
            """,
            baseURL: nil
        )
    }

    private func loadAfterPolicyValidation(_ url: URL) {
        let rawURL = url.absoluteString
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let validation = validateBrowserNavigationURL(rawURL, resolveHostnames: true)
            DispatchQueue.main.async {
                guard let self else { return }
                switch validation {
                case .success(let decision):
                    self.webView.load(URLRequest(url: decision.url))
                case .failure(let failure):
                    self.renderBlockedNavigation(failure.message)
                }
            }
        }
    }

    private static func escapeHTML(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
