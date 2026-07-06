# Osaurus Browsing Capability Execution Plan

Date: 2026-07-06  
Repository: `osaurus-ai/osaurus-tools`  
Base branch: `master`

Primary goal: make Osaurus browsing tools safe, readable, testable, and useful for real agent browsing workflows. This plan favors reviewable functional PRs over one oversized security PR, but every PR below must still deliver a real behavior improvement.

## Strategic Direction From External Harness Learnings

The attached reference-harness analysis reinforces the product direction without
making another harness the target architecture:

- Osaurus already has a broad local browser/search/fetch surface: WebKit
  automation, per-agent profiles, login helper, network/console/cookie tools,
  batched browser actions, search provider breadth, and one-shot
  `search_and_extract`.
- The highest-value gaps are not more provider backends. They are browser URL
  safety, readable authenticated/JS-rendered pages, budgeted outputs, local
  visual grounding, and an optional connection to a user's own Chrome-class
  browser.
- Osaurus should incorporate the useful engineering lessons through
  Osaurus-native mechanisms: WebKit safety, `browser_read`, deterministic eval
  evidence, local VLM vision, and later CDP attach to the user's own browser.
  Cloud browser or premium extraction backends remain optional plugin lanes,
  not the core plan.
- `browser_read` is the major user-visible capability jump after P0 safety. It
  lets agents read logged-in or JS-rendered pages without arbitrary
  `browser_execute_script` workarounds or session-losing `fetch_html` calls.
- CDP/Chrome attach is a later engine-breadth lane. It should not delay the
  WebKit safety and readable-page work.

## Current State

The browsing surface is split across three native plugin packages:

- `tools/browser`: WebKit browser automation with persistent per-agent sessions, login helper, element refs, screenshots, console/network inspection, dialogs, cookies, viewport, user-agent, locks, and reset.
- `tools/fetch`: HTTP fetch/download with initial SSRF guard, response size caps, redirects, and lightweight HTML extraction.
- `tools/search`: web/news/image search across paid and free providers plus `search_and_extract`.

GitHub state:

- `osaurus-tools` default branch is `master`.
- Open PR #162, from another author, adds a Keenable search backend and is currently behind `master`.
- Do not duplicate #162. Search work here avoids provider-table, secret-list, default-priority, and Keenable-specific changes unless explicitly helping that PR.
- Open issue #165 asks about a community web-backend plugin. This plan keeps first-party browsing local-first and leaves cloud/community extraction backends as optional later work.

Confirmed code findings:

- Browser navigation has no URL policy/SSRF guard. `browser_navigate`, click/form/script navigations, and `browser_open_login` can reach private/internal hosts.
- Fetch checks only the initial URL. Redirect targets are followed without a second SSRF check, and credential headers are not stripped on cross-origin redirects.
- `allow_private` in fetch currently bypasses scheme policy too early. `file:` can pass when private access is allowed.
- `search_and_extract` has its own URLSession extraction path and no SSRF/private-network guard.
- Native plugin outputs should not rely on central secret scrubbing. The host normalizes/caps tool results, but the native plugin path does not apply a universal scrubber.
- Browser snapshots can leak input values, cookies, console/network URLs, dialog text, and script results.
- Browser snapshots are interaction-oriented, not reading-oriented. They expose refs and small text excerpts, but no rendered-page content extraction.
- Browser snapshot filtering likely has a JS variable bug: the filter condition references `el` inside a `TreeWalker` callback where the current node is `node`.
- Host plugin API supports inference, but the browser plugin currently mirrors only config/log strongly. Any vision/task-aware compaction work needs explicit host API mirror expansion.
- Plugins do not have a documented arbitrary file-write host API. Durable state should use plugin SQLite, and large user-visible artifacts need a deliberate artifact path or cursor/pagination design.
- Current evals prove browser tool discovery, not end-to-end browsing. Browsing evals must explicitly bootstrap native plugins until the eval bootstrap mismatch is fixed.

