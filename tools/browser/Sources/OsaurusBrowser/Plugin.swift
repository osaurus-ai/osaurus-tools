import AppKit
import Foundation
import WebKit

// MARK: - Detail Level

enum DetailLevel: String {
    case none = "none"
    case compact = "compact"
    case standard = "standard"
    case full = "full"
}

// MARK: - Headless Browser Manager

/// Manages a headless WKWebView instance for browser automation
class HeadlessBrowser: NSObject, WKNavigationDelegate, WKUIDelegate {
    private var webView: WKWebView!
    private var navigationSemaphore = DispatchSemaphore(value: 0)
    private var navigationError: Error?
    private var isLoaded = false

    // Element ref counter - increments with each snapshot
    private var refCounter = 0

    // State tracking for reliability
    private var hasNavigated = false
    private var lastNavigationURL: String?
    private var snapshotGeneration = 0

    // Dialog handling — pre-registered policy applied to next dialog of each kind.
    // Set via `setDialogPolicy(...)`; reset to `(accept:true, promptText:nil)` after use.
    struct DialogPolicy {
        var accept: Bool
        var promptText: String?
    }
    private var pendingDialogPolicy = DialogPolicy(accept: true, promptText: nil)
    private var lastDialog: [String: Any]?

    // Multi-agent coordination: a soft lock that other agents are expected
    // to honor cooperatively.
    struct LockState {
        var locked: Bool
        var owner: String?
        var acquiredAt: Date?
    }
    private var lockState = LockState(locked: false, owner: nil, acquiredAt: nil)
    private let lockQueue = DispatchQueue(label: "osaurus.browser.lock")

    override init() {
        super.init()

        // Ensure we're on the main thread for WebKit operations
        if Thread.isMainThread {
            setupWebView()
        } else {
            DispatchQueue.main.sync {
                self.setupWebView()
            }
        }
    }

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false

        // Set up user agent to appear as a real browser
        config.applicationNameForUserAgent =
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15"

