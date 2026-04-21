# Changelog — osaurus.browser

## 2.0.0

### Added

- **`browser_console_messages`** — read JavaScript console output captured since page load. Filter by level (`log`/`info`/`warn`/`error`/`debug`), filter by `since` timestamp, optionally `clear` the buffer.
- **`browser_network_requests`** — list all `fetch` and `XMLHttpRequest` calls the page has made. Filter by `failed_only`, `method`, or `url_contains`.
- **`browser_handle_dialog`** — pre-register a policy for the next `alert` / `confirm` / `prompt` dialog. Default policy is `accept`.
- **`browser_set_viewport`** — resize the headless WebKit viewport (e.g. mobile widths).
- **`browser_set_user_agent`** — override or reset the User-Agent for subsequent navigations.
- **`browser_cookies`** — `get` / `set` / `clear` cookies in the headless WebKit cookie store.
- **`browser_lock`** — cooperative lock with an `owner` string for multi-agent safety. Advisory only.
- **Auto-injected console + network capture.** A `WKUserScript` runs at document start in every page to wrap `console.*` and instrument `fetch` / `XMLHttpRequest` so the new inspection tools have data to return.
- **`WKUIDelegate` conformance** for proper alert/confirm/prompt handling. Previously dialogs were silently auto-accepted with no agent visibility.

### Changed

- All **new** tools (the seven added above) use the standard JSON envelope:

  ```json
  { "ok": true, "data": { ... } }
  { "ok": false, "error": { "code": "...", "message": "...", "hint": "..." } }
  ```

- The **legacy** tools (`browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_select`, `browser_hover`, `browser_scroll`, `browser_do`, `browser_press_key`, `browser_wait_for`, `browser_screenshot`, `browser_execute_script`) keep their existing plain-text snapshot output for back-compat with the existing test suite. They will move to the standard envelope in a future minor release.
- Plugin display name dropped the `"Osaurus "` prefix; authors set to `["Osaurus Team"]`.
- Description rewritten to reflect the broader feature set.

### Fixed

- **`escapeSelector` hardened.** Previously only escaped single quotes — selectors containing backslashes, newlines, tabs, or carriage returns could break the injected JS. Now escapes all of them.
- Removed dead `pendingRequests` / `networkIdleSemaphore` fields. Network idle continues to use the existing `performance.getEntriesByType('resource')` poll; the new `browser_network_requests` tool gives agents direct visibility into pending requests instead.

### Known limitations

- **Single-tab.** `browser_tabs` is not yet exposed. The plugin still operates against one `WKWebView` per plugin context.
- **`browser_file_upload`** is not exposed. Programmatic file inputs are blocked by WebKit's security model and require a different injection strategy.

### Notes on signing

Any plugin version signed before the November 2025 minisign rotation is unverifiable. Reinstalling from the registry pulls the currently-signed `2.0.0` build.