Attached-plan confirmations:

- Browser plugin URL policy is the P0 security gap because fetch has partial
  SSRF protection but live WebKit navigation does not.
- Browser-readable page content is the highest capability ROI after security.
- Output budget/spill must use cursor pagination first unless a host-readable
  plugin artifact path is confirmed.
- CDP, browser vision, popups/downloads, PDF extraction, and session hygiene are
  valuable follow-up lanes, but they should not preempt P0 safety plus
  `browser_read`.

## Wave 0 Decisions

Wave 0 is mandatory before implementation. These are design decisions, not vague risks.

### Shared Security Code Mechanism

Decision target:

- Prefer a source target statically compiled into each plugin dylib, or a small script-synced vendored source file, over a separately packaged shared dylib.
- Do not place a plugin-like `Package.swift` under `tools/common`; release scripts treat `tools/*/Package.swift` as plugin packages.
- If a root-level Swift package is used, prove `scripts/build-tool.sh browser`, `scripts/build-tool.sh fetch`, and `scripts/build-tool.sh search` still produce one plugin dylib per tool and do not require shipping an extra shared dylib.

Acceptance checks:

- Package graph inspection shows no extra dynamic library artifact for shared security code.
- `scripts/build-tool.sh <tool> --version <test-version>` still stages one plugin dylib plus docs/assets.
- `scripts/regenerate-catalogs.py --check --tool <tool>` still works.
- If script-synced vendored sources are selected, add a drift check such as `scripts/check-websafety-sync.sh` and wire it into validation. Without a drift check, script-synced vendoring is rejected for security code.

### Browser Test Fixture Strategy

Problem:

- Existing browser tests use `file://` fixtures.
- New production URL policy must block `file:`.
- Browser security/eval tests need deterministic local pages, but loopback should be blocked in production by default.

Decision target:

- Use a production-inert test strategy. Acceptable options:
  - an injected policy resolver in tests, with no production environment-variable bypass;
  - a local HTTP fixture server only when a test-only policy context explicitly allows loopback;
  - `loadHTMLString` for unit-style DOM tests that do not exercise navigation policy.
- Do not add a production `file://` or loopback allowance just to make tests pass.

Acceptance checks:

- Production policy blocks `file:`, loopback, and private ranges by default.
- Tests can prove blocked production behavior and allowed fixture behavior separately.
- Any test-only bypass is unavailable in release/plugin runtime.

### Main App Worktree For Evals

The main Osaurus app checkout is dirty. Browsing eval work must use a fresh worktree, for example:

- `/Users/mmeding/Developer/Claude/Projects/osaurus-worktrees/browse-eval-evidence`

Acceptance checks:

- No edits are made in the dirty app root checkout.
- The eval PR records which `osaurus-tools` plugin build or source SHA it tested.

### Wave 0 Decision Artifact

Wave 0 must leave a committed or PR-local decision artifact before adoption PRs proceed. The artifact records:

- chosen shared-code mechanism;
- exact test fixture strategy;
- package/build proof commands and outcomes;
- cross-repo eval worktree path;
- whether the P0 wave uses unit/live WebKit tests only or waits for browsing evals.

## Execution Principles

- Ship meaningful functional PRs, not one-line slices.
- Start every new branch from fresh `origin/master`.
- Use one isolated worktree per independent lane.
- Keep branch scopes disjoint unless the controller intentionally serializes a shared dependency.
- Treat security, credential handling, cookies, browsing history, network targets, downloads, screenshots, and cross-origin redirects as security-sensitive.
- Do not claim browser functionality works from source inspection only. Require unit tests and, where feasible, live WebKit proof behind explicit local test gates.
- Do not mark a PR ready until local validation passes, GitHub checks are green, and merge state is clean.
- Keep public PR wording human-readable.