        // Inject capture scripts at document start so we record console output
        // and network activity for `browser_console_messages` and
        // `browser_network_requests`. Buffers live on `window.__osaurus_*`
        // and are read back via plain `evaluateJavaScript`.
        let captureScript = WKUserScript(
            source: HeadlessBrowser.captureScriptSource,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        config.userContentController.addUserScript(captureScript)

        // Create a headless webview (no window needed)
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self

        // Enable JavaScript
        if #available(macOS 14.0, *) {
            webView.configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        }
    }

    /// JS injected at document start in every page. Wraps console.{log,info,warn,error,debug}
    /// and instruments fetch + XMLHttpRequest. The agent reads the buffers via JS.
    static let captureScriptSource: String = """
        (function() {
          if (window.__osaurus_capture_installed) return;
          window.__osaurus_capture_installed = true;
          window.__osaurus_console = [];
          window.__osaurus_network = [];
          var origConsole = {};
          ['log', 'info', 'warn', 'error', 'debug'].forEach(function(level) {
            origConsole[level] = (console[level] || console.log).bind(console);
            console[level] = function() {
              var args = Array.prototype.slice.call(arguments).map(function(a) {
                try { return typeof a === 'string' ? a : JSON.stringify(a); }
                catch (e) { return String(a); }
              });
              window.__osaurus_console.push({
                level: level,
                message: args.join(' '),
                timestamp: Date.now(),
                location: (new Error()).stack ? (new Error()).stack.split('\\n')[2] || '' : ''
              });
              if (window.__osaurus_console.length > 500) window.__osaurus_console.shift();
              try { origConsole[level].apply(null, arguments); } catch (e) {}
            };
          });
          var origFetch = window.fetch;
          if (origFetch) {
            window.fetch = function(input, init) {
              var url = typeof input === 'string' ? input : (input && input.url) || '';
              var method = (init && init.method) || (typeof input === 'object' && input.method) || 'GET';
              var entry = { url: url, method: method.toUpperCase(), kind: 'fetch', start: Date.now() };
              window.__osaurus_network.push(entry);
              if (window.__osaurus_network.length > 500) window.__osaurus_network.shift();
              return origFetch.apply(this, arguments).then(function(resp) {
                entry.status = resp.status;
                entry.ok = resp.ok;
                entry.duration_ms = Date.now() - entry.start;
                return resp;
              }).catch(function(err) {
                entry.status = 0;
                entry.error = String(err);
                entry.duration_ms = Date.now() - entry.start;
                throw err;
              });
            };
          }
          var XHR = window.XMLHttpRequest;
          if (XHR) {
            var origOpen = XHR.prototype.open;
            var origSend = XHR.prototype.send;
            XHR.prototype.open = function(method, url) {
              this.__osaurus_entry = { url: url, method: method.toUpperCase(), kind: 'xhr', start: Date.now() };
              window.__osaurus_network.push(this.__osaurus_entry);
              if (window.__osaurus_network.length > 500) window.__osaurus_network.shift();
              return origOpen.apply(this, arguments);
            };
            XHR.prototype.send = function() {
              var self = this;
              this.addEventListener('loadend', function() {
                if (self.__osaurus_entry) {
                  self.__osaurus_entry.status = self.status;
                  self.__osaurus_entry.ok = self.status >= 200 && self.status < 400;
                  self.__osaurus_entry.duration_ms = Date.now() - self.__osaurus_entry.start;
                }
              });
              return origSend.apply(this, arguments);
            };
          }
        })();
        """

    // MARK: - Navigation

    enum WaitUntil: String {
        case load = "load"
        case networkidle = "networkidle"
        case domstable = "domstable"
    }

    func navigate(
        to urlString: String, timeout: TimeInterval = 30, waitUntil: WaitUntil = .load
    ) -> (success: Bool, error: String?) {
        guard let url = URL(string: urlString) else {
            return (false, "Invalid URL: \(urlString)")
        }

        navigationError = nil
        isLoaded = false
        navigationSemaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            let request = URLRequest(url: url, timeoutInterval: timeout)
            self.webView.load(request)
        }

        let result = navigationSemaphore.wait(timeout: .now() + timeout)

        if result == .timedOut {
            return (false, "Navigation timed out after \(timeout) seconds")
        }

        if let error = navigationError {
            return (false, error.localizedDescription)
        }

        // Additional wait strategies
        switch waitUntil {
        case .load:
            // Already done - didFinish was called
            break
        case .networkidle:
            // Wait for network to be idle (no requests for 500ms)
            waitForNetworkIdle(timeout: timeout)
        case .domstable:
            // Wait for DOM to stabilize
            waitForDOMStable(timeout: timeout)
        }

        // Mark navigation as successful
        hasNavigated = true
        lastNavigationURL = urlString

        return (true, nil)
    }

    func waitForNetworkIdle(timeout: TimeInterval) {
        // Simple implementation: wait a bit for dynamic content
        Thread.sleep(forTimeInterval: 0.5)

        // Check if there are pending XHR/fetch requests
        let script = """
            (function() {
                return window.performance.getEntriesByType('resource')
                    .filter(r => r.initiatorType === 'fetch' || r.initiatorType === 'xmlhttprequest')
                    .filter(r => r.responseEnd === 0).length;
            })()
            """

        let startTime = Date()
        while Date().timeIntervalSince(startTime) < timeout {
            let result = evaluateJavaScript(script)
            if let pending = result.result as? Int, pending == 0 {
                Thread.sleep(forTimeInterval: 0.3)  // Extra buffer
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    func waitForDOMStable(timeout: TimeInterval) {
        // Poll-based approach: Check DOM stability by comparing snapshots
        // First, wait for document.readyState to be complete
        let readyScript = """
            (function() {
                try {
                    return document.readyState === 'complete';
                } catch (e) {
                    return false;
                }
            })()
            """

        let startTime = Date()

        // Wait for document ready
        while Date().timeIntervalSince(startTime) < timeout {
            let result = evaluateJavaScript(readyScript)
            if result.result as? Bool == true {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        // Now check for DOM stability by comparing element counts
        let countScript = """
            (function() {
                try {
                    if (!document.body) return -1;
                    return document.body.getElementsByTagName('*').length;
                } catch (e) {
                    return -1;
                }
            })()
            """

        var lastCount = -1
        var stableIterations = 0
        let requiredStableIterations = 3  // DOM must be stable for 3 consecutive checks

        while Date().timeIntervalSince(startTime) < timeout {
            let result = evaluateJavaScript(countScript)
            if let count = result.result as? Int {
                if count == lastCount && count >= 0 {
                    stableIterations += 1
                    if stableIterations >= requiredStableIterations {
                        return  // DOM is stable
                    }
                } else {
                    stableIterations = 0
                    lastCount = count
                }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    // MARK: - JavaScript Execution

    func evaluateJavaScript(_ script: String, timeout: TimeInterval = 10) -> (result: Any?, error: String?) {
        var jsResult: Any?
        var jsError: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            self.webView.evaluateJavaScript(script) { result, error in
                jsResult = result
                if let error = error {
                    jsError = error.localizedDescription
                }
                semaphore.signal()
            }
        }

        let waitResult = semaphore.wait(timeout: .now() + timeout)

        if waitResult == .timedOut {
            return (nil, "JavaScript execution timed out")
        }

        return (jsResult, jsError)
    }

    // MARK: - Snapshot (Core Feature)

    struct SnapshotOptions {
        var filter: String = "all"  // all, inputs, buttons, links, forms
        var maxElements: Int = 100
        var visibleOnly: Bool = true
    }

    func takeSnapshot(options: SnapshotOptions = SnapshotOptions(), detail: DetailLevel = .standard) -> String {
        // Validate state before attempting snapshot
        guard hasNavigated else {
            return "Error: No page loaded. Call browser_navigate first to load a page."
        }

        // Reset ref counter and increment generation for each snapshot
        refCounter = 0
        snapshotGeneration += 1
        let currentGeneration = snapshotGeneration

        let filterCondition: String
        switch options.filter {
        case "inputs":
            filterCondition = "el.matches('input, textarea, select, [contenteditable=\"true\"]')"
        case "buttons":
            filterCondition = "el.matches('button, input[type=\"button\"], input[type=\"submit\"], [role=\"button\"]')"
        case "links":
            filterCondition = "el.matches('a[href]')"
        case "forms":
            filterCondition = "el.matches('form, input, textarea, select, button')"
        default:
            filterCondition = "true"
        }

        let visibilityCheck =
            options.visibleOnly
            ? """
                try {
                    const rect = el.getBoundingClientRect();
                    const style = window.getComputedStyle(el);
                    if (style.display === 'none' || style.visibility === 'hidden' || style.opacity === '0') return false;
                    if (rect.width === 0 && rect.height === 0) return false;
                    return true;
                } catch (e) {
                    return false;
                }
            """ : "return true;"

        let script = """
            (function() {
                try {
                    // Validate page state
                    if (!document || !document.body) {
                        return {error: 'Page not ready - document.body is null. Wait for page to load or call browser_navigate again.'};
                    }
                    
                    if (document.readyState === 'loading') {
                        return {error: 'Page still loading. Wait a moment and try again, or use browser_wait_for.'};
                    }
                    
                    const maxElements = \(options.maxElements);
                    const results = [];
                    let refId = 0;
                    
                    // Store refs in a global map for later retrieval with generation tracking
                    window.__osaurus_refs = new Map();
                    window.__osaurus_snapshot_gen = \(currentGeneration);
                    
                    function isVisible(el) {
                        \(visibilityCheck)
                    }
                    
                    function isInteractive(el) {
                        try {
                            const tag = el.tagName ? el.tagName.toLowerCase() : '';
                            if (!tag) return false;
                            
                            const role = el.getAttribute ? el.getAttribute('role') : null;
                            const tabIndex = el.getAttribute ? el.getAttribute('tabindex') : null;
                            
                            // Standard interactive elements
                            if (['a', 'button', 'input', 'textarea', 'select', 'details', 'summary'].includes(tag)) return true;
                            
                            // ARIA roles
                            if (['button', 'link', 'menuitem', 'option', 'radio', 'checkbox', 'tab', 'textbox', 'combobox', 'listbox', 'menu', 'menubar', 'slider', 'spinbutton', 'switch'].includes(role)) return true;
                            
                            // Clickable elements
                            if (el.onclick || (el.getAttribute && el.getAttribute('onclick'))) return true;
                            if (tabIndex && tabIndex !== '-1') return true;
                            
                            // Contenteditable
                            if (el.getAttribute && el.getAttribute('contenteditable') === 'true') return true;
                            
                            return false;
                        } catch (e) {
                            return false;
                        }
                    }
                    
                    function getElementType(el) {
                        try {
                            const tag = el.tagName ? el.tagName.toLowerCase() : 'unknown';
                            const type = el.getAttribute ? el.getAttribute('type') : null;
                            const role = el.getAttribute ? el.getAttribute('role') : null;
                            
                            if (tag === 'a') return 'link';
                            if (tag === 'button' || role === 'button') return 'button';
                            if (tag === 'input') {
                                if (type === 'checkbox') return 'checkbox';
                                if (type === 'radio') return 'radio';
                                if (type === 'submit') return 'submit';
                                if (type === 'file') return 'file';
                                return 'input';
                            }
                            if (tag === 'textarea') return 'textarea';
                            if (tag === 'select') return 'select';
                            if (tag === 'img') return 'img';
                            if (role) return role;
                            return tag;
                        } catch (e) {
                            return 'unknown';
                        }
                    }
                    
                    function truncate(str, len) {
                        if (!str) return '';
                        try {
                            str = String(str).trim().replace(/\\s+/g, ' ');
                            return str.length > len ? str.substring(0, len) + '...' : str;
                        } catch (e) {
                            return '';
                        }
                    }
                    
                    function getElementText(el) {
                        try {
                            const tag = el.tagName ? el.tagName.toLowerCase() : '';
                            
                            // For inputs, use placeholder or aria-label
                            if (tag === 'input' || tag === 'textarea') {
                                return el.placeholder || (el.getAttribute && el.getAttribute('aria-label')) || el.name || '';
                            }
                            
                            // For images, use alt text
                            if (tag === 'img') {
                                return el.alt || el.title || '';
                            }
                            
                            // For other elements, get visible text
                            const text = el.innerText || el.textContent || '';
                            return text;
                        } catch (e) {
                            return '';
                        }
                    }
                    
                    function getElementInfo(el) {
                        try {
                            const ref = 'E' + (++refId);
                            window.__osaurus_refs.set(ref, el);
                            
                            const type = getElementType(el);
                            const text = truncate(getElementText(el), 50);
                            
                            let info = { ref, type, text };
                            
                            // Add relevant attributes with safety checks
                            try {
                                if (el.name) info.name = el.name;
                                if (el.id) info.id = truncate(el.id, 30);
                                if (el.value && el.tagName && el.tagName.toLowerCase() !== 'textarea') info.value = truncate(el.value, 30);
                                if (el.placeholder) info.placeholder = truncate(el.placeholder, 30);
                                if (el.href) info.href = truncate(el.href, 50);
                                if (el.checked) info.checked = true;
                                if (el.disabled) info.disabled = true;
                                if (el.required) info.required = true;
                                if (el.getAttribute && el.getAttribute('aria-label')) info.ariaLabel = truncate(el.getAttribute('aria-label'), 30);
                            } catch (attrError) {
                                // Continue with partial info
                            }
                            
                            return info;
                        } catch (e) {
                            return null;
                        }
                    }
                    
                    // Walk the DOM with error handling
                    let walker;
                    try {
                        walker = document.createTreeWalker(
                            document.body,
                            NodeFilter.SHOW_ELEMENT,
                            {
                                acceptNode: function(node) {
                                    try {
                                        if (!node || !node.tagName) return NodeFilter.FILTER_SKIP;
                                        if (!isInteractive(node)) return NodeFilter.FILTER_SKIP;
                                        if (!isVisible(node)) return NodeFilter.FILTER_SKIP;
                                        if (!(\(filterCondition))) return NodeFilter.FILTER_SKIP;
                                        return NodeFilter.FILTER_ACCEPT;
                                    } catch (e) {
                                        return NodeFilter.FILTER_SKIP;
                                    }
                                }
                            }
                        );
                    } catch (walkerError) {
                        return {error: 'Failed to create DOM walker: ' + walkerError.message + '. The page may be in an invalid state.'};
                    }
                    
                    let el;
                    let iterations = 0;
                    const maxIterations = 10000; // Prevent infinite loops
                    
                    while (iterations < maxIterations) {
                        iterations++;
                        try {
                            el = walker.nextNode();
                            if (!el) break;
                            if (results.length >= maxElements) break;
                            
                            const info = getElementInfo(el);
                            if (info) {
                                results.push(info);
                            }
                        } catch (walkError) {
                            // Skip problematic elements and continue
                            continue;
                        }
                    }
                    
                    let hasMore = false;
                    try {
                        hasMore = walker.nextNode() !== null;
                    } catch (e) {
                        // Ignore - just report what we have
                    }
                    
                    return {
                        url: window.location.href || '',
                        title: document.title || '',
                        elementCount: results.length,
                        hasMore: hasMore,
                        elements: results,
                        generation: \(currentGeneration),
                        bodyText: (function() { try { return (document.body.innerText || '').substring(0, 500); } catch(e) { return ''; } })()
                    };
                } catch (e) {
                    return {error: 'Snapshot failed: ' + (e.message || String(e)) + '. Try calling browser_navigate to reload the page.'};
                }
            })()
            """

        let result = evaluateJavaScript(script, timeout: 15)

        if let error = result.error {
            return "Error: \(error)"
        }

        // Check for error in the result object
        if let dict = result.result as? [String: Any], let errorMsg = dict["error"] as? String {
            return "Error: \(errorMsg)"
        }

        guard let data = result.result as? [String: Any] else {
            return "Error: Failed to parse snapshot"
        }

        return formatSnapshotOutput(data, detail: detail)
    }

    // MARK: - Element Interactions (Ref-based)

    func clickElement(ref: String?, selector: String?) -> (success: Bool, error: String?) {
        // Validate state
        guard hasNavigated else {
            return (false, "No page loaded. Call browser_navigate first.")
        }

        let script: String
        let currentGen = snapshotGeneration

        if let ref = ref {
            script = """
                (function() {
                    try {
                        if (!document || !document.body) {
                            return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                        }
                        if (!window.__osaurus_refs) {
                            return {success: false, error: 'No snapshot taken. Call browser_snapshot first to get element refs.'};
                        }
                        if (window.__osaurus_snapshot_gen !== \(currentGen)) {
                            return {success: false, error: 'Snapshot is stale (page may have changed). Call browser_snapshot again to get fresh refs.'};
                        }
                        const el = window.__osaurus_refs.get('\(ref)');
                        if (!el) {
                            return {success: false, error: 'Element ref \\'\(ref)\\' not found. Call browser_snapshot to get current element refs.'};
                        }
                        if (!document.body.contains(el)) {
                            return {success: false, error: 'Element no longer in DOM (page changed). Call browser_snapshot to refresh.'};
                        }
                        el.scrollIntoView({block: 'center', behavior: 'instant'});
                        el.click();
                        return {success: true};
                    } catch (e) {
                        return {success: false, error: 'Click failed: ' + (e.message || String(e))};
                    }
                })()
                """
        } else if let selector = selector {
            script = """
                (function() {
                    try {
                        if (!document || !document.body) {
                            return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                        }
                        const el = document.querySelector('\(escapeSelector(selector))');
                        if (!el) {
                            return {success: false, error: 'Element not found with selector: \(escapeSelector(selector))'};
                        }
                        el.scrollIntoView({block: 'center', behavior: 'instant'});
                        el.click();
                        return {success: true};
                    } catch (e) {
                        return {success: false, error: 'Click failed: ' + (e.message || String(e))};
                    }
                })()
                """
        } else {
            return (false, "Either ref or selector must be provided")
        }

        let result = evaluateJavaScript(script)

        if let error = result.error {
            return (false, "JavaScript error: \(error). Try calling browser_navigate to reload the page.")
        }

        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }

        return (false, "Unknown error during click. Try calling browser_snapshot to refresh element refs.")
    }

    func typeText(
        ref: String?, selector: String?, text: String, clear: Bool = true, submit: Bool = false
    ) -> (success: Bool, error: String?) {
        // Validate state
        guard hasNavigated else {
            return (false, "No page loaded. Call browser_navigate first.")
        }

        let escapedText = text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n")

        let currentGen = snapshotGeneration
        let getElementScript: String
        let refValidation: String

        if let ref = ref {
            getElementScript = "window.__osaurus_refs?.get('\(ref)')"
            refValidation = """
                if (!window.__osaurus_refs) {
                    return {success: false, error: 'No snapshot taken. Call browser_snapshot first.'};
                }
                if (window.__osaurus_snapshot_gen !== \(currentGen)) {
                    return {success: false, error: 'Snapshot is stale. Call browser_snapshot again.'};
                }
                """
        } else if let selector = selector {
            getElementScript = "document.querySelector('\(escapeSelector(selector))')"
            refValidation = ""
        } else {
            return (false, "Either ref or selector must be provided")
        }

        let script = """
            (function() {
                try {
                    if (!document || !document.body) {
                        return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                    }
                    \(refValidation)
                    const el = \(getElementScript);
                    if (!el) {
                        return {success: false, error: 'Element not found. Call browser_snapshot to get current refs.'};
                    }
                    if (!document.body.contains(el)) {
                        return {success: false, error: 'Element no longer in DOM. Call browser_snapshot to refresh.'};
                    }
                    
                    el.scrollIntoView({block: 'center', behavior: 'instant'});
                    el.focus();
                    
                    // Handle contenteditable elements
                    if (el.getAttribute('contenteditable') === 'true') {
                        if (\(clear)) el.innerHTML = '';
                        el.innerHTML += '\(escapedText)';
                    } else {
                        if (\(clear)) el.value = '';
                        el.value += '\(escapedText)';
                    }
                    
                    el.dispatchEvent(new Event('input', {bubbles: true}));
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    
                    if (\(submit)) {
                        const form = el.closest('form');
                        if (form) {
                            form.submit();
                        } else {
                            el.dispatchEvent(new KeyboardEvent('keydown', {key: 'Enter', code: 'Enter', bubbles: true}));
                            el.dispatchEvent(new KeyboardEvent('keypress', {key: 'Enter', code: 'Enter', bubbles: true}));
                            el.dispatchEvent(new KeyboardEvent('keyup', {key: 'Enter', code: 'Enter', bubbles: true}));
                        }
                    }
                    
                    return {success: true};
                } catch (e) {
                    return {success: false, error: 'Type failed: ' + (e.message || String(e))};
                }
            })()
            """

        let result = evaluateJavaScript(script)

        if let error = result.error {
            return (false, "JavaScript error: \(error). Try calling browser_navigate to reload.")
        }

        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }

        return (false, "Unknown error during type. Try calling browser_snapshot to refresh.")
    }

    func selectOption(ref: String?, selector: String?, values: [String]) -> (success: Bool, error: String?) {
        // Validate state
        guard hasNavigated else {
            return (false, "No page loaded. Call browser_navigate first.")
        }

        let valuesJSON = values.map { "\"\($0.replacingOccurrences(of: "\"", with: "\\\""))\"" }.joined(separator: ",")
        let currentGen = snapshotGeneration

        let getElementScript: String
        let refValidation: String

        if let ref = ref {
            getElementScript = "window.__osaurus_refs?.get('\(ref)')"
            refValidation = """
                if (!window.__osaurus_refs) {
                    return {success: false, error: 'No snapshot taken. Call browser_snapshot first.'};
                }
                if (window.__osaurus_snapshot_gen !== \(currentGen)) {
                    return {success: false, error: 'Snapshot is stale. Call browser_snapshot again.'};
                }
                """
        } else if let selector = selector {
            getElementScript = "document.querySelector('\(escapeSelector(selector))')"
            refValidation = ""
        } else {
            return (false, "Either ref or selector must be provided")
        }

        let script = """
            (function() {
                try {
                    if (!document || !document.body) {
                        return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                    }
                    \(refValidation)
                    const el = \(getElementScript);
                    if (!el) {
                        return {success: false, error: 'Element not found. Call browser_snapshot to get current refs.'};
                    }
                    if (!el.tagName || el.tagName.toLowerCase() !== 'select') {
                        return {success: false, error: 'Element is not a <select>. Use browser_snapshot to find the correct element.'};
                    }
                    
                    const values = [\(valuesJSON)];
                    let matched = false;
                    for (const opt of el.options) {
                        const shouldSelect = values.includes(opt.value) || values.includes(opt.text);
                        opt.selected = shouldSelect;
                        if (shouldSelect) matched = true;
                    }
                    
                    if (!matched && values.length > 0) {
                        return {success: false, error: 'No matching options found for values: ' + values.join(', ')};
                    }
                    
                    el.dispatchEvent(new Event('change', {bubbles: true}));
                    return {success: true};
                } catch (e) {
                    return {success: false, error: 'Select failed: ' + (e.message || String(e))};
                }
            })()
            """

        let result = evaluateJavaScript(script)

        if let error = result.error {
            return (false, "JavaScript error: \(error). Try calling browser_navigate to reload.")
        }

        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }

        return (false, "Unknown error during select. Try calling browser_snapshot to refresh.")
    }

    func hoverElement(ref: String?, selector: String?) -> (success: Bool, error: String?) {
        // Validate state
        guard hasNavigated else {
            return (false, "No page loaded. Call browser_navigate first.")
        }

        let currentGen = snapshotGeneration
        let getElementScript: String
        let refValidation: String

        if let ref = ref {
            getElementScript = "window.__osaurus_refs?.get('\(ref)')"
            refValidation = """
                if (!window.__osaurus_refs) {
                    return {success: false, error: 'No snapshot taken. Call browser_snapshot first.'};
                }
                if (window.__osaurus_snapshot_gen !== \(currentGen)) {
                    return {success: false, error: 'Snapshot is stale. Call browser_snapshot again.'};
                }
                """
        } else if let selector = selector {
            getElementScript = "document.querySelector('\(escapeSelector(selector))')"
            refValidation = ""
        } else {
            return (false, "Either ref or selector must be provided")
        }

        let script = """
            (function() {
                try {
                    if (!document || !document.body) {
                        return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                    }
                    \(refValidation)
                    const el = \(getElementScript);
                    if (!el) {
                        return {success: false, error: 'Element not found. Call browser_snapshot to get current refs.'};
                    }
                    if (!document.body.contains(el)) {
                        return {success: false, error: 'Element no longer in DOM. Call browser_snapshot to refresh.'};
                    }
                    
                    el.scrollIntoView({block: 'center', behavior: 'instant'});
                    
                    const rect = el.getBoundingClientRect();
                    const x = rect.left + rect.width / 2;
                    const y = rect.top + rect.height / 2;
                    
                    el.dispatchEvent(new MouseEvent('mouseenter', {bubbles: true, clientX: x, clientY: y}));
                    el.dispatchEvent(new MouseEvent('mouseover', {bubbles: true, clientX: x, clientY: y}));
                    el.dispatchEvent(new MouseEvent('mousemove', {bubbles: true, clientX: x, clientY: y}));
                    
                    return {success: true};
                } catch (e) {
                    return {success: false, error: 'Hover failed: ' + (e.message || String(e))};
                }
            })()
            """

        let result = evaluateJavaScript(script)

        if let error = result.error {
            return (false, "JavaScript error: \(error). Try calling browser_navigate to reload.")
        }

        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }

        return (false, "Unknown error during hover. Try calling browser_snapshot to refresh.")
    }

    // MARK: - Scroll

    func scroll(
        direction: String? = nil, ref: String? = nil, x: Int? = nil, y: Int? = nil
    ) -> (success: Bool, error: String?) {
        // Validate state
        guard hasNavigated else {
            return (false, "No page loaded. Call browser_navigate first.")
        }

        let script: String
        let currentGen = snapshotGeneration

        if let ref = ref {
            // Scroll to element
            script = """
                (function() {
                    try {
                        if (!document || !document.body) {
                            return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                        }
                        if (!window.__osaurus_refs) {
                            return {success: false, error: 'No snapshot taken. Call browser_snapshot first.'};
                        }
                        if (window.__osaurus_snapshot_gen !== \(currentGen)) {
                            return {success: false, error: 'Snapshot is stale. Call browser_snapshot again.'};
                        }
                        const el = window.__osaurus_refs.get('\(ref)');
                        if (!el) {
                            return {success: false, error: 'Element ref not found. Call browser_snapshot to get current refs.'};
                        }
                        if (!document.body.contains(el)) {
                            return {success: false, error: 'Element no longer in DOM. Call browser_snapshot to refresh.'};
                        }
                        el.scrollIntoView({behavior: 'smooth', block: 'center'});
                        return {success: true};
                    } catch (e) {
                        return {success: false, error: 'Scroll failed: ' + (e.message || String(e))};
                    }
                })()
                """
        } else if let direction = direction {
            // Scroll by direction
            let scrollAmount: (x: Int, y: Int)
            switch direction.lowercased() {
            case "up": scrollAmount = (0, -400)
            case "down": scrollAmount = (0, 400)
            case "left": scrollAmount = (-400, 0)
            case "right": scrollAmount = (400, 0)
            default: scrollAmount = (0, 400)
            }
            script = """
                (function() {
                    try {
                        if (!document || !document.body) {
                            return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                        }
                        window.scrollBy({left: \(scrollAmount.x), top: \(scrollAmount.y), behavior: 'smooth'});
                        return {success: true};
                    } catch (e) {
                        return {success: false, error: 'Scroll failed: ' + (e.message || String(e))};
                    }
                })()
                """
        } else if let x = x, let y = y {
            // Scroll to position
            script = """
                (function() {
                    try {
                        if (!document || !document.body) {
                            return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                        }
                        window.scrollTo({left: \(x), top: \(y), behavior: 'smooth'});
                        return {success: true};
                    } catch (e) {
                        return {success: false, error: 'Scroll failed: ' + (e.message || String(e))};
                    }
                })()
                """
        } else {
            return (false, "Provide direction, ref, or x/y coordinates")
        }

        let result = evaluateJavaScript(script)

        if let error = result.error {
            return (false, "JavaScript error: \(error). Try calling browser_navigate to reload.")
        }

        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                // Wait for smooth scroll to complete
                Thread.sleep(forTimeInterval: 0.3)
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }

        // Wait for smooth scroll to complete
        Thread.sleep(forTimeInterval: 0.3)
        return (true, nil)
    }

    // MARK: - Press Key

    func pressKey(key: String, modifiers: [String] = []) -> (success: Bool, error: String?) {
        // Validate state
        guard hasNavigated else {
            return (false, "No page loaded. Call browser_navigate first.")
        }

        let keyMap: [String: (key: String, code: String, keyCode: Int)] = [
            "enter": ("Enter", "Enter", 13),
            "escape": ("Escape", "Escape", 27),
            "tab": ("Tab", "Tab", 9),
            "backspace": ("Backspace", "Backspace", 8),
            "delete": ("Delete", "Delete", 46),
            "arrowup": ("ArrowUp", "ArrowUp", 38),
            "arrowdown": ("ArrowDown", "ArrowDown", 40),
            "arrowleft": ("ArrowLeft", "ArrowLeft", 37),
            "arrowright": ("ArrowRight", "ArrowRight", 39),
            "home": ("Home", "Home", 36),
            "end": ("End", "End", 35),
            "pageup": ("PageUp", "PageUp", 33),
            "pagedown": ("PageDown", "PageDown", 34),
            "space": (" ", "Space", 32),
        ]

        let keyInfo =
            keyMap[key.lowercased()] ?? (key, "Key\(key.uppercased())", Int(key.unicodeScalars.first?.value ?? 0))

        let ctrlKey = modifiers.contains("ctrl") || modifiers.contains("control")
        let shiftKey = modifiers.contains("shift")
        let altKey = modifiers.contains("alt") || modifiers.contains("option")
        let metaKey = modifiers.contains("meta") || modifiers.contains("cmd") || modifiers.contains("command")

        let script = """
            (function() {
                try {
                    if (!document || !document.body) {
                        return {success: false, error: 'Page not ready. Call browser_navigate to reload.'};
                    }
                    const target = document.activeElement || document.body;
                    const opts = {
                        key: '\(keyInfo.key)',
                        code: '\(keyInfo.code)',
                        keyCode: \(keyInfo.keyCode),
                        which: \(keyInfo.keyCode),
                        bubbles: true,
                        cancelable: true,
                        ctrlKey: \(ctrlKey),
                        shiftKey: \(shiftKey),
                        altKey: \(altKey),
                        metaKey: \(metaKey)
                    };
                    target.dispatchEvent(new KeyboardEvent('keydown', opts));
                    target.dispatchEvent(new KeyboardEvent('keypress', opts));
                    target.dispatchEvent(new KeyboardEvent('keyup', opts));
                    return {success: true};
                } catch (e) {
                    return {success: false, error: 'Key press failed: ' + (e.message || String(e))};
                }
            })()
            """

        let result = evaluateJavaScript(script)

        if let error = result.error {
            return (false, "JavaScript error: \(error). Try calling browser_navigate to reload.")
        }

        if let dict = result.result as? [String: Any] {
            if let success = dict["success"] as? Bool, success {
                return (true, nil)
            }
            if let error = dict["error"] as? String {
                return (false, error)
            }
        }

        return (true, nil)
    }

    // MARK: - Wait For

    func waitFor(
        text: String? = nil, textGone: String? = nil, time: TimeInterval? = nil, timeout: TimeInterval = 10
    ) -> (success: Bool, error: String?) {
        // Time-based wait doesn't require page state
        if let time = time {
            Thread.sleep(forTimeInterval: time)
            return (true, nil)
        }

        // Text-based waits require a page to be loaded
        guard hasNavigated else {
            return (false, "No page loaded. Call browser_navigate first.")
        }

        let startTime = Date()

        if let text = text {
            let escapedText = text.replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\\", with: "\\\\")
            while Date().timeIntervalSince(startTime) < timeout {
                let script = """
                    (function() {
                        try {
                            if (!document || !document.body) return false;
                            return document.body.innerText.includes('\(escapedText)');
                        } catch (e) {
                            return false;
                        }
                    })()
                    """
                let result = evaluateJavaScript(script)
                if let found = result.result as? Bool, found {
                    return (true, nil)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return (
                false, "Timeout after \(timeout)s waiting for text: '\(text)'. The text may not exist on this page."
            )
        }

        if let textGone = textGone {
            let escapedText = textGone.replacingOccurrences(of: "'", with: "\\'")
                .replacingOccurrences(of: "\\", with: "\\\\")
            while Date().timeIntervalSince(startTime) < timeout {
                let script = """
                    (function() {
                        try {
                            if (!document || !document.body) return true;
                            return !document.body.innerText.includes('\(escapedText)');
                        } catch (e) {
                            return true;
                        }
                    })()
                    """
                let result = evaluateJavaScript(script)
                if let gone = result.result as? Bool, gone {
                    return (true, nil)
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return (false, "Timeout after \(timeout)s waiting for text to disappear: '\(textGone)'")
        }

        return (false, "Provide text, text_gone, or time parameter")
    }

    // MARK: - Screenshot

    func takeScreenshot(fullPage: Bool = false) -> Data? {
        // Validate state - need a page loaded for screenshot
        guard hasNavigated else {
            return nil
        }

        var imageData: Data?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            let config = WKSnapshotConfiguration()

            if fullPage {
                // Get full page dimensions with safety checks
                let dimensionScript = """
                    (function() {
                        try {
                            if (!document || !document.body) {
                                return JSON.stringify({width: 1280, height: 800});
                            }
                            return JSON.stringify({
                                width: Math.max(document.body.scrollWidth || 1280, 1280),
                                height: Math.max(document.body.scrollHeight || 800, 800)
                            });
                        } catch (e) {
                            return JSON.stringify({width: 1280, height: 800});
                        }
                    })()
                    """
                self.webView.evaluateJavaScript(dimensionScript) { result, _ in
                    if let jsonString = result as? String,
                        let data = jsonString.data(using: .utf8),
                        let dimensions = try? JSONSerialization.jsonObject(with: data) as? [String: CGFloat],
                        let width = dimensions["width"],
                        let height = dimensions["height"]
                    {
                        // Cap dimensions to prevent memory issues
                        let cappedWidth = min(width, 8000)
                        let cappedHeight = min(height, 8000)
                        config.rect = CGRect(x: 0, y: 0, width: cappedWidth, height: cappedHeight)
                    }

                    self.captureSnapshot(config: config) { data in
                        imageData = data
                        semaphore.signal()
                    }
                }
            } else {
                self.captureSnapshot(config: config) { data in
                    imageData = data
                    semaphore.signal()
                }
            }
        }

        _ = semaphore.wait(timeout: .now() + 30)
        return imageData
    }

    private func captureSnapshot(config: WKSnapshotConfiguration, completion: @escaping (Data?) -> Void) {
        webView.takeSnapshot(with: config) { image, error in
            guard let image = image, error == nil else {
                completion(nil)
                return
            }

            // Convert NSImage to PNG data
            guard let tiffData = image.tiffRepresentation,
                let bitmap = NSBitmapImageRep(data: tiffData),
                let pngData = bitmap.representation(using: .png, properties: [:])
            else {
                completion(nil)
                return
            }

            completion(pngData)
        }
    }

    // MARK: - Properties

    var currentURL: String? {
        var url: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            url = self.webView.url?.absoluteString
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return url
    }

    var currentTitle: String? {
        var title: String?
        let semaphore = DispatchSemaphore(value: 0)

        DispatchQueue.main.async {
            title = self.webView.title
            semaphore.signal()
        }

        _ = semaphore.wait(timeout: .now() + 5)
        return title
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isLoaded = true
        navigationSemaphore.signal()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        navigationError = error
        navigationSemaphore.signal()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        navigationError = error
        navigationSemaphore.signal()
    }

    // MARK: - Console / Network capture (read buffers from page)

    func consoleMessages(level: String?, since: Double?, clear: Bool) -> [[String: Any]] {
        let levelFilter = level?.lowercased() ?? "all"
        let script = """
            (function() {
              try {
                var arr = window.__osaurus_console || [];
                return arr;
              } catch (e) { return []; }
            })()
            """
        let result = evaluateJavaScript(script)
        var messages: [[String: Any]] = []
        if let arr = result.result as? [[String: Any]] {
            messages = arr
        }
        if levelFilter != "all" {
            messages = messages.filter { (entry: [String: Any]) -> Bool in
                ((entry["level"] as? String)?.lowercased() ?? "") == levelFilter
            }
        }
        if let since = since {
            let cutoff = since * 1000
            messages = messages.filter { entry in
                ((entry["timestamp"] as? Double) ?? 0) >= cutoff
            }
        }
        if clear {
            _ = evaluateJavaScript("window.__osaurus_console = [];")
        }
        return messages
    }

    func networkRequests(failedOnly: Bool, methodFilter: String?, urlContains: String?, clear: Bool) -> [[String: Any]]
    {
        let script = """
            (function() {
              try { return window.__osaurus_network || []; }
              catch (e) { return []; }
            })()
            """
        let result = evaluateJavaScript(script)
        var requests: [[String: Any]] = []
        if let arr = result.result as? [[String: Any]] {
            requests = arr
        }
        if failedOnly {
            requests = requests.filter { entry in
                let status = entry["status"] as? Int ?? 0
                return status == 0 || !(200...399 ~= status)
            }
        }
        if let m = methodFilter?.uppercased() {
            requests = requests.filter { ($0["method"] as? String) == m }
        }
        if let needle = urlContains?.lowercased() {
            requests = requests.filter { ($0["url"] as? String)?.lowercased().contains(needle) ?? false }
        }
        if clear {
            _ = evaluateJavaScript("window.__osaurus_network = [];")
        }
        return requests
    }

    // MARK: - Viewport / UA

    func setViewport(width: Int, height: Int) {
        DispatchQueue.main.sync {
            self.webView.frame = NSRect(x: 0, y: 0, width: width, height: height)
        }
    }

    func currentViewport() -> (width: Int, height: Int) {
        var w = 0
        var h = 0
        DispatchQueue.main.sync {
            w = Int(self.webView.frame.width)
            h = Int(self.webView.frame.height)
        }
        return (w, h)
    }

    func setUserAgent(_ ua: String?) {
        DispatchQueue.main.sync {
            self.webView.customUserAgent = (ua?.isEmpty ?? true) ? nil : ua
        }
    }

    func currentUserAgent() -> String? {
        var ua: String?
        DispatchQueue.main.sync { ua = self.webView.customUserAgent }
        return ua
    }

    // MARK: - Cookies

    func cookieStore() -> WKHTTPCookieStore {
        return webView.configuration.websiteDataStore.httpCookieStore
    }

    func getCookies(domain: String?) -> [[String: Any]] {
        let semaphore = DispatchSemaphore(value: 0)
        var cookies: [HTTPCookie] = []
        DispatchQueue.main.async {
            self.cookieStore().getAllCookies { c in
                cookies = c
                semaphore.signal()
            }
        }
        _ = semaphore.wait(timeout: .now() + 5)
        let filtered = domain.map { d in cookies.filter { $0.domain.contains(d) } } ?? cookies
        return filtered.map { c in
            [
                "name": c.name,
                "value": c.value,
                "domain": c.domain,
                "path": c.path,
                "secure": c.isSecure,
                "http_only": c.isHTTPOnly,
                "expires": c.expiresDate?.timeIntervalSince1970 as Any? ?? NSNull(),
            ]
        }
    }

    func setCookie(_ props: [String: Any]) -> (ok: Bool, error: String?) {
        var attrs: [HTTPCookiePropertyKey: Any] = [:]
        guard let name = props["name"] as? String,
            let value = props["value"] as? String,
            let domain = props["domain"] as? String
        else {
            return (false, "name, value, and domain are required")
        }
        attrs[.name] = name
        attrs[.value] = value
        attrs[.domain] = domain
        attrs[.path] = (props["path"] as? String) ?? "/"
        if let secure = props["secure"] as? Bool, secure { attrs[.secure] = "TRUE" }
        if let expires = props["expires"] as? Double {
            attrs[.expires] = Date(timeIntervalSince1970: expires)
        }
        guard let cookie = HTTPCookie(properties: attrs) else {
            return (false, "Failed to construct cookie from properties")
        }
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            self.cookieStore().setCookie(cookie) { semaphore.signal() }
        }
        _ = semaphore.wait(timeout: .now() + 5)
        return (true, nil)
    }

    func clearCookies(domain: String?) {
        let cookies = getCookies(domain: domain)
        let semaphore = DispatchSemaphore(value: 0)
        var remaining = cookies.count
        if remaining == 0 { return }
        DispatchQueue.main.async {
            for c in cookies {
                guard let name = c["name"] as? String,
                    let dom = c["domain"] as? String,
                    let path = c["path"] as? String,
                    let cookie = HTTPCookie(properties: [
                        .name: name, .value: "", .domain: dom, .path: path,
                    ])
                else {
                    remaining -= 1
                    if remaining == 0 { semaphore.signal() }
                    continue
                }
                self.cookieStore().delete(cookie) {
                    remaining -= 1
                    if remaining == 0 { semaphore.signal() }
                }
            }
        }
        _ = semaphore.wait(timeout: .now() + 5)
    }

    // MARK: - Dialogs

    func setDialogPolicy(accept: Bool, promptText: String?) {
        pendingDialogPolicy = DialogPolicy(accept: accept, promptText: promptText)
    }

    func recordedDialog() -> [String: Any]? {
        return lastDialog
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        lastDialog = ["kind": "alert", "message": message, "timestamp": Date().timeIntervalSince1970]
        completionHandler()
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        lastDialog = [
            "kind": "confirm",
            "message": message,
            "timestamp": Date().timeIntervalSince1970,
            "accepted": pendingDialogPolicy.accept,
        ]
        let accept = pendingDialogPolicy.accept
        pendingDialogPolicy = DialogPolicy(accept: true, promptText: nil)
        completionHandler(accept)
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let text = pendingDialogPolicy.accept ? (pendingDialogPolicy.promptText ?? defaultText ?? "") : nil
        lastDialog = [
            "kind": "prompt",
            "message": prompt,
            "default_text": defaultText ?? "",
            "response": text as Any? ?? NSNull(),
            "timestamp": Date().timeIntervalSince1970,
        ]
        pendingDialogPolicy = DialogPolicy(accept: true, promptText: nil)
        completionHandler(text)
    }

    // MARK: - Lock state

    func acquireLock(owner: String?) -> (ok: Bool, owner: String?) {
        var success = false
        var current: String?
        lockQueue.sync {
            if lockState.locked {
                current = lockState.owner
                success = false
            } else {
                lockState = LockState(locked: true, owner: owner ?? "anonymous", acquiredAt: Date())
                current = lockState.owner
                success = true
            }
        }
        return (success, current)
    }

    func releaseLock(owner: String?) -> Bool {
        var success = false
        lockQueue.sync {
            if !lockState.locked { return }
            if owner == nil || lockState.owner == owner {
                lockState = LockState(locked: false, owner: nil, acquiredAt: nil)
                success = true
            }
        }
        return success
    }

    func currentLock() -> [String: Any] {
        var info: [String: Any] = ["locked": false]
        lockQueue.sync {
            info["locked"] = lockState.locked
            if let owner = lockState.owner { info["owner"] = owner }
            if let date = lockState.acquiredAt {
                info["acquired_at"] = date.timeIntervalSince1970
            }
        }
        return info
    }

}

/// Escape a CSS selector for safe interpolation inside a single-quoted JS
/// string literal. Handles backslashes, single quotes, newlines, and other
/// JS-string-breaking chars. Free function so it's unit-testable.
func escapeSelector(_ selector: String) -> String {
    return
        selector
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "'", with: "\\'")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

// MARK: - JSON Helpers

func escapeJSON(_ s: String) -> String {
    return
        s
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\n", with: "\\n")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
}

func toJSONString(_ value: Any?) -> String {
    guard let value = value else { return "null" }

    if let string = value as? String {
        return "\"\(escapeJSON(string))\""
    } else if let number = value as? NSNumber {
        return "\(number)"
    } else if let bool = value as? Bool {
        return bool ? "true" : "false"
    } else if let array = value as? [Any] {
        let items = array.map { toJSONString($0) }.joined(separator: ",")
        return "[\(items)]"
    } else if let dict = value as? [String: Any] {
        let items = dict.map { "\"\(escapeJSON($0.key))\":\(toJSONString($0.value))" }.joined(separator: ",")
        return "{\(items)}"
    } else {
        return "\"\(escapeJSON(String(describing: value)))\""
    }
}

// MARK: - Snapshot Formatting

func formatSnapshotOutput(_ data: [String: Any], detail: DetailLevel) -> String {
    let title = data["title"] as? String ?? ""
    let url = data["url"] as? String ?? ""
    let hasMore = data["hasMore"] as? Bool ?? false
    let bodyText = data["bodyText"] as? String ?? ""

    switch detail {
    case .none:
        return ""

    case .compact:
        var output = "- page: \(title) | url: \(url)\n"

        guard let elements = data["elements"] as? [[String: Any]], !elements.isEmpty else {
            return output + "(no interactive elements found)"
        }

        var parts: [String] = []
        for element in elements {
            let ref = element["ref"] as? String ?? ""
            let type = element["type"] as? String ?? ""
            let text = element["text"] as? String ?? ""
            let truncText = text.count > 20 ? String(text.prefix(20)) + "..." : text

            if !truncText.isEmpty {
                parts.append("[\(ref)] \(type) \"\(truncText)\"")
            } else {
                parts.append("[\(ref)] \(type)")
            }
        }

        output += parts.joined(separator: " ")
        if hasMore {
            output += " ..."
        }
        return output

    case .standard:
        var output = ""
        output += "- page: \(title)\n"
        output += "- url: \(url)\n\n"

        guard let elements = data["elements"] as? [[String: Any]], !elements.isEmpty else {
            return output + "(no interactive elements found)"
        }

        for element in elements {
            let ref = element["ref"] as? String ?? ""
            let type = element["type"] as? String ?? ""
            let text = element["text"] as? String ?? ""

            var line = "[\(ref)] \(type)"

            if !text.isEmpty {
                line += " \"\(text)\""
            }

            var attrs: [String] = []
            if let name = element["name"] as? String, !name.isEmpty {
                attrs.append("name=\"\(name)\"")
            }
            if let placeholder = element["placeholder"] as? String, !placeholder.isEmpty {
                attrs.append("placeholder=\"\(placeholder)\"")
            }
            if let href = element["href"] as? String, !href.isEmpty, type == "link" {
                attrs.append("href=\"\(href)\"")
            }
            if let value = element["value"] as? String, !value.isEmpty {
                attrs.append("value=\"\(value)\"")
            }
            if element["checked"] as? Bool == true {
                attrs.append("checked")
            }
            if element["disabled"] as? Bool == true {
                attrs.append("disabled")
            }
            if element["required"] as? Bool == true {
                attrs.append("required")
            }

            if !attrs.isEmpty {
                line += " " + attrs.joined(separator: " ")
            }

            output += line + "\n"
        }

        if hasMore {
            output += "\n... (more elements available, use filter or increase max_elements)"
        }

        return output

    case .full:
        var output = ""
        output += "- page: \(title)\n"
        output += "- url: \(url)\n"

        if !bodyText.isEmpty {
            let truncBody = bodyText.count > 200 ? String(bodyText.prefix(200)) + "..." : bodyText
            let singleLine =
                truncBody
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
            output += "- text: \(singleLine)\n"
        }

        output += "\n"

        guard let elements = data["elements"] as? [[String: Any]], !elements.isEmpty else {
            return output + "(no interactive elements found)"
        }

        for element in elements {
            let ref = element["ref"] as? String ?? ""
            let type = element["type"] as? String ?? ""
            let text = element["text"] as? String ?? ""

            var line = "[\(ref)] \(type)"

            if !text.isEmpty {
                line += " \"\(text)\""
            }

            var attrs: [String] = []
            if let name = element["name"] as? String, !name.isEmpty {
                attrs.append("name=\"\(name)\"")
            }
            if let id = element["id"] as? String, !id.isEmpty {
                attrs.append("id=\"\(id)\"")
            }
            if let placeholder = element["placeholder"] as? String, !placeholder.isEmpty {
                attrs.append("placeholder=\"\(placeholder)\"")
            }
            if let href = element["href"] as? String, !href.isEmpty {
                attrs.append("href=\"\(href)\"")
            }
            if let value = element["value"] as? String, !value.isEmpty {
                attrs.append("value=\"\(value)\"")
            }
            if let ariaLabel = element["ariaLabel"] as? String, !ariaLabel.isEmpty {
                attrs.append("aria-label=\"\(ariaLabel)\"")
            }
            if element["checked"] as? Bool == true {
                attrs.append("checked")
            }
            if element["disabled"] as? Bool == true {
                attrs.append("disabled")
            }
            if element["required"] as? Bool == true {
                attrs.append("required")
            }

            if !attrs.isEmpty {
                line += " " + attrs.joined(separator: " ")
            }

            output += line + "\n"
        }

        if hasMore {
            output += "\n... (more elements available, use filter or increase max_elements)"
        }

        return output
    }
}

// MARK: - Plugin Context

class PluginContext {
    /// Returns the plugin manifest JSON string for testing
    static func getManifestJSON() -> String {
        // Trigger the manifest generation through the C ABI
        let entryPtr = osaurus_plugin_entry()
        guard let ptr = entryPtr else { return "{}" }

        // The api struct has 5 function pointers in order:
        // free_string, init, destroy, get_manifest, invoke
        let apiBase = ptr.assumingMemoryBound(to: Optional<UnsafeRawPointer>.self)

        // get_manifest is at offset 3
        guard let getManifestRaw = apiBase.advanced(by: 3).pointee else { return "{}" }

        typealias GetManifestFn = @convention(c) (UnsafeMutableRawPointer?) -> UnsafePointer<CChar>?
        let getManifest = unsafeBitCast(getManifestRaw, to: GetManifestFn.self)

        guard let cStr = getManifest(nil) else { return "{}" }
        let result = String(cString: cStr)

        // free_string is at offset 0
        if let freeStringRaw = apiBase.advanced(by: 0).pointee {
            typealias FreeStringFn = @convention(c) (UnsafePointer<CChar>?) -> Void
            let freeString = unsafeBitCast(freeStringRaw, to: FreeStringFn.self)
            freeString(cStr)
        }

        return result
    }

    lazy var browser: HeadlessBrowser = {
        // Ensure NSApplication is initialized for WebKit
        if NSApp == nil {
            DispatchQueue.main.sync {
                _ = NSApplication.shared
            }
        }
        return HeadlessBrowser()
    }()

    // MARK: - Helpers

    func parseDetail(_ detail: String?, default defaultLevel: DetailLevel = .compact) -> DetailLevel {
        guard let detail = detail else { return defaultLevel }
        return DetailLevel(rawValue: detail) ?? defaultLevel
    }

    func autoSnapshot(detail: DetailLevel, actionPrefix: String) -> String {
        if detail == .none {
            return actionPrefix
        }
        let snapshot = browser.takeSnapshot(detail: detail)
        return actionPrefix + "\n" + snapshot
    }

    // MARK: - Tool Implementations

    func navigate(args: String) -> String {
        struct Args: Decodable {
            let url: String
            let wait_until: String?
            let timeout: Double?
            let detail: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: url\"}"
        }

        let waitUntil = HeadlessBrowser.WaitUntil(rawValue: input.wait_until ?? "load") ?? .load
        let result = browser.navigate(to: input.url, timeout: input.timeout ?? 30, waitUntil: waitUntil)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        let detail = parseDetail(input.detail)
        return autoSnapshot(detail: detail, actionPrefix: "Action: navigate to \(input.url) succeeded")
    }

    func snapshot(args: String) -> String {
        struct Args: Decodable {
            let filter: String?
            let max_elements: Int?
            let visible_only: Bool?
            let detail: String?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(filter: nil, max_elements: nil, visible_only: nil, detail: nil)
        }

        var options = HeadlessBrowser.SnapshotOptions()
        if let filter = input.filter { options.filter = filter }
        if let maxElements = input.max_elements { options.maxElements = maxElements }
        if let visibleOnly = input.visible_only { options.visibleOnly = visibleOnly }

        let detail = parseDetail(input.detail, default: .standard)
        let result = browser.takeSnapshot(options: options, detail: detail)
        return result
    }

    func click(args: String) -> String {
        struct Args: Decodable {
            let ref: String?
            let selector: String?
            let detail: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: ref or selector\"}"
        }

        let result = browser.clickElement(ref: input.ref, selector: input.selector)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        // Brief DOM stability wait for click-triggered changes
        Thread.sleep(forTimeInterval: 0.2)

        let detail = parseDetail(input.detail)
        return autoSnapshot(detail: detail, actionPrefix: "Action: click succeeded")
    }

    func type(args: String) -> String {
        struct Args: Decodable {
            let ref: String?
            let selector: String?
            let text: String
            let clear: Bool?
            let submit: Bool?
            let detail: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: (ref or selector), text\"}"
        }

        let result = browser.typeText(
            ref: input.ref,
            selector: input.selector,
            text: input.text,
            clear: input.clear ?? true,
            submit: input.submit ?? false
        )

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        let detail = parseDetail(input.detail)
        return autoSnapshot(detail: detail, actionPrefix: "Action: type succeeded")
    }

    func select(args: String) -> String {
        struct Args: Decodable {
            let ref: String?
            let selector: String?
            let values: [String]
            let detail: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: (ref or selector), values\"}"
        }

        let result = browser.selectOption(ref: input.ref, selector: input.selector, values: input.values)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        let detail = parseDetail(input.detail)
        return autoSnapshot(detail: detail, actionPrefix: "Action: select succeeded")
    }

    func hover(args: String) -> String {
        struct Args: Decodable {
            let ref: String?
            let selector: String?
            let detail: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: ref or selector\"}"
        }

        let result = browser.hoverElement(ref: input.ref, selector: input.selector)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        let detail = parseDetail(input.detail)
        return autoSnapshot(detail: detail, actionPrefix: "Action: hover succeeded")
    }

    func scroll(args: String) -> String {
        struct Args: Decodable {
            let direction: String?
            let ref: String?
            let x: Int?
            let y: Int?
            let detail: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: direction, ref, or x/y\"}"
        }

        let result = browser.scroll(direction: input.direction, ref: input.ref, x: input.x, y: input.y)

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        let detail = parseDetail(input.detail)
        return autoSnapshot(detail: detail, actionPrefix: "Action: scroll succeeded")
    }

    func pressKey(args: String) -> String {
        struct Args: Decodable {
            let key: String
            let modifiers: [String]?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: key\"}"
        }

        let result = browser.pressKey(key: input.key, modifiers: input.modifiers ?? [])

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true}"
    }

    func waitFor(args: String) -> String {
        struct Args: Decodable {
            let text: String?
            let text_gone: String?
            let time: Double?
            let timeout: Double?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: text, text_gone, or time\"}"
        }

        let result = browser.waitFor(
            text: input.text,
            textGone: input.text_gone,
            time: input.time,
            timeout: input.timeout ?? 10
        )

        if !result.success {
            return "{\"error\": \"\(escapeJSON(result.error ?? "Unknown error"))\"}"
        }

        return "{\"success\": true}"
    }

    func screenshot(args: String) -> String {
        struct Args: Decodable {
            let path: String?
            let full_page: Bool?
        }

        let input: Args
        if let data = args.data(using: .utf8),
            let decoded = try? JSONDecoder().decode(Args.self, from: data)
        {
            input = decoded
        } else {
            input = Args(path: nil, full_page: nil)
        }

        guard let imageData = browser.takeScreenshot(fullPage: input.full_page ?? false) else {
            return
                "{\"error\": \"Failed to capture screenshot. Make sure a page is loaded with browser_navigate first.\"}"
        }

        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")

        let path: String
        if let customPath = input.path {
            path = (customPath as NSString).expandingTildeInPath
        } else {
            path =
                FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Downloads")
                .appendingPathComponent("screenshot_\(timestamp).png")
                .path
        }

        do {
            try imageData.write(to: URL(fileURLWithPath: path))
            return "{\"success\": true, \"path\": \"\(escapeJSON(path))\", \"size\": \(imageData.count)}"
        } catch {
            return "{\"error\": \"Failed to save screenshot: \(escapeJSON(error.localizedDescription))\"}"
        }
    }

    func executeScript(args: String) -> String {
        struct Args: Decodable {
            let script: String
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: script\"}"
        }

        // Wrap user script in try-catch for better error handling
        let safeScript = """
            (function() {
                try {
                    return {result: (function() { \(input.script) })()};
                } catch (e) {
                    return {error: e.message || String(e)};
                }
            })()
            """

        let result = browser.evaluateJavaScript(safeScript)

        if let error = result.error {
            return
                "{\"error\": \"JavaScript execution failed: \(escapeJSON(error)). Make sure a page is loaded with browser_navigate first.\"}"
        }

        if let dict = result.result as? [String: Any] {
            if let errorMsg = dict["error"] as? String {
                return "{\"error\": \"Script error: \(escapeJSON(errorMsg))\"}"
            }
            return "{\"result\": \(toJSONString(dict["result"]))}"
        }

        return "{\"result\": \(toJSONString(result.result))}"
    }

    // MARK: - Batch Actions

    func batchDo(args: String) -> String {
        struct ActionItem: Decodable {
            let action: String
            let ref: String?
            let selector: String?
            let text: String?
            let values: [String]?
            let key: String?
            let modifiers: [String]?
            let direction: String?
            let x: Int?
            let y: Int?
            let clear: Bool?
            let submit: Bool?
            let time: Double?
            let timeout: Double?
            let text_gone: String?
        }

        struct Args: Decodable {
            let actions: [ActionItem]
            let detail: String?
            let wait_after: String?
        }

        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return "{\"error\": \"Invalid arguments. Required: actions (array)\"}"
        }

        let detail = parseDetail(input.detail)

        if input.actions.isEmpty {
            return autoSnapshot(detail: detail, actionPrefix: "Action: browser_do completed (0 actions)")
        }

        for (index, action) in input.actions.enumerated() {
            let result: (success: Bool, error: String?)

            switch action.action {
            case "click":
                result = browser.clickElement(ref: action.ref, selector: action.selector)
            case "type":
                guard let text = action.text else {
                    let snapshot = browser.takeSnapshot(detail: detail)
                    return "Error: Action \(index) (type) missing required 'text' parameter\n\n\(snapshot)"
                }
                result = browser.typeText(
                    ref: action.ref,
                    selector: action.selector,
                    text: text,
                    clear: action.clear ?? true,
                    submit: action.submit ?? false
                )
            case "select":
                guard let values = action.values else {
                    let snapshot = browser.takeSnapshot(detail: detail)
                    return "Error: Action \(index) (select) missing required 'values' parameter\n\n\(snapshot)"
                }
                result = browser.selectOption(ref: action.ref, selector: action.selector, values: values)
            case "hover":
                result = browser.hoverElement(ref: action.ref, selector: action.selector)
            case "scroll":
                result = browser.scroll(
                    direction: action.direction, ref: action.ref, x: action.x, y: action.y)
            case "press_key":
                guard let key = action.key else {
                    let snapshot = browser.takeSnapshot(detail: detail)
                    return "Error: Action \(index) (press_key) missing required 'key' parameter\n\n\(snapshot)"
                }
                result = browser.pressKey(key: key, modifiers: action.modifiers ?? [])
            case "wait_for":
                result = browser.waitFor(
                    text: action.text,
                    textGone: action.text_gone,
                    time: action.time,
                    timeout: action.timeout ?? 10
                )
            default:
                let snapshot = browser.takeSnapshot(detail: detail)
                return "Error: Action \(index) has unknown action type '\(action.action)'\n\n\(snapshot)"
            }

            if !result.success {
                let snapshot = browser.takeSnapshot(detail: detail)
                return
                    "Error: Action \(index) (\(action.action)) failed: \(result.error ?? "Unknown error")\n\n\(snapshot)"
            }
        }

        // Optional wait after all actions
        if let waitAfter = input.wait_after {
            switch waitAfter {
            case "domstable":
                browser.waitForDOMStable(timeout: 10)
            case "networkidle":
                browser.waitForNetworkIdle(timeout: 10)
            default:
                break
            }
        }

        // Brief stability wait if last action was a click
        if let lastAction = input.actions.last, lastAction.action == "click" {
            Thread.sleep(forTimeInterval: 0.2)
        }

        return autoSnapshot(
            detail: detail,
            actionPrefix: "Action: browser_do completed (\(input.actions.count) actions)")
    }

    // MARK: - New tools (2.0.0)
    //
    // These tools use the standard JSON envelope:
    //   { "ok": true,  "data": {...} }
    //   { "ok": false, "error": {"code","message","hint"?} }
    // The legacy tools above retain their pre-2.0.0 plain-text snapshot output
    // for back-compat with the existing test suite.

    private func envelopeOK(_ data: [String: Any]) -> String {
        return jsonEnvelope(["ok": true, "data": data])
    }

    private func envelopeError(_ code: String, _ message: String, hint: String? = nil) -> String {
        var error: [String: Any] = ["code": code, "message": message]
        if let hint = hint { error["hint"] = hint }
        return jsonEnvelope(["ok": false, "error": error])
    }

    private func jsonEnvelope(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
            let data = try? JSONSerialization.data(
                withJSONObject: obj,
                options: [.sortedKeys, .withoutEscapingSlashes]
            ),
            let str = String(data: data, encoding: .utf8)
        else {
            return #"{"ok":false,"error":{"code":"INTERNAL","message":"serialization failed"}}"#
        }
        return str
    }

    func consoleMessages(args: String) -> String {
        struct Args: Decodable {
            let level: String?
            let since: Double?
            let clear: Bool?
        }
        let parsed =
            (args.data(using: .utf8).flatMap { try? JSONDecoder().decode(Args.self, from: $0) })
            ?? Args(level: nil, since: nil, clear: nil)
        let messages = browser.consoleMessages(level: parsed.level, since: parsed.since, clear: parsed.clear ?? false)
        return envelopeOK([
            "count": messages.count,
            "messages": messages,
        ])
    }

    func networkRequests(args: String) -> String {
        struct Args: Decodable {
            let failed_only: Bool?
            let method: String?
            let url_contains: String?
            let clear: Bool?
        }
        let parsed =
            (args.data(using: .utf8).flatMap { try? JSONDecoder().decode(Args.self, from: $0) })
            ?? Args(failed_only: nil, method: nil, url_contains: nil, clear: nil)
        let entries = browser.networkRequests(
            failedOnly: parsed.failed_only ?? false,
            methodFilter: parsed.method,
            urlContains: parsed.url_contains,
            clear: parsed.clear ?? false
        )
        return envelopeOK([
            "count": entries.count,
            "requests": entries,
        ])
    }

    func handleDialog(args: String) -> String {
        struct Args: Decodable {
            let action: String?
            let prompt_text: String?
        }
        let parsed =
            (args.data(using: .utf8).flatMap { try? JSONDecoder().decode(Args.self, from: $0) })
            ?? Args(action: nil, prompt_text: nil)
        let action = (parsed.action ?? "accept").lowercased()
        switch action {
        case "accept":
            browser.setDialogPolicy(accept: true, promptText: parsed.prompt_text)
        case "dismiss":
            browser.setDialogPolicy(accept: false, promptText: nil)
        case "status":
            break
        default:
            return envelopeError(
                "INVALID_ARGS",
                "Unknown dialog action '\(action)'.",
                hint: "Use 'accept', 'dismiss', or 'status'."
            )
        }
        var data: [String: Any] = ["policy": action]
        if let last = browser.recordedDialog() { data["last_dialog"] = last }
        return envelopeOK(data)
    }

    func setViewport(args: String) -> String {
        struct Args: Decodable {
            let width: Int
            let height: Int
        }
        guard let data = args.data(using: .utf8),
            let input = try? JSONDecoder().decode(Args.self, from: data)
        else {
            return envelopeError("INVALID_ARGS", "Required: width (int), height (int).")
        }
        browser.setViewport(width: input.width, height: input.height)
        let v = browser.currentViewport()
        return envelopeOK(["width": v.width, "height": v.height])
    }

    func setUserAgent(args: String) -> String {
        struct Args: Decodable { let user_agent: String? }
        let parsed =
            (args.data(using: .utf8).flatMap { try? JSONDecoder().decode(Args.self, from: $0) })
            ?? Args(user_agent: nil)
        browser.setUserAgent(parsed.user_agent)
        return envelopeOK([
            "user_agent": browser.currentUserAgent() ?? NSNull()
        ])
    }

    func cookies(args: String) -> String {
        struct Args: Decodable {
            let action: String?
            let domain: String?
            let cookie: [String: AnyJSON]?
        }
        let parsed =
            (args.data(using: .utf8).flatMap { try? JSONDecoder().decode(Args.self, from: $0) })
            ?? Args(action: nil, domain: nil, cookie: nil)
        let action = (parsed.action ?? "get").lowercased()
        switch action {
        case "get":
            return envelopeOK(["cookies": browser.getCookies(domain: parsed.domain)])
        case "set":
            guard let cookieDict = parsed.cookie else {
                return envelopeError("INVALID_ARGS", "Required: cookie object with name, value, domain.")
            }
            let raw = cookieDict.mapValues { $0.value }
            let result = browser.setCookie(raw)
            if !result.ok {
                return envelopeError("COOKIE_SET_FAILED", result.error ?? "unknown")
            }
            return envelopeOK(["set": true])
        case "clear":
            browser.clearCookies(domain: parsed.domain)
            return envelopeOK(["cleared": true])
        default:
            return envelopeError(
                "INVALID_ARGS",
                "Unknown cookies action '\(action)'.",
                hint: "Use 'get', 'set', or 'clear'."
            )
        }
    }

    func lock(args: String) -> String {
        struct Args: Decodable {
            let action: String?
            let owner: String?
        }
        let parsed =
            (args.data(using: .utf8).flatMap { try? JSONDecoder().decode(Args.self, from: $0) })
            ?? Args(action: nil, owner: nil)
        let action = (parsed.action ?? "lock").lowercased()
        switch action {
        case "lock":
            let result = browser.acquireLock(owner: parsed.owner)
            if !result.ok {
                return envelopeError(
                    "LOCK_HELD",
                    "Browser is already locked by '\(result.owner ?? "unknown")'.",
                    hint: "Wait and retry, or call browser_lock with action='unlock' (if you own it)."
                )
            }
            return envelopeOK(["locked": true, "owner": result.owner ?? NSNull()])
        case "unlock":
            let ok = browser.releaseLock(owner: parsed.owner)
            if !ok {
                return envelopeError(
                    "LOCK_NOT_OWNED",
                    "Cannot release a lock you don't own.",
                    hint: "Pass the same owner string that acquired the lock."
                )
            }
            return envelopeOK(["locked": false])
        case "status":
            return envelopeOK(browser.currentLock())
        default:
            return envelopeError(
                "INVALID_ARGS",
                "Unknown lock action '\(action)'.",
                hint: "Use 'lock', 'unlock', or 'status'."
            )
        }
    }
}

