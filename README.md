# Osaurus Tools Repository

Central registry for community tools and plugins for [Osaurus](https://github.com/osaurus-ai/osaurus).

## Official System Tools

| Plugin ID            | Description                            | Tools                                                                                                                                                                                                                 |
| -------------------- | -------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `osaurus.time`       | Time and date utilities                | `current_time`, `format_date`                                                                                                                                                                                         |
| `osaurus.git`        | Git repository utilities               | `git_status`, `git_log`, `git_diff`, `git_branch`                                                                                                                                                                     |
| `osaurus.browser`    | Agent-friendly headless WebKit browser | `browser_navigate`, `browser_snapshot`, `browser_click`, `browser_type`, `browser_select`, `browser_hover`, `browser_scroll`, `browser_press_key`, `browser_wait_for`, `browser_screenshot`, `browser_execute_script` |
| `osaurus.fetch`      | HTTP client for web requests           | `fetch`, `fetch_json`, `fetch_html`, `download`                                                                                                                                                                       |
| `osaurus.search`     | Web search via DuckDuckGo              | `search`, `search_news`, `search_images`                                                                                                                                                                              |
| `osaurus.filesystem` | File system operations                 | `read_file`, `write_file`, `list_directory`, `create_directory`, `delete_file`, `move_file`, `search_files`, `get_file_info`                                                                                          |

### Installation

```bash
osaurus tools install osaurus.time
osaurus tools install osaurus.git
osaurus tools install osaurus.browser
osaurus tools install osaurus.fetch
osaurus tools install osaurus.search
osaurus tools install osaurus.filesystem
```

## Adding a Plugin to the Registry

1. Fork this repository
2. Create `plugins/<your.plugin.id>.json` (e.g., `mycompany.mytool.json`)
3. Fill in the plugin specification (see schema below)
4. Submit a Pull Request — CI will validate your JSON automatically

## Plugin Specification

Plugins are distributed as a `.dylib` in a zip file. The manifest is embedded in the plugin binary. Osaurus supports two ABI versions — v1 (tools only) and v2 (full host API: routes, config, web, storage, agent dispatch, inference, models, HTTP client). See the [Plugin Authoring Guide](https://github.com/osaurus-ai/osaurus/blob/main/docs/PLUGIN_AUTHORING.md) for the full specification.

### Zip Structure

A plugin zip can include optional files alongside the `.dylib`:

```
mycompany.mytool-1.0.0.zip
├── libMyTool.dylib        # Required
├── SKILL.md               # Optional: AI skill guidance
├── README.md              # Optional: displayed in plugin detail UI
├── CHANGELOG.md           # Optional: displayed in Changelog tab
└── web/                   # Optional: static frontend assets (v2)
    ├── index.html
    └── assets/
```

### Registry Spec Example

```json
{
  "plugin_id": "mycompany.mytool",
  "name": "My Cool Tool",
  "homepage": "https://example.com/mytool",
  "license": "MIT",
  "authors": ["Jane Doe"],
  "capabilities": {
    "tools": [
      {
        "name": "mytool",
        "description": "Does something cool"
      }
    ],
    "skills": [
      {
        "name": "mytool-skill",
        "description": "Guides the AI through mytool workflows"
      }
    ],
    "routes": [
      {
        "name": "oauth_callback",
        "description": "OAuth 2.0 callback handler"
      }
    ]
  },
  "docs": {
    "readme": "README.md",
    "changelog": "CHANGELOG.md",
    "links": [
      { "label": "Documentation", "url": "https://docs.example.com/mytool" }
    ]
  },
  "public_keys": {
    "minisign": "RWxxxxxxxxxxxxxxxx"
  },
  "versions": [
    {
      "version": "1.0.0",
      "release_date": "2025-01-01",
      "notes": "Initial release",
      "requires": {
        "osaurus_min_version": "0.5.0"
      },
      "artifacts": [
        {
          "os": "macos",
          "arch": "arm64",
          "url": "https://example.com/downloads/mytool-1.0.0.zip",
          "sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
          "minisign": {
            "signature": "RWxxxxxxxxxxxxxxxx"
          }
        }
      ]
    }
  ]
}
```

### Required Fields

| Field         | Description                                                          |
| ------------- | -------------------------------------------------------------------- |
| `plugin_id`   | Unique identifier in dot-separated format (e.g., `mycompany.mytool`) |
| `name`        | Display name                                                         |
| `public_keys` | Dictionary of public keys for signature verification                 |
| `versions`    | List of available versions                                           |

### Optional Fields

| Field                    | Description                                                                                |
| ------------------------ | ------------------------------------------------------------------------------------------ |
| `homepage`               | Plugin homepage or repository URL                                                          |
| `license`                | License (e.g., "MIT", "Apache-2.0")                                                       |
| `authors`                | List of author names                                                                       |
| `capabilities`           | Tools, skills, and routes descriptions                                                     |
| `capabilities.tools`     | Array of `{name, description}` — the tools the plugin provides                            |
| `capabilities.skills`    | Array of `{name, description}` — AI skills bundled with the plugin                        |
| `capabilities.routes`    | Array of `{name, description}` — HTTP routes the plugin exposes (v2)                      |
| `docs`                   | Documentation metadata                                                                     |
| `docs.readme`            | Path to README file in the plugin bundle                                                   |
| `docs.changelog`         | Path to CHANGELOG file in the plugin bundle                                                |
| `docs.links`             | Array of `{label, url}` — external documentation links                                    |
| `secrets`                | Array of secret definitions for API keys/credentials (see [Plugin Secrets](#plugin-secrets))|

### Version Entry

| Field                          | Required | Description                      |
| ------------------------------ | -------- | -------------------------------- |
| `version`                      | Yes      | Semantic version (e.g., "1.0.0") |
| `artifacts`                    | Yes      | List of downloadable binaries    |
| `release_date`                 | No       | Date string (ISO 8601)           |
| `notes`                        | No       | Release notes                    |
| `requires.osaurus_min_version` | No       | Minimum Osaurus version          |

### Artifact Entry

| Field       | Required | Description                                   |
| ----------- | -------- | --------------------------------------------- |
| `os`        | Yes      | Operating system (`macos`)                    |
| `arch`      | Yes      | CPU architecture (`arm64`)                    |
| `url`       | Yes      | Direct download URL for the zip               |
| `sha256`    | Yes      | SHA-256 checksum                              |
| `minisign`  | Yes      | Minisign signature object (`signature`)       |
| `min_macos` | No       | Minimum macOS version (e.g., "13.0")          |
| `size`      | No       | File size in bytes                            |

## v2 Plugin Capabilities

v2 extends the plugin system with a full host API spanning 15 callbacks across 7 capability groups: config store, data store, logging, agent dispatch, inference, models, and HTTP client. Plugins can also declare routes, configuration UI, static web serving, and documentation. These capabilities are entirely optional — a v2 plugin can use any combination of them.

For the full v2 ABI specification (entry points, host API callbacks, storage, routes, config, dispatch, inference), see the [Plugin Authoring Guide](https://github.com/osaurus-ai/osaurus/blob/main/docs/PLUGIN_AUTHORING.md).

### Routes

v2 plugins can register HTTP route handlers for OAuth flows, webhooks, and plugin-hosted web apps. Routes are namespaced under `/plugins/<plugin_id>/` and support `none`, `verify`, or `owner` auth levels.

### Configuration UI

Plugins can declare a settings schema rendered natively in the Osaurus Management window. Field types include `text`, `secret`, `toggle`, `select`, `multiselect`, `number`, `readonly`, and `status`.

### Static Web Serving

Plugins can ship a frontend (React, Svelte, Vue, vanilla JS) as static files in a `web/` directory. Osaurus serves them directly and injects a `window.__osaurus` context object.

### Storage

v2 plugins have two storage tiers: a Keychain-backed config store for secrets and tokens, and a sandboxed per-plugin SQLite database for structured data. Both are accessed through host API callbacks injected at init.

### Agent Dispatch

Plugins can dispatch background agent tasks with full tool access via `host->dispatch(ctx, prompt, config_json)`. Tasks run asynchronously; plugins poll status with `task_status`, cancel with `dispatch_cancel`, and respond to clarification requests with `dispatch_clarify`. Plugins can also implement the `on_task_event(ctx, task_id, event_type, event_json)` callback on `osr_plugin_api` to receive task lifecycle events (progress, completion, failure, clarification needed).

### Inference

Plugins can perform LLM chat completions and generate embeddings through any model configured in Osaurus (local MLX, Apple Foundation Models, or remote providers). Use `host->complete(ctx, model, messages_json, params_json)` for single-shot completions, `host->complete_stream(ctx, model, messages_json, params_json, callback, user_data)` for streaming, and `host->embed(ctx, model, texts_json)` for embedding vectors.

### Models

Plugins can enumerate available models at runtime via `host->list_models(ctx)`, which returns a JSON array of model descriptors including id, provider, and capability tags. This enables dynamic model routing or user-facing model selection within plugin UIs.

### HTTP Client

Plugins can make outbound HTTP requests via `host->http_request(ctx, method, url, headers_json, body)`. Requests are subject to SSRF protection — private/internal IP ranges are blocked by default. This enables plugins to integrate with external APIs, webhooks, and third-party services without bundling their own HTTP stack.

## Code Signing

macOS plugins (`.dylib`) **must be code-signed** with a valid Developer ID Application certificate. Unsigned plugins will be blocked by Gatekeeper when downloaded.

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: Your Name (TEAMID)" \
  libMyPlugin.dylib
```

## Artifact Signing (Minisign)

Sign your release zip to ensure integrity:

```bash
# Install Minisign
brew install minisign

# Generate key pair (once)
minisign -G -p minisign.pub -s minisign.key

# Sign your zip
minisign -S -s minisign.key -m myplugin-macos-arm64.zip
```

Add to your plugin spec:

- Public key contents → `public_keys.minisign`
- Signature contents → `versions[].artifacts[].minisign.signature`

## Publishing a Plugin

Use the reusable workflow to automatically build, sign, release, and register your plugin.

### 1. Manifest Requirements

Your plugin's `get_manifest()` function must return valid JSON with these fields:

| Field                  | Required | Description                                                                |
| ---------------------- | -------- | -------------------------------------------------------------------------- |
| `plugin_id`            | Yes      | Unique identifier (e.g., `myname.weather`)                                 |
| `description`          | Yes      | Brief description of what the plugin does                                  |
| `capabilities.tools`   | Yes      | Array of tool definitions                                                  |
| `name`                 | No       | Display name (defaults to plugin_id suffix)                                |
| `license`              | No       | License identifier (defaults to `MIT`)                                     |
| `authors`              | No       | Array of author names (defaults to repo owner)                             |
| `min_macos`            | No       | Minimum macOS version (defaults to `13.0`)                                 |
| `min_osaurus`          | No       | Minimum Osaurus version (defaults to `0.5.0`)                              |
| `secrets`              | No       | Array of secret definitions for API keys/credentials                       |
| `capabilities.routes`  | No       | Array of HTTP route definitions (v2)                                       |
| `capabilities.config`  | No       | Configuration UI schema rendered in the Management window (v2)             |
| `capabilities.web`     | No       | Static web serving declaration (`static_dir`, `entry`, `mount`, `auth`) (v2)|
| `docs`                 | No       | Documentation metadata (`readme`, `changelog`, `links`) (v2)              |

Note: Version is extracted from the Git tag (e.g., `v1.0.0` or `1.0.0`), not from the manifest.

### Plugin Secrets

Plugins that require API keys or other credentials can declare them in the manifest. Osaurus stores secrets securely in the macOS Keychain and prompts users to configure them during installation.

**Declaring Secrets in Manifest:**

```json
{
  "plugin_id": "myname.weather",
  "description": "Weather forecasts",
  "secrets": [
    {
      "id": "api_key",
      "label": "OpenWeather API Key",
      "description": "Get your API key from [OpenWeather](https://openweathermap.org/api)",
      "required": true,
      "url": "https://openweathermap.org/api"
    },
    {
      "id": "backup_key",
      "label": "Backup API Key",
      "description": "Optional backup key for failover",
      "required": false
    }
  ],
  "capabilities": {
    "tools": [...]
  }
}
```

**Secret Specification Fields:**

| Field         | Type    | Required | Description                                               |
| ------------- | ------- | -------- | --------------------------------------------------------- |
| `id`          | string  | Yes      | Unique identifier for the secret (e.g., `"api_key"`)      |
| `label`       | string  | Yes      | Human-readable label shown in the UI                      |
| `description` | string  | No       | Rich text description (supports markdown links)           |
| `required`    | boolean | Yes      | Whether the secret is required for the plugin to function |
| `url`         | string  | No       | URL where users can obtain the secret                     |

**Accessing Secrets in Swift:**

When a tool is invoked, Osaurus automatically injects configured secrets into the payload under the `_secrets` key:

```swift
func run(args: String) -> String {
    struct Args: Decodable {
        let location: String
        let _secrets: [String: String]?
    }

    guard let data = args.data(using: .utf8),
          let input = try? JSONDecoder().decode(Args.self, from: data)
    else {
        return "{\"error\": \"Invalid arguments\"}"
    }

    // Get the API key from secrets
    guard let apiKey = input._secrets?["api_key"] else {
        return "{\"error\": \"API key not configured. Please configure secrets in Osaurus settings.\"}"
    }

    // Use the API key for requests
    let result = fetchWeather(location: input.location, apiKey: apiKey)
    return "{\"weather\": \"\(result)\"}"
}
```

**User Experience:**

- When a plugin with secrets is installed, Osaurus prompts the user to configure them
- If required secrets are missing, a "Needs API Key" badge appears on the plugin card
- Users can configure or edit secrets anytime via the plugin menu → "Configure Secrets"
- Secrets are stored securely in the macOS Keychain
- Secrets are automatically cleaned up when the plugin is uninstalled

### 2. Add Release Workflow

Create `.github/workflows/release.yml` in your plugin repository:

```yaml
# .github/workflows/release.yml
name: Release
on:
  push:
    tags: ["v*", "[0-9]+.[0-9]+.[0-9]+"]

jobs:
  release:
    uses: osaurus-ai/osaurus-tools/.github/workflows/build-plugin.yml@master
    secrets: inherit
```

That's it. No inputs needed - everything is extracted from your dylib's `get_manifest()`.

### 3. Configure Secrets

All secrets are required for code signing and artifact verification.

| Secret                                | Purpose                                         |
| ------------------------------------- | ----------------------------------------------- |
| `DEVELOPER_ID_CERTIFICATE_P12_BASE64` | Base64-encoded Developer ID certificate (.p12)  |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD`   | Password for the Apple certificate              |
| `MINISIGN_SECRET_KEY`                 | Minisign secret key for artifact signing        |
| `MINISIGN_PASSWORD`                   | Password for the minisign key                   |
| `MINISIGN_PUBLIC_KEY`                 | Public key included in registry manifest        |
| `REGISTRY_PAT`                        | GitHub PAT with `public_repo` scope for auto-PR |

Generate minisign keys:

```bash
minisign -G -p minisign.pub -s minisign.key
# Add minisign.key contents to MINISIGN_SECRET_KEY
# Add minisign.pub contents to MINISIGN_PUBLIC_KEY
```

### 4. Tag and Release

```bash
git tag v1.0.0
git push origin v1.0.0
```

The workflow will:

1. Build your plugin as a dylib
2. Auto-detect the dylib and extract manifest
3. Code sign with Apple Developer ID
4. Sign the artifact with minisign
5. Create a GitHub Release with the artifact
6. Submit a PR to the osaurus-tools registry

## Development

### Building System Tools

```bash
# Build a single tool
./scripts/build-tool.sh time --version 1.0.0

# Build all tools
./scripts/build-tool.sh all --version 1.0.0
```

Build output goes to `build/<tool-name>/`. The `--version` flag is required.

To extract and verify the manifest from a built plugin:

```bash
osaurus manifest extract build/time/staging/*.dylib | jq .
```

### Creating a New Tool

1. Create directory structure:

   ```
   tools/mytool/
   ├── Package.swift
   ├── Sources/OsaurusMytool/Plugin.swift
   ├── SKILL.md               # Optional: AI skill guidance
   ├── README.md              # Optional: displayed in plugin detail UI
   ├── CHANGELOG.md           # Optional: displayed in Changelog tab
   └── web/                   # Optional: static frontend assets (v2)
   ```

2. Implement the plugin using the [C ABI](https://github.com/osaurus-ai/osaurus/blob/main/docs/PLUGIN_AUTHORING.md). The manifest is embedded directly in `Plugin.swift` via the `get_manifest` function. See existing tools for examples.

   - **v1 plugins** export `osaurus_plugin_entry` — sufficient for tools-only plugins.
   - **v2 plugins** export `osaurus_plugin_entry_v2(const osr_host_api* host)` — required for routes, config, web, storage, agent dispatch, inference, or HTTP. The host API provides 15 callbacks across 7 capability groups (config store, data store, logging, agent dispatch, inference, models, HTTP client). The v2 ABI is a superset of v1; Osaurus falls back to v1 if the v2 symbol is not found.

3. Build and test:

   ```bash
   ./scripts/build-tool.sh mytool --version 1.0.0
   osaurus tools install ./build/mytool/osaurus.mytool-1.0.0.zip
   ```

   The build script automatically includes `SKILL.md`, `README.md`, `CHANGELOG.md`, and `web/` in the zip if they exist in the tool directory.

### Releasing

```bash
# Release a single tool (version is required)
./scripts/release.sh time 1.0.0
git push origin time-1.0.0

# Release all tools with the same version
./scripts/release.sh all 1.0.0
git push origin --tags
```

The GitHub Actions workflow will:

1. Build the plugin for macOS arm64
2. Create a GitHub Release with the artifact
3. Open a PR to update the registry JSON

## License

MIT License — see [LICENSE](LICENSE) for details.
