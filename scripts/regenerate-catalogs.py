#!/usr/bin/env python3
# Regenerate plugins/<plugin_id>.json catalog entries from the embedded
# get_manifest() JSON literal in each tool's Plugin.swift.
#
# The catalog files in `plugins/` are the Osaurus plugin registry. They mix
# two concerns:
#
#   * Discovery metadata (name, description, authors, capabilities) — must
#     stay in sync with what the dylib actually advertises via
#     `osaurus_plugin_entry`.
#   * Distribution metadata (homepage, license, versions[], public_keys,
#     docs, skill) — owned by the registry and must NOT be derived from
#     the dylib.
#
# This script reads tools/<tool>/Sources/*/Plugin.swift, extracts the
# `let manifest = ...` triple-quoted JSON literal, parses it, and writes
# the discovery fields back into plugins/osaurus.<id>.json while
# preserving all distribution-only fields exactly as they were.
#
# Usage:
#   scripts/regenerate-catalogs.py            # Rewrite all catalog files
#   scripts/regenerate-catalogs.py --check    # Exit 1 if any catalog is
#                                             # out-of-sync (CI mode)
#   scripts/regenerate-catalogs.py --tool time
#                                             # Limit to a single tool
#
# Exit codes:
#   0  All catalogs in sync (or successfully rewritten).
#   1  --check mode and at least one catalog drifted from its source.
#   2  Setup error (missing file, malformed manifest, etc.).

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from typing import Any

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOOLS_DIR = os.path.join(REPO_ROOT, "tools")
PLUGINS_DIR = os.path.join(REPO_ROOT, "plugins")

# Discovery fields are copied from the dylib manifest into the catalog.
# Any field NOT in this set is considered registry-owned and preserved.
DISCOVERY_FIELDS = (
    "name",
    "description",
    "authors",
    "license",
    "min_macos",
    "min_osaurus",
    "capabilities",
    "secrets",
)

# Pattern for the embedded Swift triple-quoted string holding the manifest
# JSON. Greedy until the next standalone closing """ on its own line.
_MANIFEST_LITERAL_RE = re.compile(
    r'let\s+manifest\s*=\s*"""\s*\n(?P<body>.*?)\n\s*"""',
    re.DOTALL,
)


def _find_plugin_swift(tool_name: str) -> str | None:
    """Locate the Plugin.swift file for a given tool directory name."""
    sources = os.path.join(TOOLS_DIR, tool_name, "Sources")
    if not os.path.isdir(sources):
        return None
    for dirpath, _, filenames in os.walk(sources):
        if "Plugin.swift" in filenames:
            return os.path.join(dirpath, "Plugin.swift")
    return None


def _extract_manifest_json(plugin_swift_path: str) -> dict[str, Any]:
    """Parse the JSON literal returned by get_manifest()."""
    with open(plugin_swift_path, "r", encoding="utf-8") as f:
        source = f.read()

    match = _MANIFEST_LITERAL_RE.search(source)
    if not match:
        raise ValueError(
            f"Could not find `let manifest = \"\"\" ... \"\"\"` in {plugin_swift_path}"
        )
    return json.loads(match.group("body"))


def _catalog_path(plugin_id: str) -> str:
    return os.path.join(PLUGINS_DIR, f"{plugin_id}.json")


def _merge_into_catalog(
    catalog: dict[str, Any], manifest: dict[str, Any]
) -> dict[str, Any]:
    """Return a new catalog dict with discovery fields overwritten from manifest."""
    out = dict(catalog)

    # plugin_id is part of both — manifest must agree with catalog.
    manifest_id = manifest.get("plugin_id")
    catalog_id = catalog.get("plugin_id")
    if manifest_id and catalog_id and manifest_id != catalog_id:
        raise ValueError(
            f"plugin_id mismatch: manifest says {manifest_id!r}, "
            f"catalog says {catalog_id!r}"
        )

    for field in DISCOVERY_FIELDS:
        if field in manifest:
            out[field] = manifest[field]
        else:
            # Drop discovery fields that the manifest no longer declares
            # (e.g. a removed `secrets` block).
            out.pop(field, None)

    return out