## PR 1: Add Shared Web Safety Core

Branch: `browse/web-safety-core`  
Priority: P0  
Parallelization: starts first; fetch/search/browser adoption branches rebase onto it.

Owned scope:

- Shared source location selected in Wave 0.
- Shared tests.
- Build/package scripts only if necessary to support static/shared source adoption.
- Documentation explaining the policy contract.

Feature:

- Add reusable URL policy, metadata-endpoint detection, credential URL detection, URL redaction, header redaction, cookie redaction, and output redaction helpers for first-party web tools.

Functional requirements:

- Accept only `http` and `https` for network requests.
- Allow `about:blank` only where explicitly needed by the browser login helper.
- Reject URL userinfo as `SECRET_IN_URL`.
- Treat credential-looking query strings as redaction targets by default, not necessarily hard request blockers, because signed cloud URLs are legitimate. Hard-block only clearly embedded secrets such as userinfo or raw secret tokens in unsafe contexts.
- Block private, loopback, link-local, multicast, reserved, `.local`, `.internal`, and cloud metadata endpoints by default.
- Metadata IPs and hostnames remain blocked even when private access is allowed, including common encodings of `169.254.169.254`.
- Validate scheme before any `allow_private` bypass.
- Re-run DNS and policy checks for every redirect or navigation decision.
- Define accepted residual risk for DNS rebinding if the implementation cannot pin resolved IPs through URLSession/WKWebView.
- Add a shared download path-jail validator so later fetch/browser download work does not duplicate path policy.
- Provide a safe GET helper or redirect-policy primitive that fetch and search extraction can share for redirect re-validation and byte limits.
- Provide stable error codes:
  - `SSRF_BLOCKED`
  - `SECRET_IN_URL`
  - `UNSAFE_SCHEME`

Tests:

- Public HTTPS allowed.
- `file:`, `data:`, and `javascript:` rejected even when private access is allowed.
- Localhost and RFC1918 blocked by default.
- Metadata IP/host blocked even when private access is allowed.
- URL userinfo rejected.
- Signed-cloud-style query strings are redacted in output without being automatically rejected.
- OAuth/token-bearing URL fragments are redacted.
- Percent-decoded secret prefixes are redacted or rejected per policy.
- IPv6 loopback/link-local/ULA rejected.
- Header redaction covers `Authorization`, `Cookie`, `Set-Cookie`, proxy auth, and common token headers.
- Download path validator rejects absolute paths, parent traversal, hidden/tilde paths, path separators, and paths outside the chosen download/artifact directory.

Validation:

- Shared tests.
- Package artifact proof from Wave 0.
- `git diff --check`.

## PR 2: Fix Browser Snapshot Filters And Test Harness Foundation

Branch: `browse/snapshot-filter-foundation`  
Priority: P0/P1  
Parallelization: can start immediately after Wave 0 decisions; keep max one open browser PR at a time unless `Plugin.swift` is split.

Owned scope:

- `tools/browser/Sources/OsaurusBrowser/Plugin.swift`
- `tools/browser/Tests/OsaurusBrowserTests/*`
- test fixtures/helpers only as required by the production-inert fixture strategy.

Feature:

- Fix the confirmed snapshot filter bug and establish browser test helper patterns needed by later security work.

Functional requirements:

- `inputs`, `buttons`, `links`, and `forms` filters operate on the current DOM node.
- Add regression tests that fail under the old JS.
- Keep output format compatible.
- Add or document test helpers for production-blocked navigation versus fixture-allowed navigation, without adding any production runtime bypass.

Tests:

- Filter fixtures for each filter mode.
- Hidden elements remain excluded when `visible_only=true`.
- Test-harness helper proves production policy and fixture policy are separate when policy code is present.

Validation:

- `swift test --package-path tools/browser`
- `git diff --check`

## PR 3: Harden Fetch Redirects And Outputs

