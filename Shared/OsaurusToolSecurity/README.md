# OsaurusToolSecurity

Shared Swift security primitives for first-party web-capable tools. The package
lives under `Shared/` instead of `tools/` so release scripts do not mistake it
for a standalone plugin package. The library product is static, so later
browser, fetch, and search adoption can compile the code into each plugin dylib
without shipping an extra shared dynamic library.

## Policy Contract

`URLPolicy` is the canonical network URL gate for browser, fetch, and search
adoption work.

- `http` and `https` are the only network schemes accepted.
- `about:blank` is accepted only when the caller opts in for browser flows that
  explicitly need it.
- URL userinfo is rejected with `SECRET_IN_URL`.
- Unsafe schemes are rejected with `UNSAFE_SCHEME` before any private-network
  allowance is considered.
- Loopback, private, link-local, multicast, reserved, `.local`, and `.internal`
  hosts are rejected by default with `SSRF_BLOCKED`.
- Cloud metadata hostnames and metadata IPs are rejected even when
  `allowPrivateNetwork` is enabled.
- Host checks cover canonical IPv4, common non-dotted IPv4 forms, IPv6
  loopback/link-local/ULA ranges, IPv4-mapped IPv6, the well-known NAT64
  prefix, 6to4, and Teredo embedded IPv4 forms.
- DNS results are checked through an injectable resolver. Tests use a stub
  resolver; production callers use `SystemHostResolver`. Hostname resolution
  fails closed when no addresses are available for validation.
- `resolveHostnames` defaults to `true`. Disabling it is for deterministic
  tests only; production network paths must leave DNS validation enabled or a
  public-looking hostname can resolve to a private or metadata address after
  policy approval.
- Redirects must call `RedirectPolicy.evaluate(...)` for every hop. The helper
  re-runs the full URL policy and strips sensitive headers across origins or
  HTTPS-to-HTTP downgrades.

Signed cloud URLs are valid request targets, so credential-looking query
strings are redacted in output by default rather than automatically blocked.

Stable URL policy error codes:

- `SSRF_BLOCKED`
- `SECRET_IN_URL`
- `UNSAFE_SCHEME`

## Redaction Contract

`WebSafetyRedactor` provides:

- URL userinfo and credential-query redaction.
- Header redaction for `Authorization`, `Cookie`, `Set-Cookie`,
  `Proxy-Authorization`, API key, token, secret, and credential-like headers.
- Cookie value redaction that preserves non-secret attributes.
- Text redaction for embedded credential URLs, auth header lines, bearer/basic
  tokens, and common key/value secret pairs.

Native plugins should redact their own outputs before returning tool results;
they should not rely on a host-level scrubber.

## Download Path Jail

`DownloadPathValidator` resolves plain filenames under a caller-provided
download or artifact directory. It rejects absolute paths, parent traversal,
hidden names, tilde-prefixed names, path separators, and existing symlink
targets that escape the base directory.

## Residual DNS Risk

The policy resolves and checks hostnames before allowing a request, fails closed
when a hostname cannot be resolved for validation, and redirect targets must be
re-validated. URLSession and WKWebView adoption cannot fully pin the vetted
address to the eventual connection without deeper transport control, so DNS
rebinding between validation and connection remains a known residual risk.
Adoption PRs should document that risk unless the specific transport path can
prove IP pinning. Adoption PRs should also re-check URL parsing against the
transport they call, because URL parser differences can create the same kind of
validate/connect gap.

## Validation

Run:

```bash
swift test --package-path Shared/OsaurusToolSecurity
swift package describe --package-path Shared/OsaurusToolSecurity --type json
git diff --check
```

Tool build scripts still discover plugin packages exclusively under `tools/*`.
When browser, fetch, and search later depend on this package, package artifact
proof should confirm each tool still stages one plugin dylib and no extra shared
dylib.
