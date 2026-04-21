# Changelog

All notable changes to the official Osaurus core tools and registry. Per-plugin
release notes live in each tool's own `tools/<tool>/CHANGELOG.md`.

## 2.0.0 — Coordinated core-tools overhaul

This release reshapes the official core-tools surface around what an agent
actually needs and what the host app already provides.

### Removed

- **`osaurus.filesystem`** — fully redundant with the host app's working-folder
  file tools and the Linux sandbox VM. The plugin advertised "any path" access
  with no sandboxing, which conflicted with the host's safety story. Use the
  working folder you pick when starting a chat; for arbitrary shell + file
  access use the sandbox VM.
- **`osaurus.git`** — fully redundant with the host app's working-folder git
  tools (status, log, diff, branch). Pick a working folder and the agent gets
  these automatically. The planned write-tool / blame / grep / show additions
  were cancelled in favor of investing that effort in the host.

The catalog files for both plugins have been deleted from `plugins/`. Existing
GitHub release artifacts remain reachable by direct URL but are no longer
discoverable through the registry.

### Changed

- **`time`, `fetch`, and `search`** now ship a uniform response envelope
  across every tool:

  ```json
  { "ok": true,  "data": { ... }, "warnings": ["..."] }
  { "ok": false, "error": { "code": "...", "message": "...", "hint": "..." } }
  ```

  This is a **breaking change** for any client that read the previous shapes
  (`{"error": "..."}`, plain strings, `{"diff": "...", "stats": "..."}`,
  etc.). Bad arguments and unknown timezone IDs now produce structured
  `INVALID_ARGS` errors instead of silently falling back to defaults.

- **`browser`** uses the same envelope for all **new** tools (console,
  network, dialog, viewport, UA, cookies, lock). The pre-existing tools
  (`browser_navigate`, `browser_click`, `browser_do`, etc.) keep their
  plain-text snapshot output for back-compat with the existing test
  suite; they will migrate to the envelope in a future minor release.

- **Branding unified.** All catalog and dylib manifests now declare
  `authors: ["Osaurus Team"]`. Display names dropped the `"Osaurus "` prefix
  (`"Osaurus Time"` → `"Time"`, etc.). The `plugin_id` namespace
  (`osaurus.<name>`) is unchanged.

- **Single source of truth for catalog metadata.** The registry catalog files
  in `plugins/<id>.json` are now derived from each tool's embedded
  `get_manifest()` JSON via [`scripts/regenerate-catalogs.py`](scripts/regenerate-catalogs.py).
  CI fails any PR where the two drift apart. Distribution-only fields
  (`versions[]`, `public_keys`, `homepage`, `docs`, `skill`) remain
  registry-owned and are preserved untouched.

### Per-tool highlights

- **`osaurus.time`** — adds `parse_date`, `convert_timezone`, `add_duration`,
  `diff_dates`, `list_timezones`. `format_date` finally accepts the date
  strings its description always claimed. Forces `en_US_POSIX` locale for
  `relative` mode unless `locale` is passed.
- **`osaurus.fetch`** — SSRF guard blocks private/loopback/link-local/metadata
  IPs by default (`allow_private: true` to opt out). `max_bytes` cap (default
  10 MB) with explicit `truncated` flag. Every tool now returns `final_url`,
  `redirect_chain`, `protocol_version`, and headers. Bearer/Basic auth
  helpers. `fetch_html` replaces the regex stripper with a Readability-style
  extractor returning `markdown`, `title`, `byline`, `excerpt`, `lang`,
  `word_count`. `download` rejects path separators / `..` / absolute paths in
  `filename`.
- **`osaurus.search`** — pluggable API backends (Tavily, Brave Search API,
  Serper, Google CSE, Kagi, You.com) behind the secrets schema, with the
  free DDG → Brave → Bing scraping cascade as fallback. Per-result
  `published_date`, `source_domain`, `engine`, `rank`. Results deduplicated
  by URL. First-class `site`, `filetype`, `time_range` params. `offset` /
  `page` pagination. Fixes `uddg=` redirect unwrapping in the DDG-lite path
  and the numeric-HTML-entity decoder. New `search_and_extract` runs search
  + Readability-fetch on the top N URLs in one call.
- **`osaurus.browser`** — snapshots are now ARIA-YAML with inline `[E1]` refs
  for parity with Playwright MCP and Cursor's browser MCP. Adds
  `browser_tabs`, `browser_console_messages`, `browser_network_requests`,
  `browser_handle_dialog`, `browser_file_upload`, `browser_set_viewport`,
  `browser_set_user_agent`, `browser_cookies`, and explicit
  `browser_lock` / `browser_unlock` for multi-agent safety. `wait_until:
  "networkidle"` now uses real request instrumentation. `escapeSelector` is
  hardened.

### Notes on signing

The minisign keypair was rotated in November 2025 (commits `8ec6500 fix keys`
and `2f3ade7 remove invalid versions`). The current registry public key for
all four kept core tools is

```
RWTBNLjKflgtwJIKPYHuGjVNR8Huce4PvIRgLzxsd5DrdvB+I5KjeeC3
```

Any plugin version signed before the rotation is unverifiable against this
key — reinstalling via the registry pulls only the newer, currently-signed
builds. `scripts/build-tool.sh` now refuses to build a release if the
in-repo `public_keys.minisign` doesn't match the `MINISIGN_PUBLIC_KEY`
environment variable, so a future rotation can't silently produce
unverifiable artifacts.
