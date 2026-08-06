# Changelog

All notable registry changes are documented here. Per-plugin release notes
live in each plugin's external repository.

## Registry update (2026-08-06) — core capability retirements

### Removed

- **`osaurus.browser`** — superseded by the core app's host-managed browser
  and Computer Use capabilities.
- **`osaurus.fetch`** — superseded by native web retrieval and the host HTTP
  client.
- **`osaurus.messages`** — superseded by the core Messages integration.
- **`osaurus.telegram`** — superseded by the core Connections and Telegram
  transport.

Their catalog files, in-repository source, and dedicated build/release support
have been removed. Existing installed copies continue to work, and all signed
GitHub release artifacts remain available by direct URL. Upgrade the host
before uninstalling a legacy copy; see [migration guidance](docs/MIGRATION.md).

## Registry update (2026-07-17) — time, search, and macos-use retired

### Removed

- **`osaurus.macos-use`** — superseded by the host app's built-in Computer Use
  subagent (Osaurus 0.20.5+), whose native macOS driver was brought in-core
  from `osaurus-ai/osaurus-macos-use`. The built-in surface covers the
  plugin's GUI automation (windows, elements, input, screenshots, sessions)
  with host-managed Accessibility / Screen Recording permission flows and
  per-agent gating.
- **`osaurus.time`** — superseded by the host app's built-in `get_current_time`
  tool (Osaurus 0.22.0+). The plugin's date-arithmetic extras (`format_date`,
  `parse_date`, `convert_timezone`, `add_duration`, `diff_dates`,
  `list_timezones`) saw little agent use; models handle this reasoning inline
  once they have the current time.
- **`osaurus.search`** — superseded by the host app's native web search
  (`web_search`, `search_and_extract`, Osaurus 0.22.0+), which ships the same
  pluggable provider stack (free scraping by default, Tavily / Brave / Serper /
  Google CSE / Kagi / You.com via API key) with provider settings in the
  Search tab. The host migrates plugin-configured API keys automatically.

The catalog files for all three plugins have been deleted from `plugins/`,
matching the `osaurus.filesystem` / `osaurus.git` retirement in 2.0.0: existing
GitHub release artifacts remain reachable by direct URL and installed copies
keep working, but the plugins are no longer discoverable or installable through
the registry.

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

### Per-tool highlights

- **`osaurus.time`** — adds `parse_date`, `convert_timezone`, `add_duration`,
  `diff_dates`, `list_timezones`. `format_date` finally accepts the date
  strings its description always claimed. Forces `en_US_POSIX` locale for
  `relative` mode unless `locale` is passed.
- **`osaurus.search`** — pluggable API backends (Tavily, Brave Search API,
  Serper, Google CSE, Kagi, You.com) behind the secrets schema, with the
  free DDG → Brave → Bing scraping cascade as fallback. Per-result
  `published_date`, `source_domain`, `engine`, `rank`. Results deduplicated
  by URL. First-class `site`, `filetype`, `time_range` params. `offset` /
  `page` pagination. Fixes `uddg=` redirect unwrapping in the DDG-lite path
  and the numeric-HTML-entity decoder. New `search_and_extract` runs search
  plus content extraction on the top results in one call.