/// JSON-decodable wrapper for arbitrary values (used in cookies args).
struct AnyJSON: Decodable {
    let value: Any
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let v = try? container.decode(Bool.self) {
            value = v
        } else if let v = try? container.decode(Int.self) {
            value = v
        } else if let v = try? container.decode(Double.self) {
            value = v
        } else if let v = try? container.decode(String.self) {
            value = v
        } else if let v = try? container.decode([String: AnyJSON].self) {
            value = v.mapValues { $0.value }
        } else if let v = try? container.decode([AnyJSON].self) {
            value = v.map { $0.value }
        } else {
            value = NSNull()
        }
    }
}

// MARK: - C ABI

private typealias osr_plugin_ctx_t = UnsafeMutableRawPointer
private typealias osr_free_string_t = @convention(c) (UnsafePointer<CChar>?) -> Void
private typealias osr_init_t = @convention(c) () -> osr_plugin_ctx_t?
private typealias osr_destroy_t = @convention(c) (osr_plugin_ctx_t?) -> Void
private typealias osr_get_manifest_t = @convention(c) (osr_plugin_ctx_t?) -> UnsafePointer<CChar>?
private typealias osr_invoke_t =
    @convention(c) (
        osr_plugin_ctx_t?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?,
        UnsafePointer<CChar>?
    ) -> UnsafePointer<CChar>?