Branch: `browse/fetch-url-safety`  
Priority: P0  
Parallelization: depends on PR 1; can run independently of browser once PR 1 lands or is stable.

Owned scope:

- `tools/fetch/Package.swift`
- `tools/fetch/Sources/OsaurusFetch/Plugin.swift`
- `tools/fetch/Tests/OsaurusFetchTests/*`
- `tools/fetch/SKILL.md`
- `tools/fetch/CHANGELOG.md`

Feature:

- Adopt shared web safety in `osaurus.fetch`.
- Close redirect SSRF and credential-forwarding gaps.
- Redact sensitive response fields.

Functional requirements:

- Initial URL uses shared policy.
- Every redirect target re-runs policy before following.
- Redirect header stripping is based on scheme, host, and port.
- Strip sensitive headers on cross-origin redirects and on HTTPS-to-HTTP downgrade.
- Preserve `allow_private` only for documented trusted local/private use, never for unsafe schemes or metadata endpoints.
- Redact:
  - `final_url`
  - `redirect_chain`
  - sensitive response headers
  - credential-like URLs in body snippets where feasible
- Add warnings when redaction occurs.

Tests:

- Redirect to private host blocked.
- Redirect to metadata endpoint blocked even with private access allowed.
- Cross-origin redirect strips auth/cookie headers.
- HTTPS-to-HTTP redirect strips auth/cookie headers.
- `file:` rejected with private access allowed.
- Sensitive headers redacted.
- Token query strings redacted in final URL and redirect chain.

Validation:

- `swift test --package-path tools/fetch`
- `python3 scripts/validate.py` if manifest/catalog changes.
- `scripts/regenerate-catalogs.py --check --tool fetch`
- `git diff --check`

## PR 4: Harden Search Extraction Safety

Branch: `browse/search-extraction-safety`  
Priority: P0  
Parallelization: depends on PR 1; avoids PR #162 provider backend files where possible.

Owned scope:

- `tools/search/Package.swift`
- `tools/search/Sources/OsaurusSearch/Plugin.swift`
- `tools/search/Tests/OsaurusSearchTests/*`
- `tools/search/SKILL.md`
- `tools/search/CHANGELOG.md`

Feature:

- Put `search_and_extract` inside the same URL safety perimeter as fetch and browser.

Functional requirements:

- Apply shared URL policy to every extracted search result URL.
- Re-validate every extraction redirect target.
- Apply the shared response byte cap / safe GET primitive rather than unbounded `URLSession.shared`.
- Add a `max_bytes` cap or equivalent extraction size cap.
- Preserve provider selection, provider priority, and Keenable PR #162 scope.
- Report per-result skipped/error states for blocked or unsupported extraction targets.
- Do not silently treat PDFs/binary pages as failed HTML; return typed skipped/unsupported states until PDF extraction lands.
- Redact credential-like URLs in result/extraction outputs.

Tests:

- `search_and_extract` blocks private/internal result URLs.
- `search_and_extract` blocks metadata endpoints.
- Signed URL query parameters are redacted in output.
- Binary/PDF-like result is skipped with explicit unsupported state.
- Provider priority and valid-provider sets do not change.

PR #162 conflict handling:

- PR #162 edits the same search implementation and changelog files. If #162 is still open when this lane starts, keep this PR draft until rebased on top of #162 or explicitly state that the branch will offer the #162 author a rebase. Do not silently compete for the same version/changelog entry.

Validation:

- `swift test --package-path tools/search`
- `python3 scripts/validate.py` if manifest/catalog changes.
- `scripts/regenerate-catalogs.py --check --tool search`
- `git diff --check`

## PR 5: Harden Browser Navigation Policy

Branch: `browse/browser-navigation-safety`  
Priority: P0  
Parallelization: depends on PR 1; serialize before browser output/readability PRs that touch the same monolithic plugin file.

Owned scope:

- `tools/browser/Package.swift`
- `tools/browser/Sources/OsaurusBrowser/Plugin.swift`
- `tools/browser/Sources/OsaurusBrowser/LoginWindow.swift`
- `tools/browser/Tests/OsaurusBrowserTests/*`
- `tools/browser/SKILL.md`
- `tools/browser/CHANGELOG.md`

Feature:

- Adopt shared web safety in the WebKit browser plugin.
- Block unsafe main-frame browser navigation before loading and during redirects/script-driven navigation.

Functional requirements:

- Validate direct `browser_navigate`.
- Validate `browser_open_login` initial URL and helper-window address-bar loads.
- Add `WKNavigationDelegate.decidePolicyFor` checks for every main-frame navigation.
- Validate iframe navigations as well as top-level navigations where WebKit exposes them.
- Add a mandatory minimum `WKContentRuleList` or equivalent blocking layer for literal metadata, loopback, RFC1918, link-local, and private-range subresource URLs when WebKit supports it.
- Document residual risk for DNS-named internal subresources if the implementation cannot resolve them before load.
- Record last blocked navigation and surface it in subsequent snapshots.
- Preserve `about:blank` only for login helper blank start.
- Keep local/private navigation opt-in and explicit; never allow metadata endpoints.
- Define browser private-access opt-in precisely:
  - per-call parameter, session setting, or both;
  - inheritance rule for redirects and script-driven navigation after an allowed private navigation;
  - user-facing error hint when local/private browsing is blocked by default.

Tests:

- Unsafe direct navigation returns typed failure.
- Script-driven `location.href` to private host is blocked.
- Redirect/meta-refresh private target is blocked where testable.
- Literal private subresource request is blocked or appears in an explicit residual-risk test if WebKit cannot enforce it.
- Login helper rejects unsafe initial URL.
- Test fixture strategy from Wave 0 is used without production bypass.
- Optional live WebKit proof.

Validation:

- `swift test --package-path tools/browser`
- Optional live WebKit test command where supported.
- `python3 scripts/validate.py` if manifest/catalog changes.
- `scripts/regenerate-catalogs.py --check --tool browser`
- `git diff --check`

## PR 6: Redact Browser Outputs And Guard Credential Entry

Branch: `browse/browser-output-redaction`  
Priority: P0/P1  
Parallelization: depends on PR 1 and should serialize after PR 4 unless `Plugin.swift` is split.

Owned scope:

- `tools/browser/Sources/OsaurusBrowser/Plugin.swift`
- `tools/browser/Tests/OsaurusBrowserTests/*`
- `tools/browser/SKILL.md`
- `tools/browser/CHANGELOG.md`

Feature:

- Prevent browser tool outputs from leaking secrets into the agent context.

Functional requirements:

- Redact password and credential field values in snapshots.
- Add reusable internal browser sanitizer APIs so `browser_read` can reuse exactly the same redaction path later.
- Redact cookie values from `browser_cookies get`.
- Redact console messages, network request URLs, dialog text, script results, final login URLs, and snapshot URLs where credential-like values appear.
- Headless `browser_type` and `browser_do` reject typing into password fields and return a login-helper hint.
- `browser_execute_script` result redaction is best-effort and clearly documented.
- Screenshot output remains a file path; do not claim pixel-level redaction. Add guidance that screenshots can contain visible page secrets.

Tests:

- Password input value does not appear in formatted snapshots.
- Cookie values are redacted.
- Console/network buffers redact token-bearing URLs.
- Dialog text redaction works.
- Script result redaction works for representative token strings.
- Typing into password fields returns a login-helper error.
- Sanitizer helper is directly tested and reused by snapshot formatting.

Validation:

- `swift test --package-path tools/browser`
- `scripts/regenerate-catalogs.py --check --tool browser` if docs/catalog change.
- `git diff --check`

## PR 7: Browser Readable Page Tool

