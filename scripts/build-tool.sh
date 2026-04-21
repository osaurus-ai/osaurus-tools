#!/bin/bash
#
# Build and package Osaurus plugins
#
# Usage:
#   ./scripts/build-tool.sh <tool-name>     Build a single tool
#   ./scripts/build-tool.sh all             Build all tools
#
# Examples:
#   ./scripts/build-tool.sh time
#   ./scripts/build-tool.sh git --version 1.0.0
#   ./scripts/build-tool.sh all
#
# Environment Variables:
#   CODESIGN_IDENTITY    Signing identity for codesign (e.g., "Developer ID Application: Company (TEAMID)")
#                        If not set, ad-hoc signing is used.
#
# This script:
# 1. Builds the Swift plugin as a dynamic library
# 2. Code signs the dylib (Developer ID if CODESIGN_IDENTITY is set, ad-hoc otherwise)
# 3. Packages the .dylib into a zip
# 4. Computes SHA256 checksum
# 5. Outputs build artifacts to build/<tool-name>/
#

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_success() { echo -e "${GREEN}✓${NC} $1"; }
print_error() { echo -e "${RED}✗${NC} $1"; }
print_info() { echo -e "${YELLOW}→${NC} $1"; }

if [ $# -lt 1 ]; then
    echo "Usage: $0 <tool-name|all> --version <version>"
    echo ""
    echo "Commands:"
    echo "  <tool-name>    Build a specific tool (e.g., time, git)"
    echo "  all            Build all tools in the tools/ directory"
    echo ""
    echo "Options:"
    echo "  --version      Version string (required for release builds)"
    echo ""
    echo "Examples:"
    echo "  $0 time --version 1.0.0"
    echo "  $0 git --version 1.0.0"
    echo "  $0 all --version 1.0.0"
    exit 1
fi

TOOL_NAME="$1"
VERSION=""

# Parse optional arguments
shift
while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            VERSION="$2"
            shift 2
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
done

# Function to build a single tool
build_tool() {
    local tool_name="$1"
    local version_override="$2"

    local tool_dir="$ROOT_DIR/tools/$tool_name"
    local build_output="$ROOT_DIR/build/$tool_name"

    if [ ! -d "$tool_dir" ]; then
        print_error "Tool directory not found: $tool_dir"
        return 1
    fi

    if [ ! -f "$tool_dir/Package.swift" ]; then
        print_error "Package.swift not found in $tool_dir"
        return 1
    fi

    # Find Plugin.swift
    local plugin_swift=$(find "$tool_dir/Sources" -name "Plugin.swift" -type f | head -1)
    if [ -z "$plugin_swift" ] || [ ! -f "$plugin_swift" ]; then
        print_error "Plugin.swift not found in $tool_dir/Sources"
        return 1
    fi

    # Version must be provided
    local version="$version_override"
    if [ -z "$version" ]; then
        print_error "Version is required. Use --version <version>"
        return 1
    fi

    # Extract plugin_id from Plugin.swift
    local plugin_id=$(grep -o '"plugin_id"[[:space:]]*:[[:space:]]*"[^"]*"' "$plugin_swift" | head -1 | sed 's/.*"plugin_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/')

    echo ""
    echo "========================================"
    print_info "Building $plugin_id v$version"
    echo "========================================"
    echo "Tool directory: $tool_dir"
    echo "Output directory: $build_output"

    # Clean and create build output directory
    rm -rf "$build_output"
    mkdir -p "$build_output"

    # Build the Swift package
    echo ""
    print_info "Building Swift package..."
    cd "$tool_dir"

    # Get the product name from Package.swift
    local product_name=$(swift package describe --type json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['products'][0]['name'])" 2>/dev/null || echo "")

    if [ -z "$product_name" ]; then
        # Fallback: derive from directory name
        product_name="Osaurus$(echo "$tool_name" | sed 's/.*/\u&/')"
    fi

    echo "Product name: $product_name"

    swift build -c release

    # Find the built dylib
    local dylib_path="$tool_dir/.build/release/lib${product_name}.dylib"

    if [ ! -f "$dylib_path" ]; then
        print_error "Built library not found at $dylib_path"
        echo "Looking for available libraries..."
        find "$tool_dir/.build/release" -name "*.dylib" -type f
        return 1
    fi

    print_success "Built library: $dylib_path"

    # Create staging directory for packaging
    local staging_dir="$build_output/staging"
    mkdir -p "$staging_dir"

    # Copy artifacts to staging
    cp "$dylib_path" "$staging_dir/lib${product_name}.dylib"

    # Include optional v2 plugin assets
    for asset in SKILL.md README.md CHANGELOG.md; do
        if [ -f "$tool_dir/$asset" ]; then
            cp "$tool_dir/$asset" "$staging_dir/$asset"
            print_success "Included $asset"
        fi
    done

    if [ -d "$tool_dir/web" ]; then
        cp -R "$tool_dir/web" "$staging_dir/web"
        print_success "Included web/ directory"
    fi

    # Code sign the dylib
    local dylib_file="$staging_dir/lib${product_name}.dylib"
    if [ -n "${CODESIGN_IDENTITY:-}" ]; then
        print_info "Signing dylib with Developer ID..."
        codesign --force --options runtime --timestamp --sign "$CODESIGN_IDENTITY" "$dylib_file"
        print_success "Signed with Developer ID: lib${product_name}.dylib"
    else
        print_info "Ad-hoc signing dylib (no CODESIGN_IDENTITY set)..."
        codesign -s - -f "$dylib_file"
        print_success "Ad-hoc signed: lib${product_name}.dylib"
    fi

    # Create the zip archive
    local zip_name="${plugin_id}-${version}.zip"
    local zip_path="$build_output/$zip_name"

    print_info "Creating zip archive..."
    cd "$staging_dir"
    zip -r "$zip_path" .

    # Compute SHA256
    print_info "Computing SHA256..."
    local sha256=$(shasum -a 256 "$zip_path" | cut -d' ' -f1)

    # Get file size
    local size=$(stat -f%z "$zip_path" 2>/dev/null || stat --printf="%s" "$zip_path")

    # Keep staging directory with dylib for manifest extraction
    # Can be used with: osaurus manifest extract build/<tool>/staging/*.dylib

    # Write build info
    cat > "$build_output/build-info.json" <<EOF
{
  "plugin_id": "$plugin_id",
  "version": "$version",
  "artifact": "$zip_name",
  "sha256": "$sha256",
  "size": $size,
  "dylib": "staging/lib${product_name}.dylib",
  "built_at": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
}
EOF

    # Sync the registry catalog with the dylib's manifest so the two never
    # drift. Distribution-only fields (versions[], public_keys, homepage,
    # docs, skill) are preserved by regenerate-catalogs.py.
    print_info "Syncing plugins/${plugin_id}.json with dylib manifest..."
    if python3 "$SCRIPT_DIR/regenerate-catalogs.py" --tool "$tool_name" >/dev/null; then
        print_success "Registry catalog in sync"
    else
        print_error "Catalog regeneration failed for $plugin_id"
        return 1
    fi

    # Belt-and-braces: confirm the registry's minisign public key matches the
    # CI signing keypair before we publish anything. Skips when MINISIGN_PUBLIC_KEY
    # is unset (local dev). A mismatch silently produces unverifiable artifacts.
    local catalog_file="$ROOT_DIR/plugins/${plugin_id}.json"
    if [ -n "${MINISIGN_PUBLIC_KEY:-}" ] && [ -f "$catalog_file" ]; then
        local registry_pubkey
        registry_pubkey=$(python3 -c "import json,sys; d=json.load(open('$catalog_file')); print(d.get('public_keys',{}).get('minisign',''))")
        # MINISIGN_PUBLIC_KEY env may be the raw key or the 2-line file ("untrusted comment\n<key>");
        # match against either form.
        local env_pubkey
        env_pubkey=$(echo "$MINISIGN_PUBLIC_KEY" | grep -oE 'RW[A-Za-z0-9+/=]{50,}' | head -1)
        if [ -n "$registry_pubkey" ] && [ -n "$env_pubkey" ] && [ "$registry_pubkey" != "$env_pubkey" ]; then
            print_error "Minisign key mismatch for $plugin_id!"
            echo "  Registry public key: $registry_pubkey"
            echo "  CI public key:       $env_pubkey"
            echo "  Releasing now would silently produce unverifiable artifacts."
            echo "  Either rotate the registry public_keys.minisign or fix MINISIGN_PUBLIC_KEY."
            return 1
        fi
    fi

    echo ""
    print_success "Build complete!"
    echo ""
    echo "  Artifact: $zip_path"
    echo "  SHA256:   $sha256"
    echo "  Size:     $size bytes"
    echo ""

    return 0
}

# Main logic
if [ "$TOOL_NAME" == "all" ]; then
    echo ""
    echo "========================================"
    echo "  Building all tools"
    echo "========================================"

    TOOLS_DIR="$ROOT_DIR/tools"
    FAILED=0
    BUILT=0

    for tool_path in "$TOOLS_DIR"/*/; do
        tool=$(basename "$tool_path")
        if [ -f "$tool_path/Package.swift" ]; then
            if build_tool "$tool" "$VERSION"; then
                ((BUILT++))
            else
                ((FAILED++))
            fi
        fi
    done

    echo ""
    echo "========================================"
    if [ $FAILED -eq 0 ]; then
        print_success "All $BUILT tools built successfully!"
    else
        print_error "$FAILED tool(s) failed to build"
        exit 1
    fi
else
    build_tool "$TOOL_NAME" "$VERSION"
fi