private struct osr_plugin_api {
    var free_string: osr_free_string_t?
    var `init`: osr_init_t?
    var destroy: osr_destroy_t?
    var get_manifest: osr_get_manifest_t?
    var invoke: osr_invoke_t?
}

private func makeCString(_ s: String) -> UnsafePointer<CChar>? {
    guard let ptr = strdup(s) else { return nil }
    return UnsafePointer(ptr)
}

private var api: osr_plugin_api = {
    var api = osr_plugin_api()

    api.free_string = { ptr in
        if let p = ptr { free(UnsafeMutableRawPointer(mutating: p)) }
    }

    api.`init` = {
        let ctx = PluginContext()
        return Unmanaged.passRetained(ctx).toOpaque()
    }

    api.destroy = { ctxPtr in
        guard let ctxPtr = ctxPtr else { return }
        Unmanaged<PluginContext>.fromOpaque(ctxPtr).release()
    }

    api.get_manifest = { _ in
        let manifest = """
            {
              "plugin_id": "osaurus.browser",
              "name": "Browser",
              "description": "Agent-friendly headless WebKit browser. Element refs from snapshots, batched actions, console & network inspection, dialog handling, viewport / UA control, cookies, and a cooperative lock for multi-agent safety.",
              "license": "MIT",
              "authors": ["Osaurus Team"],
              "min_macos": "13.0",
              "min_osaurus": "0.5.0",
              "capabilities": {
                "tools": [
                  {
                    "id": "browser_navigate",
                    "description": "Navigate to a URL and return a page snapshot with element refs. Use wait_until='networkidle' for SPAs. Use detail to control snapshot verbosity.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "url": {"type": "string", "description": "URL to navigate to"},
                        "wait_until": {"type": "string", "enum": ["load", "networkidle", "domstable"], "description": "When to consider navigation done"},
                        "timeout": {"type": "number", "description": "Timeout in seconds (default 30)"},
                        "detail": {"type": "string", "enum": ["none", "compact", "standard", "full"], "description": "Snapshot verbosity: none (action result only), compact (single-line refs, default), standard (multi-line with attributes), full (all attributes + page text)"}
                      },
                      "required": ["url"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_snapshot",
                    "description": "Get a structured snapshot of interactive elements. Usually not needed since action tools return snapshots automatically. Use when you need to re-inspect without acting.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "filter": {"type": "string", "enum": ["all", "inputs", "buttons", "links", "forms"], "description": "Filter element types (default: all)"},
                        "max_elements": {"type": "number", "description": "Max elements to return (default: 100)"},
                        "visible_only": {"type": "boolean", "description": "Only visible elements (default: true)"},
                        "detail": {"type": "string", "enum": ["none", "compact", "standard", "full"], "description": "Snapshot verbosity (default: standard)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "browser_click",
                    "description": "Click an element and return updated page snapshot.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Element ref from snapshot (e.g., 'E5')"},
                        "selector": {"type": "string", "description": "CSS selector (fallback if ref not available)"},
                        "detail": {"type": "string", "enum": ["none", "compact", "standard", "full"], "description": "Snapshot verbosity (default: compact)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_type",
                    "description": "Type text into an input element and return updated page snapshot. Use submit=true to press Enter after typing.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Element ref from snapshot"},
                        "selector": {"type": "string", "description": "CSS selector (fallback)"},
                        "text": {"type": "string", "description": "Text to type"},
                        "clear": {"type": "boolean", "description": "Clear existing text first (default: true)"},
                        "submit": {"type": "boolean", "description": "Press Enter after typing (default: false)"},
                        "detail": {"type": "string", "enum": ["none", "compact", "standard", "full"], "description": "Snapshot verbosity (default: compact)"}
                      },
                      "required": ["text"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_select",
                    "description": "Select option(s) in a dropdown and return updated page snapshot.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Element ref from snapshot"},
                        "selector": {"type": "string", "description": "CSS selector (fallback)"},
                        "values": {"type": "array", "items": {"type": "string"}, "description": "Values or text to select"},
                        "detail": {"type": "string", "enum": ["none", "compact", "standard", "full"], "description": "Snapshot verbosity (default: compact)"}
                      },
                      "required": ["values"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_hover",
                    "description": "Hover over an element and return updated page snapshot.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "ref": {"type": "string", "description": "Element ref from snapshot"},
                        "selector": {"type": "string", "description": "CSS selector (fallback)"},
                        "detail": {"type": "string", "enum": ["none", "compact", "standard", "full"], "description": "Snapshot verbosity (default: compact)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_scroll",
                    "description": "Scroll the page and return updated page snapshot.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "direction": {"type": "string", "enum": ["up", "down", "left", "right"], "description": "Scroll direction"},
                        "ref": {"type": "string", "description": "Scroll to bring this element into view"},
                        "x": {"type": "number", "description": "X coordinate to scroll to"},
                        "y": {"type": "number", "description": "Y coordinate to scroll to"},
                        "detail": {"type": "string", "enum": ["none", "compact", "standard", "full"], "description": "Snapshot verbosity (default: compact)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "browser_do",
                    "description": "Execute multiple browser actions in sequence and return a single snapshot at the end. Use to batch interactions (type, click, select, etc.) in one call. All refs from the previous snapshot remain valid throughout the batch. If any action fails, execution stops and returns the error with a snapshot.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "actions": {
                          "type": "array",
                          "description": "Ordered list of actions to execute",
                          "items": {
                            "type": "object",
                            "properties": {
                              "action": {"type": "string", "enum": ["click", "type", "select", "hover", "scroll", "press_key", "wait_for"], "description": "Action type"},
                              "ref": {"type": "string", "description": "Element ref from snapshot"},
                              "selector": {"type": "string", "description": "CSS selector (fallback)"},
                              "text": {"type": "string", "description": "Text for type action, or text to wait for in wait_for"},
                              "values": {"type": "array", "items": {"type": "string"}, "description": "Values for select action"},
                              "key": {"type": "string", "description": "Key for press_key action"},
                              "modifiers": {"type": "array", "items": {"type": "string"}, "description": "Modifier keys for press_key"},
                              "direction": {"type": "string", "description": "Direction for scroll"},
                              "clear": {"type": "boolean", "description": "Clear before typing (default: true)"},
                              "submit": {"type": "boolean", "description": "Submit after typing"},
                              "time": {"type": "number", "description": "Wait time in seconds"},
                              "timeout": {"type": "number", "description": "Wait timeout in seconds"},
                              "text_gone": {"type": "string", "description": "Wait for text to disappear"}
                            },
                            "required": ["action"]
                          }
                        },
                        "detail": {"type": "string", "enum": ["none", "compact", "standard", "full"], "description": "Snapshot verbosity for final result (default: compact)"},
                        "wait_after": {"type": "string", "enum": ["none", "domstable", "networkidle"], "description": "Wait condition after last action before snapshotting"}
                      },
                      "required": ["actions"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_press_key",
                    "description": "Press a keyboard key. Useful for Enter, Escape, Tab, arrow keys, or shortcuts.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "key": {"type": "string", "description": "Key name (Enter, Escape, Tab, ArrowUp, ArrowDown, etc.) or character"},
                        "modifiers": {"type": "array", "items": {"type": "string"}, "description": "Modifier keys: ctrl, shift, alt, meta/cmd"}
                      },
                      "required": ["key"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_wait_for",
                    "description": "Wait for text to appear, disappear, or for a specified time.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "text": {"type": "string", "description": "Wait for this text to appear"},
                        "text_gone": {"type": "string", "description": "Wait for this text to disappear"},
                        "time": {"type": "number", "description": "Wait for this many seconds"},
                        "timeout": {"type": "number", "description": "Max time to wait (default: 10s)"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "browser_screenshot",
                    "description": "Take a screenshot for visual debugging. Use full_page=true for entire page.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "path": {"type": "string", "description": "Save path (default: ~/Downloads/screenshot_<timestamp>.png)"},
                        "full_page": {"type": "boolean", "description": "Capture full scrollable page"}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_execute_script",
                    "description": "Execute arbitrary JavaScript. Use as escape hatch for edge cases not covered by other tools.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "script": {"type": "string", "description": "JavaScript code to execute"}
                      },
                      "required": ["script"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_console_messages",
                    "description": "Read JavaScript console output captured since the page loaded (or since the last clear). Returns level, message, timestamp (ms epoch), and call-site for each entry.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "level": {"type": "string", "enum": ["all", "log", "info", "warn", "error", "debug"], "description": "Filter by level. Default 'all'."},
                        "since": {"type": "number", "description": "Unix seconds. Only return messages at or after this time."},
                        "clear": {"type": "boolean", "description": "Clear the buffer after returning. Default false."}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "browser_network_requests",
                    "description": "List fetch/XHR requests made by the page. Includes method, url, status, ok, duration_ms.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "failed_only": {"type": "boolean", "description": "Only return requests with status 0 or 4xx/5xx."},
                        "method": {"type": "string", "description": "Filter by HTTP method (GET, POST, etc.)."},
                        "url_contains": {"type": "string", "description": "Filter by substring in URL."},
                        "clear": {"type": "boolean", "description": "Clear the buffer after returning. Default false."}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  },
                  {
                    "id": "browser_handle_dialog",
                    "description": "Pre-register a policy for the next JavaScript dialog (alert/confirm/prompt). Call BEFORE the action that triggers the dialog. Default policy is 'accept'.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "action": {"type": "string", "enum": ["accept", "dismiss", "status"], "description": "accept=OK/Yes/use prompt_text; dismiss=Cancel/No/null; status=read last dialog."},
                        "prompt_text": {"type": "string", "description": "Text to fill into a window.prompt() dialog when action='accept'."}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_set_viewport",
                    "description": "Resize the headless WebKit viewport. Useful for testing responsive layouts.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "width": {"type": "integer", "description": "Pixels."},
                        "height": {"type": "integer", "description": "Pixels."}
                      },
                      "required": ["width", "height"]
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_set_user_agent",
                    "description": "Override the User-Agent header for subsequent navigations. Pass an empty string or omit user_agent to reset to the WebKit default.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "user_agent": {"type": "string", "description": "Full UA string. Empty/null restores default."}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_cookies",
                    "description": "Inspect, set, or clear cookies in the headless WebKit cookie store.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "action": {"type": "string", "enum": ["get", "set", "clear"], "description": "Default 'get'."},
                        "domain": {"type": "string", "description": "Filter (get/clear) by domain substring."},
                        "cookie": {"type": "object", "description": "For action='set': {name, value, domain, path?, secure?, expires?(unix seconds)}."}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "ask"
                  },
                  {
                    "id": "browser_lock",
                    "description": "Cooperative lock for multi-agent safety. Call action='lock' before a critical sequence and action='unlock' after. Other agents are expected to honor this lock; it is advisory, not enforced.",
                    "parameters": {
                      "type": "object",
                      "properties": {
                        "action": {"type": "string", "enum": ["lock", "unlock", "status"], "description": "Default 'lock'."},
                        "owner": {"type": "string", "description": "Free-form owner string (agent name, task id, etc.). Required to release the lock you acquired."}
                      },
                      "required": []
                    },
                    "requirements": [],
                    "permission_policy": "allow"
                  }
                ]
              }
            }
            """
        return makeCString(manifest)
    }

    api.invoke = { ctxPtr, typePtr, idPtr, payloadPtr in
        guard let ctxPtr = ctxPtr,
            let typePtr = typePtr,
            let idPtr = idPtr,
            let payloadPtr = payloadPtr
        else { return nil }

        let ctx = Unmanaged<PluginContext>.fromOpaque(ctxPtr).takeUnretainedValue()
        let type = String(cString: typePtr)
        let id = String(cString: idPtr)
        let payload = String(cString: payloadPtr)

        guard type == "tool" else {
            return makeCString("{\"error\": \"Unknown capability type\"}")
        }

        switch id {
        case "browser_navigate":
            return makeCString(ctx.navigate(args: payload))
        case "browser_snapshot":
            return makeCString(ctx.snapshot(args: payload))
        case "browser_click":
            return makeCString(ctx.click(args: payload))
        case "browser_type":
            return makeCString(ctx.type(args: payload))
        case "browser_select":
            return makeCString(ctx.select(args: payload))
        case "browser_hover":
            return makeCString(ctx.hover(args: payload))
        case "browser_scroll":
            return makeCString(ctx.scroll(args: payload))
        case "browser_press_key":
            return makeCString(ctx.pressKey(args: payload))
        case "browser_wait_for":
            return makeCString(ctx.waitFor(args: payload))
        case "browser_screenshot":
            return makeCString(ctx.screenshot(args: payload))
        case "browser_execute_script":
            return makeCString(ctx.executeScript(args: payload))
        case "browser_do":
            return makeCString(ctx.batchDo(args: payload))
        case "browser_console_messages":
            return makeCString(ctx.consoleMessages(args: payload))
        case "browser_network_requests":
            return makeCString(ctx.networkRequests(args: payload))
        case "browser_handle_dialog":
            return makeCString(ctx.handleDialog(args: payload))
        case "browser_set_viewport":
            return makeCString(ctx.setViewport(args: payload))
        case "browser_set_user_agent":
            return makeCString(ctx.setUserAgent(args: payload))
        case "browser_cookies":
            return makeCString(ctx.cookies(args: payload))
        case "browser_lock":
            return makeCString(ctx.lock(args: payload))
        default:
            return makeCString("{\"error\": \"Unknown tool: \(id)\"}")
        }
    }

    return api
}()

@_cdecl("osaurus_plugin_entry")
public func osaurus_plugin_entry() -> UnsafeRawPointer? {
    return UnsafeRawPointer(&api)
}