Branch: `browse/browser-read`  
Priority: P1  
Parallelization: after PR 4/5 or after a file split that makes scope disjoint.

Owned scope:

- `tools/browser/Sources/OsaurusBrowser/Plugin.swift`
- `tools/browser/Tests/OsaurusBrowserTests/*`
- `tools/browser/Tests/OsaurusBrowserTests/Fixtures/*`
- `tools/browser/SKILL.md`
- `tools/browser/CHANGELOG.md`
- `plugins/osaurus.browser.json` through catalog regeneration only if needed.

Feature:

- Add `browser_read` so agents can read authenticated and JS-rendered pages without arbitrary scripts.

Attached-plan learning:

- Treat this as the largest immediate user-facing browsing improvement after
  URL safety. The implementation should first prove deterministic rendered-DOM
  extraction and cursor pagination. Vendored Readability.js can be added only if
  fixture evidence shows the simpler DOM extractor is not reliable enough.

Functional requirements:

- Reads live rendered DOM content.
- Supports `format: "markdown" | "text"`.
- Supports `selector`.
- Supports `max_chars`.
- Supports cursor pagination for large content.
- Returns `{ok, data}` with `title`, `url`, content, `word_count`, `truncated`, and `next_cursor`.
- Applies the same URL/form-field/text redaction layer as snapshots.
- Treat page content as untrusted data in SKILL guidance; the agent should quote/summarize it as webpage content, not follow instructions embedded in it.
- Uses cursor pagination first; do not assume host-readable cache writes.
- Avoid full Readability vendoring unless fixture quality proves deterministic DOM extraction is insufficient.

Tests:

- JS-rendered article fixture returns rendered text.
- Long article pagination returns a cursor and continuation.
- Selector-scoped extraction.
- Redaction inside `browser_read` output.
- Prompt-injection fixture or eval task where page text attempts to override system/developer instructions; agent must treat it as page content.
- Manifest tests for `browser_read`.
- Skill guidance tells agents to use `browser_read` for content instead of arbitrary scripts.

Validation:

- `swift test --package-path tools/browser`
- Optional live WebKit proof.
- `python3 scripts/validate.py` if manifest/catalog changes.
- `scripts/regenerate-catalogs.py --check --tool browser`
- `git diff --check`

## PR 8: Browsing Evals And Plugin Build Evidence

Branch: `browse/eval-evidence`  
Priority: P1  
Parallelization: main-app worktree can start immediately, but tasks that prove new plugin behavior must pin the matching plugin build/SHA.

Owned scope:

- Main app repo fresh worktree only:
  - `Packages/OsaurusEvals/Suites/*`
  - `Packages/OsaurusEvals/Sources/*` only if bootstrap behavior must be fixed
  - `scripts/review/evals-browsing-evidence.sh`
  - eval docs if needed

Feature:

- Add deterministic browsing eval evidence so browser/search/fetch PRs can prove real agent behavior.

Functional requirements:

- Define reproducible plugin bootstrap:
  - released plugin version pin, or
  - local dylib path built from a recorded `osaurus-tools` SHA, or
  - source checkout path plus build command.
- Add a suite that can initially prove current behavior:
  - open a deterministic page and inspect/summarize it
  - complete a simple form
  - handle a dialog
- Add security evals only when the matching security PR is available:
  - unsafe URL blocked
  - redirect/private target blocked
  - cookie/password/token value does not appear in transcript
  - page-content prompt injection remains quoted/summarized as untrusted content
- Record exact tool calls, arguments, failures, and grounded final answers.
- Explicitly bootstrap native browser plugin until automatic bootstrap is fixed.
- Use a browsing-specific evidence script name so it cannot be confused with
  broader local/frontier PR eval evidence workflows.
- The current helper starts a loopback fixture server. Future browser URL
  policy adoption must keep that allowance eval-only and continue blocking
  loopback in production by default.

Tests:

