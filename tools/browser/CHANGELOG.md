# Changelog — osaurus.browser

## Unreleased

### Fixed

- **Tool errors are now reported to the host as failures.** Many tools returned bare `{"error": "..."}` objects or plain `"Error: ..."` strings. The Osaurus host classifies any result not shaped like `{"ok": false, ...}` as a SUCCESS, so those failures were silently surfaced to the model as successful calls. A single normalization boundary in `invoke` now rewrites such results into the canonical failure envelope (`{"ok": false, "kind": ..., "message": ..., "retryable": ...}`) while leaving real envelopes and success payloads untouched.
- **`browser_reset_session` no longer crashes the host process.** Previously called `WKWebsiteDataStore.remove(forIdentifier:)` immediately after tearing down the `WKWebView`, which races with WebKit's Networking / Storage XPC processes that may still hold the per-identifier store open. On macOS 14+ the internal completion lambda inside `WebsiteDataStore::removeDataStoreWithIdentifierImpl` would dispatch to a NULL `RunLoop` and segfault inside the `com.apple.WebKit.WebsiteDataStoreIO` queue, taking the host (Osaurus) down with it. Reset now wipes every cookie / localStorage / IndexedDB / cache entry in place via the documented `removeData(ofTypes:modifiedSince:)` API and clears the persisted `profile_id` so the next session mints a brand-new isolated UUID. Behaviourally equivalent (next session is logged out and isolated) without the crash.

## 2.0.0

### Added

- **Per-agent persistent browser sessions.** Each Osaurus agent now has its own on-disk `WKWebsiteDataStore` keyed by a per-agent `profile_id` (resolved via the host's per-agent keychain). Cookies, localStorage, IndexedDB, and cache survive across runs and stay isolated between agents — agent A signing into Gmail does not log agent B in.
- **`browser_open_login`** — opens a *visible* login window (NSWindow + WKWebView) bound to the active agent's data store. The user signs in normally (OAuth, 2FA, captchas all work in a real window). Cookies entered there are immediately visible to the headless instance for subsequent `browser_*` calls. Optional `url` parameter; otherwise the window opens with a small prompt that lets the user enter any URL.
- **`browser_reset_session`** — closes the active agent's headless browser and removes its on-disk data store. Next tool call respawns a fresh logged-out profile.
- **`LOGIN_REQUIRED` structured error** returned by `browser_navigate` when navigation lands on a login-looking page (path matches `/login`, `/signin`, `/auth`, etc., or document title matches `^(Sign in|Log in|Login)`). The error envelope includes `domain`, `url`, and a hint telling the agent to call `browser_open_login` rather than asking the user for credentials in chat.
- **ABI v2.** Plugin now exports `osaurus_plugin_entry_v2` so it receives the host API. Required for per-agent `config_get` / `config_set` (used to bootstrap and persist `profile_id`). The legacy `osaurus_plugin_entry` is kept for v1 hosts.
- **`browser_console_messages`** — read JavaScript console output captured since page load. Filter by level (`log`/`info`/`warn`/`error`/`debug`), filter by `since` timestamp, optionally `clear` the buffer.
- **`browser_network_requests`** — list all `fetch` and `XMLHttpRequest` calls the page has made. Filter by `failed_only`, `method`, or `url_contains`.
- **`browser_handle_dialog`** — pre-register a policy for the next `alert` / `confirm` / `prompt` dialog. Default policy is `accept`.
- **`browser_set_viewport`** — resize the headless WebKit viewport (e.g. mobile widths).
- **`browser_set_user_agent`** — override or reset the User-Agent for subsequent navigations.
- **`browser_cookies`** — `get` / `set` / `clear` cookies in the headless WebKit cookie store.
- **`browser_lock`** — cooperative lock with an `owner` string for multi-agent safety. Advisory only.
- **Auto-injected console + network capture.** A `WKUserScript` runs at document start in every page to wrap `console.*` and instrument `fetch` / `XMLHttpRequest` so the new inspection tools have data to return.
- **`WKUIDelegate` conformance** for proper alert/confirm/prompt handling. Previously dialogs were silently auto-accepted with no agent visibility.

### Breaking

- **`min_macos` raised to 14.0.** `WKWebsiteDataStore(forIdentifier:)` is macOS 14+, and per-agent isolation depends on it.
- **Browser state is now persistent on disk** instead of in-memory. There is no migration step (previous releases had no persisted state to migrate), but existing agents will start with empty profiles on first run after upgrade.

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
