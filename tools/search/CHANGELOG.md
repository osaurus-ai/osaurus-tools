# Changelog — osaurus.search

## 2.2.0

### Added

- **Keenable backend.** New paid provider `keenable` — web search purpose-built for AI agents. Configure `KEENABLE_API_KEY` from [docs.keenable.ai](https://docs.keenable.ai). Sits at the top of the paid priority cascade.

## 2.1.0

### Fixed

- **Brave HTML scraping returned zero results.** Brave reshipped their search frontend with new class names (`.snippet` wrapper, `<a class="title">` for the title link, `<div class="description">` for the snippet, ad blocks tagged with `data-type="ad"` and `/a/redirect` hrefs). The legacy regex looked for an unqualified `class="...title..."` `<div>` that no longer exists in the markup, so `parseBraveHTML` always returned an empty list. The new parser slices on `.snippet` (CSS-class-aware tokenization, so `snippet-description` no longer false-matches), filters out ad blocks, and pulls URL / title / description from the modern selectors.

### Added — easier for agents to use

- **Auto-cascade is now the dominant path.** The tool description no longer enumerates `Tavily > Brave API > Serper > ...` — that copy was baiting agents into hallucinating `provider: "tavily"` / `"auto"` / `"bing"` even with no API keys configured. New copy: *"Just pass `query` — the plugin auto-selects the best available backend."*
- **`provider` / `region` / `site` / `filetype` / `offset` are demoted** to "Advanced — leave unset unless ..." in the schema. Agents see the simple shape first.
- **Unknown `provider` and malformed `region` are silently sanitized** into auto-cascade rather than erroring. Agents that send `provider: "auto"` or `region: "us"` (instead of `"us-en"`) now get results plus a `warnings: [...]` entry explaining the substitution.

### Added — fewer "stuck" tool calls

- **Free fallback scrapers run in parallel** under a 12 s wall-clock budget. Previously DDG → Brave → Bing ran sequentially with a 25 s per-request timeout, so a single slow / rate-limited Brave page could wedge a whole search call for 60–90 s. With the new parallel race, the tool always returns within ~12 s when no API key is configured, even if Brave hangs.
- **Per-request HTTP timeout dropped 25 s → 8 s** for scrapers (paid APIs explicitly request 15 s). Timed-out URLSession tasks are now cancelled at the timeout instead of waiting `timeout + 5 s` slack.
- **Brave anti-bot challenge pages are detected and skipped** (response under 2 KB / contains `captcha` / `just a moment` / `checking your browser`). Surfaced as `attempts: [{ ok: false, error: "challenge_page" }]` instead of silently parsing an empty result.
- **Free cascade early-exit:** if any one provider returns ≥ 3 hits, the cascade returns immediately rather than waiting for the budget to expire.

### Changed

- **`NO_RESULTS` is now an `ok:false` failure** instead of `ok:true, count:0`. The error envelope carries `data.attempts` and any `data.warnings` so the agent can see *why* nothing came back. Old behavior misled agents into thinking the search "succeeded".
- **Free providers' results are merged + deduplicated** across the parallel cascade (paid APIs still short-circuit on first success, since each call costs quota).
- **Tools return `ToolOutcome { data, warnings }`** internally so non-fatal warnings (e.g. ignored bad provider) ride along with successful responses.

### Tests

- Added fixtures for the modern Brave markup, ad filtering, challenge-page detection.
- Added unit tests for `sanitizeProvider` (`"auto"` / `"bing"` / `"TAVILY"`), `sanitizeRegion` (`"us"` rejected, `"us-en"` accepted), `providerHasSecrets`, and the `runWebOrNews` `NO_RESULTS` path.

## 2.0.0

### Added

- **Pluggable backends behind the manifest's `secrets` schema.** Configure any of these in the plugin settings to upgrade from scraping to grounded API search:
  - `TAVILY_API_KEY` — Tavily (best free agent search; great snippets and dates)
  - `BRAVE_SEARCH_API_KEY` — Brave Search API
  - `SERPER_API_KEY` — Serper (Google SERP)
  - `GOOGLE_CSE_API_KEY` + `GOOGLE_CSE_CX` — Google Custom Search Engine
  - `KAGI_API_KEY` — Kagi
  - `YOU_API_KEY` — You.com
- **`provider` arg** to pin a specific backend (`tavily`, `brave_api`, `serper`, `google_cse`, `kagi`, `you`, `ddg`, `brave_html`, `bing_html`). Without it, the highest-quality configured backend is picked, falling back to the free DDG → Brave HTML → Bing HTML cascade.
- **First-class operators.** `site`, `filetype`, and `time_range` (`d`/`w`/`m`/`y`) are translated per-provider rather than relying on the agent to splice them into the query string.
- **Pagination.** `offset` (and a returned `next_offset` when there are more results) for backends that support it.
- **Per-result metadata.** Every result now carries `rank`, `published_date` (when available), `source_domain`, `engine`, plus the existing `title`/`url`/`snippet`. Results are deduplicated by URL across providers.
- **`search_and_extract`**, a new tool that runs a search and Readability-fetches the top N URLs in one call. Each enriched result includes `markdown`, `title`, `byline`, `lang`, `word_count`, and `extracted: true|false`.
- **Attempt log.** The response includes an `attempts` array showing which providers were tried and the outcome of each — useful for debugging quota / rate-limit issues.

### Changed

- **Breaking**: every tool returns the standard envelope:

  ```json
  { "ok": true, "data": { ... } }
  { "ok": false, "error": { "code": "...", "message": "...", "hint": "..." } }
  ```

- Plugin description corrected to reflect actual behavior: DuckDuckGo / Brave / Bing scraping cascade by default, optional API backends.
- Plugin display name dropped the `"Osaurus "` prefix; authors set to `["Osaurus Team"]`.

### Fixed

- DDG `?uddg=` redirect wrappers are now unwrapped in **all** parser branches (previously only the main path did this; lite branch exposed wrapped URLs).
- Numeric HTML entities (`&#NN;`, `&#xHH;`) preserve their codepoints instead of being stripped to empty strings.
- Bing news parsing reuses the same per-result extraction as web instead of always emitting empty snippets.

### Notes on signing

Any plugin version signed before the November 2025 minisign rotation is unverifiable. Reinstalling from the registry pulls the currently-signed `2.0.0` build.