- Eval suite fixture schema tests.
- Runner smoke test if bootstrap changes.
- `swift test --package-path Packages/OsaurusEvals` in the main app worktree.

Validation:

- Main app worktree only:
  - `swift test --package-path Packages/OsaurusEvals`
  - focused eval evidence CLI with explicit plugin bootstrap
- `git diff --check`

Risks:

- This is cross-repo. It should not block P0 code fixes, but it should become the evidence gate for later browser tool/schema changes.
- P0 security PRs may merge on unit tests plus live WebKit proof where available. The security milestone is not complete until PR 8 or a fast-follow eval slice proves SSRF/redaction behavior against pinned plugin builds.

## PR 9: Fetch PDF And Download Extraction

Branch: `browse/fetch-pdf-extraction`  
Priority: P1/P2  
Parallelization: after PR 2; serialize after search/fetch extraction safety if both touch fetch internals.

Owned scope:

- `tools/fetch/Sources/OsaurusFetch/Plugin.swift`
- `tools/fetch/Tests/OsaurusFetchTests/*`
- `tools/fetch/SKILL.md`
- `tools/fetch/CHANGELOG.md`

Feature:

- Make PDF and non-HTML fetch behavior explicit and useful.

Functional requirements:

- Detect PDF by content type and/or magic bytes.
- Add either:
  - `fetch_pdf` with PDFKit extraction, or
  - `fetch_html` typed `UNSUPPORTED_CONTENT_TYPE` with a clear `download` hint if PDFKit extraction is not reliable.
- Preserve `download` path jail.
- Reuse shared download path validator if one is introduced; do not reimplement independently for browser downloads later.
- Include final URL, byte count, truncation, and extraction warnings.

Tests:

- Minimal PDF fixture.
- PDF text extraction or explicit unsupported response.
- Binary non-PDF content returns typed unsupported.
- Download target remains jailed under `~/Downloads`.

Validation:

- `swift test --package-path tools/fetch`
- `python3 scripts/validate.py` if manifest/catalog changes.
- `scripts/regenerate-catalogs.py --check --tool fetch`
- `git diff --check`

## PR 10: Browser Popups, Downloads, And Session Hygiene

Branch: `browse/browser-robustness`  
Priority: P2  
Parallelization: after PR 4/5/7, unless a preliminary file split makes scopes disjoint.

Owned scope:

- `tools/browser/Sources/OsaurusBrowser/Plugin.swift`
- `tools/browser/Sources/OsaurusBrowser/SessionManager.swift`
- `tools/browser/Sources/OsaurusBrowser/LoginWindow.swift`
- `tools/browser/Tests/OsaurusBrowserTests/*`
- browser docs/changelog.

Feature:

- Improve browser reliability on real sites that open new windows, download files, or keep sessions alive too long.

Functional requirements:

- Implement `WKUIDelegate.createWebViewWith` handling.
- Default policy: same-view navigation for `target=_blank`, with a clear snapshot note.
- Add tab list only if same-view behavior is insufficient.
- Add browser download handling via `WKDownloadDelegate` where available.
- Save downloads through the same path-jail policy as fetch.
- Apply shared URL policy to download-triggering navigations and `WKDownload` URLs before saving.
- Add idle session eviction with configurable timeout.
- Clear `LoginWindow` associated-object retention after close to avoid leaks.

Tests:

- `target=_blank` fixture no longer no-ops.
- Download fixture saves under allowed directory or returns typed unsupported.
- Session idle eviction invalidates refs with clear error/hint.
- Login window retention cleanup unit proof where possible.

Validation:

- `swift test --package-path tools/browser`
- Optional live WebKit proof.
- catalog check for browser if manifest changes
- `git diff --check`

## Deferred Lanes

These remain valuable but should not distract from P0 safety and readability:

