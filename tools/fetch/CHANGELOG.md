# Changelog — osaurus.fetch

## 2.0.0

### Added

- **SSRF guard.** `fetch`, `fetch_json`, `fetch_html`, and `download` now block requests to private/loopback/link-local/multicast IPv4 ranges, reserved IPv6 ranges, AWS/GCP metadata hostnames, and `*.local` / `*.internal` by default. Hostnames are resolved via `getaddrinfo` and each resolved address is re-checked. Set `allow_private: true` to bypass for trusted local endpoints.
- **Response size cap.** `max_bytes` (default 10 MB; 100 MB for `download`) caps in-memory data and reports `truncated: true` if the body would have exceeded the cap.
- **Redirect visibility.** Every successful response includes `final_url`, `redirect_chain[]`, and `protocol_version` (`http/1.1`, `h2`, etc.).
- **Body shapes.** Requests can now carry `body` (UTF-8 string), `body_base64` (raw bytes), `json_body` (auto-`Content-Type: application/json`), `form` (urlencoded), or `multipart` (form-data with file fields).
- **Auth helper.** `auth: { type: "bearer", token }` or `auth: { type: "basic", username, password }` injects the right `Authorization` header without the agent constructing it manually.
- **Readability-style HTML extraction.** `fetch_html` now defaults to `extract: "readability"`, returning `markdown`, `title`, `byline`, `excerpt`, `lang`, `word_count`. Pass `extract: "raw"` for the original HTML or `extract: "text"` for stripped plain text.
- **Selector hint.** `fetch_html` `selector` accepts `#id`, `.class`, or a bare tag name to scope extraction; falls back to `<article>` → `<main>` → `<body>`.

### Changed

- **Breaking**: every tool returns the standard envelope:

  ```json
  { "ok": true, "data": { ... } }
  { "ok": false, "error": { "code": "...", "message": "...", "hint": "..." } }
  ```

- **Breaking**: `fetch_html` output replaces `{status, content}` with the Readability fields above (or `html` / `text` when `extract` is set explicitly).
- **Breaking**: `fetch_json` returns parsed JSON under `data.json`; if the body wasn't valid JSON, `data.json` is `null` and `data.body` carries the raw text. Previously the implementation would fall back to a stringified body silently.
- **Hardened `download`.** Filenames are rejected if they contain `/`, `\`, `..`, or start with `.`/`~`. The resolved path is verified to remain inside `~/Downloads`.
- **Custom URLSession per request** with a real `URLSessionDataDelegate`, replacing the previous shared-session no-delegate flow. This is what unlocks redirect tracking, byte caps, and protocol detection.
- Plugin display name dropped the `"Osaurus "` prefix; authors set to `["Osaurus Team"]`.

### Removed

- Regex-based `text_only` HTML stripper. Use `extract: "text"` for the equivalent (still regex-based but with proper entity decoding) or `extract: "readability"` for clean Markdown.

### Fixed

- Numeric HTML entities (`&#NN;`, `&#xHH;`) now preserve their codepoints instead of being stripped to empty strings.
- Errors return clear codes (`INVALID_ARGS`, `SSRF_BLOCKED`, `TIMEOUT`, `DNS`, `NETWORK`, `HTTP_ERROR`, `RESPONSE_TOO_LARGE`, `EXTRACTION_FAILED`, `DOWNLOAD_PATH_INVALID`, `WRITE_FAILED`).

### Notes on signing

Any plugin version signed before the November 2025 minisign rotation is unverifiable. Reinstalling from the registry pulls the currently-signed `2.0.0` build.
