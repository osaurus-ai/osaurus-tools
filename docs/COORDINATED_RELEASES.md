# Coordinated Plugin Releases

Use this runbook when a host contract change requires major releases across
multiple plugin repositories.

## Prepare

1. Land and tag the compatible plugin SDK before updating plugins.
2. Land host support and record the minimum compatible Osaurus version.
3. Land registry lint, validation, and reusable-workflow changes before any
   plugin release uses the new contract.
4. Give each plugin a migration note covering renamed or removed tools,
   response-envelope changes, and the required host version.

Do not publish a plugin whose contract depends on unreleased host behavior.
Do not add manifest fields that the current host does not decode.

## Gate each plugin

Before tagging:

- pin the intended SDK version
- set the manifest and package version to the coordinated major version
- set the minimum Osaurus version to the compatible host release
- run the repository's release build and full unit test suite
- test exact tool inventory, closed schemas, permission policies, canonical
  response envelopes, output limits, and skill metadata
- extract the built dylib manifest and run the same manifest lint used by the
  reusable release workflow

After tagging, the reusable workflow must finish tests, manifest lint, code
signing, minisign signing, and release creation before opening a registry pull
request.

## Accept registry updates

Treat each generated registry pull request independently:

1. Confirm the release URL points to the expected repository and tag.
2. Confirm the catalog tool and route projections match the extracted manifest.
3. Confirm `requires.osaurus_min_version` matches the coordinated host floor.
4. Run script unit tests and the full registry validator with signature
   verification.
5. Review breaking changes and migration notes before merging.

Merge in small batches. A plugin becomes discoverable as soon as its catalog
update lands, so do not merge before its host prerequisite is available.

## Rollback

Signed GitHub releases are immutable historical artifacts and must not be
deleted during a registry rollback.

- If a catalog update is wrong but its artifact is sound, revert the catalog
  commit or add a corrected release entry.
- If a new artifact is broken, remove that version from registry discovery and
  publish a new signed patch release. Do not replace assets under an existing
  tag.
- If the host rollout must be reversed, restore the previous catalog versions
  and compatibility floor before reverting host behavior.
- If a plugin is permanently retired, delete its catalog file only. Existing
  installations and direct signed release URLs remain available.

Record the rollback and user action in the registry changelog. Users should
upgrade the host before uninstalling a legacy plugin whose replacement moved
into the core app.