- Browser vision and visual grounding.
- CDP client foundation.
- Chrome/Brave/Edge attach engine. This should connect to the user's own
  locally launched or debug-port browser to improve engine breadth and
  site-compatibility while staying local-first, not as an external hosted
  browsing dependency.
- Browser vision and annotated screenshot grounding. Reuse host inference/local
  VLM support only after the exact plugin host inference API is confirmed.
- Search diagnostics and optional extract backend extension point.

## Open Questions From Attached Plan

- Confirm the exact plugin host inference API before task-aware compaction or
  `browser_vision`.
- Confirm whether native plugins can write host-readable artifacts under
  `~/.osaurus/cache` before choosing spill-to-disk over cursor pagination.
- Confirm whether the main app centrally scrubs native plugin output envelopes.
  Until proven, browser/fetch/search must scrub before returning tool results.
- Confirm packaging behavior for each adoption PR: shared safety must remain
  statically linked into each tool dylib and must not introduce an extra shared
  runtime dylib.

Each deferred lane should become its own feature plan after the first ten PRs are either merged or intentionally deferred.

## Parallelization Matrix

Can start immediately:

- PR 1 shared web safety core.
- PR 2 snapshot filter/test harness foundation, if controller keeps only one browser PR open at a time.
- PR 8 eval harness work in a fresh main-app worktree, limited to bootstrap scaffolding and current-behavior tasks.

Starts after PR 1:

- PR 3 fetch URL safety.
- PR 4 search extraction safety.
- PR 5 browser navigation safety.

Browser lanes that should serialize unless the monolithic browser file is split:

- PR 2 snapshot filter/test harness foundation.
- PR 5 browser navigation safety.
- PR 6 browser output redaction.
- PR 7 browser read.
- PR 10 robustness.

Fetch/search lanes:

- PR 3 and PR 4 can run in parallel after PR 1 because they own different tool packages, subject to PR #162 conflict handling for search.
- PR 9 should serialize after PR 3 and after any fetch-touching part of PR 4.

Must remain serialized:

- Shared security helper changes.
- Browser manifest/SKILL/catalog updates.
- Search provider-table edits because of PR #162.
- Main-app eval bootstrap changes in the fresh main-app worktree.

## Review And Validation Gates

Every PR:

- Local focused tests.
- `git diff --check`.
- Relevant catalog check.
- `python3 scripts/validate.py` when manifests/catalogs change.
- Human-readable PR body with scope, tests, security/eval evidence, and known risks.

Security-sensitive PRs:

- Explicit redaction tests.
- Unsafe-target negative tests.
- No credential leakage in output fixtures.
- No hidden bypasses for `allow_private`.
- Explicit breaking-change note when `allow_private` semantics change.
- Explicit migration note when default private/loopback blocking changes local-first workflows.

Browser behavior PRs:

- Browser unit tests.
- Live WebKit smoke when the environment supports it.
- Browsing eval evidence once PR 8 exists.

Agent-loop or tool-schema PRs:

- Browsing eval evidence with plugin bootstrap.
- Local/frontier eval evidence only where model behavior or agent-loop behavior changes.

Second-opinion review:

- Run a high-effort external plan review before execution.
- Run code review after final diffs and local validation.
- If external reviewers are unavailable, record unavailability and continue with implementation and local validation.
- For P0 security PRs, second-opinion review is required unless the service is unavailable after retry; if unavailable, the PR must say local tests and maintainer review cover the gate.

## First Execution Slice

Start with PR 1, PR 2, and PR 8 scaffolding in parallel:

- PR 1 makes shared policy/redaction decisions reviewable before tool adoption.
- PR 2 fixes a confirmed browser bug and prepares the test harness needed by browser security work.
- PR 8 can prepare plugin bootstrap and current-behavior browsing tasks without depending on new plugin behavior.

After PR 1 stabilizes, run PR 3 and PR 4 in parallel. Then serialize browser PRs through PR 5, PR 6, and PR 7 unless a file split removes overlap.
