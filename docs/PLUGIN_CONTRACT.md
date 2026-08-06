# Plugin Contract

This document is the registry and release-gate contract for Osaurus plugins.
The host authoring guide remains authoritative for the ABI and runtime
callbacks.

## Runtime response envelope

Every tool returns one of the host's canonical JSON envelopes. Do not return a
raw payload and depend on host auto-wrapping.

Success:

```json
{
  "ok": true,
  "tool": "example_tool",
  "result": {},
  "warnings": []
}
```

`tool` and `warnings` are optional. `result` may be any JSON value.

Failure:

```json
{
  "ok": false,
  "kind": "invalid_args",
  "message": "The limit must be positive.",
  "field": "limit",
  "expected": "integer greater than zero",
  "tool": "example_tool",
  "retryable": true,
  "data": { "code": "INVALID_LIMIT" }
}
```

`field`, `expected`, `tool`, and `data` are optional. `retryable` is required.
Supported failure kinds and defaults are:

- `invalid_args` (`true`)
- `rejected` (`false`)
- `user_denied` (`false`)
- `timeout` (`true`)
- `execution_error` (`true`)
- `not_found` (`false`)
- `unavailable` (`true`)
- `tool_not_found` (`false`)

Use stable `data.code` values for programmatic distinctions within a kind.

## Dylib manifest

`get_manifest()` is the runtime source of truth. A release manifest must have a
lowercase dot-separated `plugin_id`, a semantic `version` matching the release
tag, a non-empty `description`, and a `capabilities` object.

Each `capabilities.tools` entry supports exactly these fields:

- `id`: unique, non-empty snake_case identifier
- `description`: non-empty behavior description
- `parameters`: JSON Schema object
- `requirements`: unique array of host permission identifiers
- `permission_policy`: `ask`, `auto`, or `deny`

Do not add `annotations` or `outputSchema`. The current host plugin decoder
does not expose them.

Every parameters schema must have `type: "object"`, an explicit `properties`
object, an explicit `required` array, and `additionalProperties: false`.
Required names must exist in `properties`. Add enums, defaults, bounds, and
conditional requirements whenever the implementation enforces them. Use
snake_case field names and stable opaque identifiers.

Supported system requirements are `automation`, `accessibility`,
`automation_calendar`, `automation_mail`, `calendar`, `contacts`, `location`,
`maps`, `microphone`, `notes`, `reminders`, `screen_recording`, and `disk`.
Plugins may also use non-empty custom requirement identifiers for
plugin-specific grants.

Use `auto` only for read-only discovery and process-local edits. Use `ask` for
sends, filesystem writes, app or UI activation, and persistent external
mutations. `deny` disables the tool by default.

`capabilities.routes` entries use `id`, `path`, `methods`, `description`, and
`auth`. IDs are unique snake_case, paths begin with `/`, methods are uppercase,
descriptions are non-empty, and auth is `none`, `verify`, or `owner`.

The other supported capability declarations are `config`, `web`, and the
boolean `artifact_handler`. Top-level `instructions`, `secrets`, and `docs`
follow the host authoring guide.

## Registry projection

The registry catalog is a distribution index, not a second runtime manifest.
The reusable release workflow projects:

- manifest tool `id` to catalog tool `name`
- manifest route `id` to catalog route `name`
- non-empty descriptions for tools, routes, and skills
- release URLs, checksums, signatures, compatibility, and documentation

Runtime-only tool fields (`parameters`, `requirements`, and
`permission_policy`) stay in the dylib manifest. Catalog tools may retain
registry presentation fields such as `widget` and `defaultRender`.

## Plugin skills

A plugin may package one root `SKILL.md`. It must start with YAML frontmatter
containing non-empty scalar `name` and `description` values. The description
should begin with user intent such as “Use when…”. Keep instructions focused on
routing, safe sequencing, ambiguity, limitations, and result interpretation;
do not duplicate parameter schemas.

The registry embeds the complete file as the top-level `skill` string. Its
frontmatter `name` and `description` must match exactly one
`capabilities.skills` entry. Skill names are unique. Catalogs with no skill may
omit `skill` and may use an absent, empty, or legacy `null`
`capabilities.skills` value.

## Release gates

Before signing an artifact, the reusable workflow runs
`scripts/manifest_lint.py` against the extracted manifest and tag-derived
version. Registry pull requests run `scripts/validate.py`, including catalog
skill alignment, and verify artifact checksums and minisign signatures in CI.
