---
name: osaurus-search
description: Teaches the agent how to use the web search tools — DuckDuckGo / Brave / Bing scraping by default, optional API backends (Tavily, Brave Search API, Serper, Google CSE, Kagi, You.com).
metadata:
  author: Osaurus
  version: "2.0.0"
---

# Search

Web search for grounding. Free by default (HTML scraping with engine cascade), upgradable to API-grade backends when the user has configured an API key.

## When to use

- The user asks a factual question that needs current information.
- You need URLs to feed to `osaurus.fetch.fetch_html` for grounded research.
- The user wants news (`search_news`), images (`search_images`), or a quick grounded answer (`search_and_extract`).

## When NOT to use

- Reading a *known* URL — go straight to `osaurus.fetch.fetch_html`.
- Querying the user's own files — use the host's working-folder search.
- Real-time stock/weather data — those usually want a dedicated API.

## Backend selection

Provider order (auto):

1. If `TAVILY_API_KEY` / `BRAVE_SEARCH_API_KEY` / `SERPER_API_KEY` / etc. is configured via secrets → use that API (best snippets, dates, dedup).
2. Otherwise scrape DuckDuckGo HTML, then Brave HTML, then Bing HTML. First non-empty result set wins.

Pass `provider: "tavily"` (or another concrete name) to pin a backend.

## Canonical workflow

Grounded research:

```text
1. search(query, max_results=5, time_range="month")
2. For each result url: fetch_html(url) → markdown
3. Synthesize from the markdowns; cite final_url + published_date
```

Quick answer:

```text
1. search_and_extract(query, max_results=3)
   → returns search results with `markdown` already populated
```

## Output envelope

```json
{
  "ok": true,
  "data": {
    "query": "...",
    "provider": "tavily",
    "results": [
      {
        "rank": 1,
        "title": "...",
        "url": "https://...",
        "snippet": "...",
        "published_date": "2025-04-15",
        "source_domain": "example.com",
        "engine": "tavily"
      }
    ],
    "next_offset": 10
  }
}
{ "ok": false, "error": { "code": "...", "message": "...", "hint": "..." } }
```

Common error codes: `INVALID_ARGS`, `NO_RESULTS`, `RATE_LIMITED`, `PROVIDER_UNAVAILABLE`, `MISSING_API_KEY`.

## Tips

- Use `site:` / `filetype:` / `time_range` as first-class params, not query operators — they translate per provider.
- Always paginate with `offset` rather than re-querying for more results.
- Snippets vary in quality across providers. If you need full text, follow up with `fetch_html` on the top URLs.
- Image search uses DuckDuckGo only; results may be unstable if DDG changes its endpoint.
