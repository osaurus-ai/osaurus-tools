# Retired Plugin Migration

Browser, Fetch, Messages, and Telegram are no longer distributed through this
registry as of August 6, 2026. Their signed GitHub releases remain unchanged so
installed legacy copies and direct release URLs continue to work.

Upgrade Osaurus to a release containing the replacement capability before
uninstalling a legacy plugin.

## Replacement mapping

- Browser automation moves to the core app's host-managed browser and Computer
  Use capabilities. Use those surfaces for navigation, interaction,
  screenshots, authentication, and UI automation.
- HTTP fetching moves to the core app's native web retrieval and host-managed
  HTTP capabilities. Plugin authors should use the v2 host HTTP client instead
  of depending on a separate fetch plugin.
- Messages moves to the core app's Messages integration.
- Telegram moves to the core app's Connections and Telegram transport.

## What changes

- Fresh installs by the retired plugin IDs are no longer available from the
  registry.
- Existing installed dylibs are not removed automatically.
- Historical tags, archives, checksums, and minisign signatures are preserved.
- Agents and skills should reference the core capability rather than the
  retired plugin-specific tool names.

After confirming the replacement works, remove the legacy plugin through the
Osaurus management UI. If a workflow still depends on an old tool name, update
that workflow before uninstalling.
