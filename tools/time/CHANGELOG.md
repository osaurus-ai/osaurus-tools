# Changelog — osaurus.time

## 2.0.0

### Added

- `parse_date` — turn ISO 8601 / RFC 2822 / `yyyy-MM-dd` / numeric strings into a Unix timestamp + ISO 8601 in any IANA zone.
- `convert_timezone` — re-express an instant in a different IANA timezone.
- `add_duration` — add (or subtract) an ISO 8601 duration like `P1DT2H` or a raw `seconds` value.
- `diff_dates` — compute the difference between two dates as seconds, ISO 8601 duration, and a human summary.
- `list_timezones` — return all IANA timezone identifiers (optionally prefix-filtered) for grounding agents.

### Changed

- **Breaking**: every tool now returns the standard envelope:

  ```json
  { "ok": true, "data": { ... } }
  { "ok": false, "error": { "code": "...", "message": "...", "hint": "..." } }
  ```

  Previously tools returned ad-hoc JSON shapes like `{"datetime": "...", ...}`.

- `format_date` finally accepts the `date` string parameter its description always claimed (in addition to `timestamp`).
- `format_date` `relative` mode now defaults to `en_US_POSIX` locale for stable English output. Override via `locale: "en_US"` etc.
- `format_date` adds `unix` and `date` format aliases.
- Plugin display name dropped the `"Osaurus "` prefix; authors set to `["Osaurus Team"]`.

### Fixed

- Bad timezone IDs and unparseable date strings now return structured `INVALID_ARGS` errors with hints instead of silently falling back to `TimeZone.current` or `Date()`.
- Decoding errors on malformed payloads surface the underlying parser message.

### Notes on signing

Any plugin version signed before the November 2025 minisign rotation is unverifiable. Reinstalling from the registry pulls the currently-signed `2.0.0` build.
