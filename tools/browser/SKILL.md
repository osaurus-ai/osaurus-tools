---
name: osaurus-browser
description: Teaches the agent how to use the headless browser tools — refs, batching, detail levels, console/network inspection, dialogs, viewport/UA, cookies, and lock/unlock for multi-agent safety.
metadata:
  author: Osaurus
  version: "2.0.0"
---

# Osaurus Browser

Headless browser automation via element refs. Every action returns a page snapshot automatically — you rarely need to call `browser_snapshot` separately.

## Typical Flow (2 calls)

```
1. browser_navigate(url)             → snapshot with refs [E1] [E2] [E3]
2. browser_do([type E1, type E2, click E3]) → snapshot of result page
```

## Key Concepts

**Element refs** — `browser_navigate` and all actions return refs like `[E1] input`, `[E2] button "Submit"`. Use these refs in subsequent calls.

**Detail levels** — Every tool accepts `detail` to control snapshot verbosity:

- `none` — action result only, no snapshot (~10 tokens)
- `compact` — single-line refs, default for actions (~200 tokens)
- `standard` — multi-line with attributes, default for `browser_snapshot` (~500 tokens)
- `full` — all attributes + IDs + aria-labels + page text excerpt (~1000+ tokens)

Use `compact` (default) for speed. Use `full` when you need to identify elements by ID or aria-label on complex pages.

## Tools

### browser_navigate

Navigate and get initial page snapshot.

```json
{ "url": "https://example.com", "detail": "compact" }
```

Use `wait_until: "networkidle"` for SPAs.

### browser_do

**Primary interaction tool.** Batch multiple actions in one call. All refs from the previous snapshot stay valid throughout the batch.

```json
{
  "actions": [
    { "action": "type", "ref": "E1", "text": "user@example.com" },
    { "action": "type", "ref": "E2", "text": "password123" },
    { "action": "click", "ref": "E3" }
  ],
  "detail": "compact"
}
```

Supported actions: `click`, `type`, `select`, `hover`, `scroll`, `press_key`, `wait_for`.

If an action fails, execution stops and the response includes: which action failed (index), the error, and a snapshot of current state for recovery.

Use `wait_after: "domstable"` or `"networkidle"` when the last action triggers async content.

### browser_click / browser_type / browser_select / browser_hover / browser_scroll

Individual action tools — each returns a snapshot automatically. Prefer `browser_do` when performing 2+ actions in sequence.

### browser_snapshot

Re-inspect the page without acting. Usually not needed since actions auto-return snapshots. Use when you need to re-check after `browser_wait_for` or `browser_execute_script`.

### browser_press_key

Press keyboard keys: `Enter`, `Escape`, `Tab`, arrow keys, or characters with modifiers.

### browser_wait_for

Wait for text to appear, disappear, or a specified time.

### browser_screenshot

Visual debugging — saves a PNG. Use `full_page: true` for the entire scrollable page.

### browser_execute_script

Escape hatch for arbitrary JavaScript.

## Inspection tools (2.0.0)

These tools return the standard JSON envelope (`{ok, data}` or `{ok:false, error:{code,message,hint?}}`).

### browser_console_messages

Read JavaScript console output captured since page load. Useful for diagnosing client-side errors.

```json
{ "level": "error", "clear": false }
```

Returns `data.messages: [{level, message, timestamp, location}]`.

### browser_network_requests

List fetch/XHR requests the page has made. Use `failed_only: true` to surface 4xx/5xx and network errors.

```json
{ "failed_only": true, "url_contains": "/api/" }
```

Returns `data.requests: [{method, url, status, ok, duration_ms, kind}]`.

### browser_handle_dialog

**Pre-register** the policy for the next `alert` / `confirm` / `prompt` *before* the action that triggers it.

```json
{ "action": "accept", "prompt_text": "yes" }
{ "action": "dismiss" }
{ "action": "status" }
```

Default policy if you never call this is `accept`.

## Environment tools

### browser_set_viewport

Resize the headless WebKit viewport (e.g. mobile-emulation widths).

### browser_set_user_agent

Override the User-Agent header for subsequent navigations. Pass empty/null to reset.

### browser_cookies

```json
{ "action": "get", "domain": "example.com" }
{ "action": "set", "cookie": { "name": "x", "value": "y", "domain": "example.com" } }
{ "action": "clear", "domain": "example.com" }
```

## Multi-agent coordination

### browser_lock

Cooperative lock so two agents don't fight over the same headless browser. Advisory only — other agents are expected to honor it.

```json
{ "action": "lock", "owner": "agent-alice" }
... do work ...
{ "action": "unlock", "owner": "agent-alice" }
{ "action": "status" }
```

If `lock` returns `{ok: false, error: {code: "LOCK_HELD", ...}}`, wait and retry.

## Tips

- Always start with `browser_navigate` — it gives you the refs you need.
- Batch with `browser_do` to minimize round-trips. A login flow is just navigate + browser_do.
- Use `detail: "none"` for intermediate actions where you already know the next step.
- If refs go stale (page changed unexpectedly), call `browser_snapshot` to get fresh ones.
- For SPAs, use `wait_until: "networkidle"` on navigate, or `wait_after: "domstable"` on browser_do.
- Prefer **refs over selectors**. CSS selectors are escaped for safety, but a ref is unambiguous.
- After triggering a JS error you suspect, call `browser_console_messages({"level": "error"})` to confirm.
- Before form submissions that show a confirm dialog, call `browser_handle_dialog({"action": "accept"})`.