def _strip_tool_parameters(catalog_tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """
    The registry catalog historically only carried tool {name, description}.
    The full parameters schema lives in the dylib manifest. We surface the
    description in the catalog (so the registry browser shows it) but keep
    parameter schemas off-disk to avoid maintaining two copies.
    """
    out = []
    for t in catalog_tools:
        # Manifest uses "id"; catalog uses "name". Translate.
        name = t.get("id") or t.get("name")
        entry: dict[str, Any] = {"name": name}
        if "description" in t:
            entry["description"] = t["description"]
        out.append(entry)
    return out


def _shape_capabilities_for_catalog(caps: dict[str, Any]) -> dict[str, Any]:
    """Adapt manifest capabilities for the catalog schema."""
    out: dict[str, Any] = {}
    if "tools" in caps:
        out["tools"] = _strip_tool_parameters(caps["tools"])
    if "skills" in caps:
        out["skills"] = caps["skills"]
    if "routes" in caps:
        out["routes"] = caps["routes"]
    if "config" in caps:
        out["config"] = caps["config"]
    if "web" in caps:
        out["web"] = caps["web"]
    return out


def _normalize_for_compare(catalog: dict[str, Any]) -> dict[str, Any]:
    """
    Return only the fields that should agree between catalog and manifest,
    so we can compute drift without false positives from registry-owned
    fields like versions/public_keys/homepage.
    """
    return {field: catalog.get(field) for field in DISCOVERY_FIELDS if field in catalog}


def regenerate_one(tool_name: str, check_only: bool) -> bool:
    """
    Returns True if the tool's catalog is in sync after this call.
    In --check mode, returns False if drift was detected (catalog NOT modified).
    Outside --check mode, returns True after writing.
    """
    plugin_swift = _find_plugin_swift(tool_name)
    if not plugin_swift:
        print(f"  skip {tool_name}: no Plugin.swift found")
        return True

    manifest = _extract_manifest_json(plugin_swift)
    plugin_id = manifest.get("plugin_id")
    if not plugin_id:
        raise ValueError(f"{plugin_swift}: manifest is missing plugin_id")

    catalog_file = _catalog_path(plugin_id)
    if not os.path.exists(catalog_file):
        print(f"  skip {plugin_id}: no catalog file at plugins/{plugin_id}.json")
        return True

    with open(catalog_file, "r", encoding="utf-8") as f:
        catalog = json.load(f)

    # Reshape capabilities to catalog form before merging.
    if "capabilities" in manifest:
        manifest = dict(manifest)
        manifest["capabilities"] = _shape_capabilities_for_catalog(
            manifest["capabilities"]
        )

    new_catalog = _merge_into_catalog(catalog, manifest)

    old_disc = _normalize_for_compare(catalog)
    new_disc = _normalize_for_compare(new_catalog)

    if old_disc == new_disc:
        print(f"  ok   {plugin_id}")
        return True

    if check_only:
        print(f"  DRIFT {plugin_id}: catalog out of sync with dylib manifest")
        # Render a compact diff for CI logs.
        diff = {
            field: {"catalog": old_disc.get(field), "dylib": new_disc.get(field)}
            for field in DISCOVERY_FIELDS
            if old_disc.get(field) != new_disc.get(field)
        }
        print(json.dumps(diff, indent=2, sort_keys=True))
        return False

    with open(catalog_file, "w", encoding="utf-8") as f:
        json.dump(new_catalog, f, indent=2, ensure_ascii=False)
        f.write("\n")
    print(f"  wrote {plugin_id}")
    return True


def list_tools() -> list[str]:
    if not os.path.isdir(TOOLS_DIR):
        return []
    return sorted(
        d
        for d in os.listdir(TOOLS_DIR)
        if os.path.isdir(os.path.join(TOOLS_DIR, d))
        and os.path.exists(os.path.join(TOOLS_DIR, d, "Package.swift"))
    )


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Regenerate or check the plugins/ catalog from each tool's Plugin.swift manifest."
    )
    parser.add_argument(
        "--check",
        action="store_true",
        help="Exit 1 if any catalog is out of sync (do not modify files).",
    )
    parser.add_argument(
        "--tool",
        action="append",
        default=None,
        help="Limit to specific tool(s). Repeatable. Defaults to all tools.",
    )
    args = parser.parse_args()

    tools = args.tool or list_tools()
    if not tools:
        print("No tools found.")
        return 0

    print(f"{'Checking' if args.check else 'Regenerating'} {len(tools)} catalog(s):")
    all_ok = True
    for tool in tools:
        try:
            ok = regenerate_one(tool, check_only=args.check)
        except Exception as exc:  # noqa: BLE001
            print(f"  ERROR {tool}: {exc}")
            return 2
        all_ok = all_ok and ok

    if args.check and not all_ok:
        print(
            "\nCatalog drift detected. Run `scripts/regenerate-catalogs.py` to fix.",
            file=sys.stderr,
        )
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
