# Changelog — osaurus.search

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
