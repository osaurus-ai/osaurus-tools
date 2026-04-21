---
name: osaurus-fetch
description: Teaches the agent how to use the HTTP fetch tools — JSON APIs, Readability HTML extraction, file downloads, with built-in SSRF and size limits.
metadata:
  author: Osaurus
  version: "2.0.0"
---

# Fetch

Lightweight HTTP client for grounding agent work in real web content. Hardened by default: SSRF guard blocks private IPs, response size capped at 10 MB, downloads sandboxed to `~/Downloads`.

## When to use

- Calling a public JSON API (`fetch_json`).
- Reading the *content* of a static page or article (`fetch_html` returns Markdown).
- Saving a file to disk (`download`).
- Anything where the page does not require JavaScript execution or a real browser session.

## When NOT to use

- Pages that need login, JavaScript rendering, or interaction → use `osaurus.browser`.
- Web search → use `osaurus.search` (then feed top URLs to `fetch_html`).
- Reaching localhost / `127.0.0.1` / private LAN IPs → blocked by SSRF guard. Set `allow_private: true` only if the user explicitly asked for it.

## Canonical workflow

```text
1. osaurus.search.search(query)           → list of URLs
2. osaurus.fetch.fetch_html(url)          → { markdown, title, byline, ... }
3. Reason over the markdown
```

Or for APIs:

```text
1. osaurus.fetch.fetch_json(url, headers, body)
2. data is already parsed JSON in the response
```

## Output envelope

```json
{
  "ok": true,
  "data": {
    "status": 200,
    "final_url": "https://example.com/after/redirects",
    "redirect_chain": ["https://t.co/abc", "https://example.com/..."],
    "protocol_version": "h2",
    "headers": { "content-type": "..." },
    "body": "...",                     // fetch only
    "json": { ... },                   // fetch_json only
    "markdown": "...", "title": "...", // fetch_html only
    "truncated": false
  }
}
{ "ok": false, "error": { "code": "...", "message": "...", "hint": "..." } }
```

Common error codes: `INVALID_ARGS`, `SSRF_BLOCKED`, `TIMEOUT`, `RESPONSE_TOO_LARGE`, `HTTP_ERROR`, `EXTRACTION_FAILED`, `DOWNLOAD_PATH_INVALID`.

## Tips

- For long pages, prefer `fetch_html` over `fetch` — the Readability extractor returns clean Markdown a model can actually use, while `fetch` returns the raw HTML body.
- `auth: { type: "bearer", token: "..." }` is a shortcut for an `Authorization` header — use it instead of constructing headers manually.
- `download` rejects path separators, `..`, and absolute paths in `filename`. Pass a plain filename only.
- `max_bytes` caps the in-memory response. Default 10 MB. If you hit `truncated: true`, your data is incomplete.
