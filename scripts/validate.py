#!/usr/bin/env python3
import hashlib
import json
import os
import sys
import re
import glob
import subprocess
import tempfile
import urllib.request
import shutil

# Constants for validation
REQUIRED_TOP_LEVEL = {"plugin_id", "versions", "public_keys"}
REQUIRED_VERSION_LEVEL = {"version", "artifacts"}
REQUIRED_ARTIFACT_LEVEL = {"os", "arch", "url", "sha256", "minisign"}
VALID_OS = {"macos"}
VALID_ARCH = {"arm64"}

# SemVer regex (simplified but robust enough for basic validation)
# Matches 1.0.0, 1.0.0-beta, 1.0.0+build, etc.
SEMVER_REGEX = re.compile(r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-((?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*)(?:\.(?:0|[1-9]\d*|\d*[a-zA-Z-][0-9a-zA-Z-]*))*))?(?:\+([0-9a-zA-Z-]+(?:\.[0-9a-zA-Z-]+)*))?$")

# Minisign public key format: starts with "RW" and is base64 encoded (typically 56 chars)
MINISIGN_PUBKEY_REGEX = re.compile(r"^RW[A-Za-z0-9+/]{50,}={0,2}$")

def validate_semver(version):
    return bool(SEMVER_REGEX.match(version))

def semver_sort_key(version):
    """Sort key implementing semver precedence (build metadata ignored)."""
    m = SEMVER_REGEX.match(version)
    major, minor, patch = int(m.group(1)), int(m.group(2)), int(m.group(3))
    prerelease = m.group(4)
    if prerelease is None:
        # A release version has higher precedence than any of its pre-releases
        pre_key = (1,)
    else:
        identifiers = []
        for ident in prerelease.split("."):
            if ident.isdigit():
                identifiers.append((0, int(ident), ""))
            else:
                identifiers.append((1, 0, ident))
        pre_key = (0, tuple(identifiers))
    return (major, minor, patch, pre_key)

def validate_versions_order(versions, filepath):
    """Versions must be unique and sorted descending by semver (newest first)."""
    version_strings = [v.get("version") for v in versions if isinstance(v, dict) and "version" in v]
    valid = True

    duplicates = {v for v in version_strings if version_strings.count(v) > 1}
    if duplicates:
        print(f"Error in {filepath}: Duplicate versions found: {sorted(duplicates)}")
        valid = False

    parseable = [v for v in version_strings if validate_semver(v)]
    expected = sorted(parseable, key=semver_sort_key, reverse=True)
    if parseable != expected:
        print(f"Error in {filepath}: 'versions' must be sorted descending by semver (newest first)")
        print(f"  Current order:  {parseable}")
        print(f"  Expected order: {expected}")
        valid = False

    return valid

def validate_requires(data, filepath):
    """
    Every plugin must declare the minimum Osaurus version at the top level:
    normally as 'requires.osaurus_min_version'. The legacy top-level
    'min_osaurus' spelling remains accepted for older catalog entries.
    """
    requires = data.get("requires")
    if requires is not None and not isinstance(requires, dict):
        print(f"Error in {filepath}: 'requires' must be a dictionary")
        return False

    if isinstance(requires, dict):
        min_version = requires.get("osaurus_min_version")
        field = "requires.osaurus_min_version"
    else:
        min_version = data.get("min_osaurus")
        field = "min_osaurus"

    if not isinstance(min_version, str) or not min_version:
        print(
            f"Error in {filepath}: Missing top-level "
            "'requires.osaurus_min_version'"
        )
        return False

    if not validate_semver(min_version):
        print(f"Error in {filepath}: Invalid {field} '{min_version}'")
        return False

    return True

def validate_public_keys(public_keys, context):
    """Validate public_keys object contains valid minisign public key."""
    if not isinstance(public_keys, dict):
        print(f"Error in {context}: 'public_keys' must be a dictionary")
        return False
    
    if "minisign" not in public_keys:
        print(f"Error in {context}: 'public_keys' must contain 'minisign' key")
        return False
    
    pubkey = public_keys["minisign"]
    if not isinstance(pubkey, str):
        print(f"Error in {context}: 'public_keys.minisign' must be a string")
        return False
    
    if not MINISIGN_PUBKEY_REGEX.match(pubkey):
        print(f"Error in {context}: Invalid minisign public key format. Must start with 'RW' and be base64 encoded")
        return False
    
    return True

def validate_minisign_signature(minisign_obj, context):
    """Validate minisign signature object in artifact."""
    if not isinstance(minisign_obj, dict):
        print(f"Error in {context}: 'minisign' must be a dictionary")
        return False
    
    if "signature" not in minisign_obj:
        print(f"Error in {context}: 'minisign' must contain 'signature' field")
        return False
    
    signature = minisign_obj["signature"]
    if not isinstance(signature, str):
        print(f"Error in {context}: 'minisign.signature' must be a string")
        return False
    
    # Minisign signature format has specific structure:
    # - Line 1: "untrusted comment: ..."
    # - Line 2: Base64 signature (starts with key algorithm prefix, e.g., "RW")
    # - Line 3: "trusted comment: ..."
    # - Line 4: Base64 global signature
    lines = signature.strip().split('\n')
    if len(lines) != 4:
        print(f"Error in {context}: Invalid minisign signature format (expected 4 lines, got {len(lines)})")
        return False
    
    if not lines[0].startswith("untrusted comment:"):
        print(f"Error in {context}: Minisign signature must start with 'untrusted comment:'")
        return False
    
    if not lines[2].startswith("trusted comment:"):
        print(f"Error in {context}: Minisign signature line 3 must start with 'trusted comment:'")
        return False
    
    # Verify line 2 and 4 are base64 (signature data)
    base64_pattern = re.compile(r"^[A-Za-z0-9+/]+=*$")
    if not base64_pattern.match(lines[1]):
        print(f"Error in {context}: Invalid base64 in minisign signature line 2")
        return False
    
    if not base64_pattern.match(lines[3]):
        print(f"Error in {context}: Invalid base64 in minisign signature line 4")
        return False
    
    return True

def check_public_key_immutability(filepath, current_public_key):
    """
    Check that public key hasn't changed from base branch.
    Only runs in PR context (when GITHUB_BASE_REF is set).
    Returns True if check passes or is not applicable.
    """
    base_ref = os.environ.get("GITHUB_BASE_REF", "")
    if not base_ref:
        # Not in PR context, skip immutability check
        return True
    
    # Get relative path for git
    script_dir = os.path.dirname(os.path.abspath(__file__))
    repo_root = os.path.dirname(script_dir)
    rel_path = os.path.relpath(filepath, repo_root)
    
    try:
        # Try to get the file from base branch
        result = subprocess.run(
            ["git", "show", f"origin/{base_ref}:{rel_path}"],
            capture_output=True,
            text=True,
            cwd=repo_root
        )
        
        if result.returncode != 0:
            # File doesn't exist on base branch - this is a new plugin, allow any public key
            print(f"  New plugin detected (not on {base_ref}), public key registration allowed")
            return True
        
        # Parse the base branch version
        base_data = json.loads(result.stdout)
        base_public_key = base_data.get("public_keys", {}).get("minisign", "")
        
        if not base_public_key:
            # No public key on base branch (shouldn't happen with new requirements)
            print(f"  No public key found on {base_ref}, allowing initial registration")
            return True
        
        if current_public_key != base_public_key:
            print(f"Error: Public key modification detected!")
            print(f"  Base branch ({base_ref}) key: {base_public_key}")
            print(f"  Current key: {current_public_key}")
            print(f"  Public keys are IMMUTABLE after initial registration.")
            print(f"  Only the original author (holder of the private key) can sign updates.")
            return False
        
        print(f"  Public key unchanged from {base_ref} (immutability check passed)")
        return True
        
    except json.JSONDecodeError:
        print(f"  Warning: Could not parse base branch version of {filepath}")
        return True
    except Exception as e:
        print(f"  Warning: Could not check public key immutability: {e}")
        return True

def verify_artifact_signature(artifact, public_key, context):
    """Download artifact and verify sha256 checksum and minisign signature."""
    url = artifact["url"]
    signature = artifact["minisign"]["signature"]
    expected_sha256 = artifact["sha256"].lower()
    
    # Create temporary directory for verification
    tmpdir = tempfile.mkdtemp(prefix="osaurus_verify_")
    try:
        # Download artifact
        artifact_path = os.path.join(tmpdir, "artifact.zip")
        print(f"  Downloading {url}...")
        try:
            urllib.request.urlretrieve(url, artifact_path)
        except Exception as e:
            print(f"Error in {context}: Could not download artifact for signature verification: {e}")
            print(f"  Unreachable artifacts are a validation failure when VERIFY_SIGNATURES is enabled")
            return False
        
        # Verify sha256 of the downloaded artifact matches the registry value
        sha256 = hashlib.sha256()
        with open(artifact_path, "rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                sha256.update(chunk)
        actual_sha256 = sha256.hexdigest()
        if actual_sha256 != expected_sha256:
            print(f"Error in {context}: SHA256 mismatch for downloaded artifact")
            print(f"  Registry sha256: {expected_sha256}")
            print(f"  Actual sha256:   {actual_sha256}")
            return False
        print(f"  SHA256 verified for {os.path.basename(url)}")
        
        # Write public key file (minisign format requires specific format)
        pubkey_path = os.path.join(tmpdir, "minisign.pub")
        with open(pubkey_path, 'w') as f:
            f.write(f"untrusted comment: minisign public key\n{public_key}\n")
        
        # Write signature file
        sig_path = os.path.join(tmpdir, "artifact.zip.minisig")
        with open(sig_path, 'w') as f:
            f.write(signature)
        
        # Run minisign verification
        result = subprocess.run(
            ["minisign", "-V", "-p", pubkey_path, "-m", artifact_path, "-x", sig_path],
            capture_output=True,
            text=True
        )
        
        if result.returncode != 0:
            print(f"Error in {context}: Minisign signature verification FAILED")
            print(f"  minisign output: {result.stderr.strip()}")
            print(f"  This artifact was NOT signed by the registered public key!")
            return False
        
        print(f"  Signature verified for {os.path.basename(url)}")
        return True
        
    finally:
        # Clean up temporary directory
        shutil.rmtree(tmpdir, ignore_errors=True)

def validate_secrets(secrets, context):
    """Validate the optional secrets array (v2)."""
    if not isinstance(secrets, list):
        print(f"Error in {context}: 'secrets' must be an array")
        return False

    valid = True
    for idx, secret in enumerate(secrets):
        sc = f"{context} -> secrets[{idx}]"
        if not isinstance(secret, dict):
            print(f"Error in {sc}: each secret must be an object")
            valid = False
            continue

        for required_field in ("id", "label", "required"):
            if required_field not in secret:
                print(f"Error in {sc}: missing required field '{required_field}'")
                valid = False

        if "id" in secret and not isinstance(secret["id"], str):
            print(f"Error in {sc}: 'id' must be a string")
            valid = False
        if "label" in secret and not isinstance(secret["label"], str):
            print(f"Error in {sc}: 'label' must be a string")
            valid = False
        if "required" in secret and not isinstance(secret["required"], bool):
            print(f"Error in {sc}: 'required' must be a boolean")
            valid = False
        if "description" in secret and not isinstance(secret["description"], str):
            print(f"Error in {sc}: 'description' must be a string")
            valid = False
        if "url" in secret and not isinstance(secret["url"], str):
            print(f"Error in {sc}: 'url' must be a string")
            valid = False

    return valid


def validate_capabilities(capabilities, context):
    """Validate the optional capabilities object including v2 fields."""
    if not isinstance(capabilities, dict):
        print(f"Error in {context}: 'capabilities' must be a dictionary")
        return False

    valid = True

    # tools: array of {name, description}. Names must be present, non-empty,
    # and unique — mirrors the manifest conformance lint in the release
    # workflows (tool *ids* there project to `name` in the registry catalog).
    if "tools" in capabilities:
        tools = capabilities["tools"]
        if not isinstance(tools, list):
            print(f"Error in {context}: 'capabilities.tools' must be an array")
            valid = False
        else:
            seen_tool_names = set()
            for idx, tool in enumerate(tools):
                tc = f"{context} -> tools[{idx}]"
                if not isinstance(tool, dict):
                    print(f"Error in {tc}: each tool must be an object")
                    valid = False
                    continue
                name = tool.get("name")
                if not isinstance(name, str) or not name.strip():
                    print(f"Error in {tc}: tool must have a non-empty string 'name'")
                    valid = False
                    continue
                name = name.strip()
                if name in seen_tool_names:
                    print(f"Error in {tc}: duplicate tool name '{name}'")
                    valid = False
                seen_tool_names.add(name)
                description = tool.get("description")
                if not isinstance(description, str) or not description.strip():
                    print(
                        f"Error in {tc}: tool must have a non-empty string "
                        "'description'"
                    )
                    valid = False

    # skills: array of {name, description} or null
    if "skills" in capabilities and capabilities["skills"] is not None:
        skills = capabilities["skills"]
        if not isinstance(skills, list):
            print(f"Error in {context}: 'capabilities.skills' must be an array or null")
            valid = False
        else:
            seen_skill_names = set()
            for idx, skill in enumerate(skills):
                sc = f"{context} -> skills[{idx}]"
                if not isinstance(skill, dict):
                    print(f"Error in {sc}: each skill must be an object")
                    valid = False
                    continue
                name = skill.get("name")
                if not isinstance(name, str) or not name.strip():
                    print(
                        f"Error in {sc}: skill must have a non-empty string 'name'"
                    )
                    valid = False
                else:
                    name = name.strip()
                    if name in seen_skill_names:
                        print(f"Error in {sc}: duplicate skill name '{name}'")
                        valid = False
                    seen_skill_names.add(name)
                description = skill.get("description")
                if not isinstance(description, str) or not description.strip():
                    print(
                        f"Error in {sc}: skill must have a non-empty string "
                        "'description'"
                    )
                    valid = False

    # routes (v2): array of {name, description}
    if "routes" in capabilities and capabilities["routes"] is not None:
        routes = capabilities["routes"]
        if not isinstance(routes, list):
            print(f"Error in {context}: 'capabilities.routes' must be an array or null")
            valid = False
        else:
            seen_route_names = set()
            for idx, route in enumerate(routes):
                rc = f"{context} -> routes[{idx}]"
                if not isinstance(route, dict):
                    print(f"Error in {rc}: each route must be an object")
                    valid = False
                    continue
                name = route.get("name")
                if not isinstance(name, str) or not name.strip():
                    print(
                        f"Error in {rc}: route must have a non-empty string 'name'"
                    )
                    valid = False
                else:
                    name = name.strip()
                    if name in seen_route_names:
                        print(f"Error in {rc}: duplicate route name '{name}'")
                        valid = False
                    seen_route_names.add(name)
                description = route.get("description")
                if not isinstance(description, str) or not description.strip():
                    print(
                        f"Error in {rc}: route must have a non-empty string "
                        "'description'"
                    )
                    valid = False

    # config (v2): object (validated at runtime by host, just type-check here)
    if "config" in capabilities and capabilities["config"] is not None:
        if not isinstance(capabilities["config"], dict):
            print(f"Error in {context}: 'capabilities.config' must be an object or null")
            valid = False

    # web (v2): object (validated at runtime by host, just type-check here)
    if "web" in capabilities and capabilities["web"] is not None:
        if not isinstance(capabilities["web"], dict):
            print(f"Error in {context}: 'capabilities.web' must be an object or null")
            valid = False

    return valid


def parse_skill_frontmatter(skill_text, context):
    """Parse the required scalar name/description from SKILL.md frontmatter."""
    if not isinstance(skill_text, str):
        print(f"Error in {context}: top-level 'skill' must be a string")
        return None

    lines = skill_text.splitlines()
    if not lines or lines[0].strip() != "---":
        print(f"Error in {context}: skill must start with YAML frontmatter ('---')")
        return None

    try:
        closing_index = next(
            idx for idx, line in enumerate(lines[1:], start=1) if line.strip() == "---"
        )
    except StopIteration:
        print(f"Error in {context}: skill YAML frontmatter is not closed")
        return None

    values = {}
    for line in lines[1:closing_index]:
        if not line or line[0].isspace() or ":" not in line:
            continue
        key, raw_value = line.split(":", 1)
        key = key.strip()
        if key not in {"name", "description"}:
            continue
        if key in values:
            print(f"Error in {context}: duplicate skill frontmatter key '{key}'")
            return None
        value = raw_value.strip()
        if len(value) >= 2 and value[0] == value[-1] == '"':
            try:
                value = json.loads(value)
            except json.JSONDecodeError:
                print(
                    f"Error in {context}: invalid quoted value for skill "
                    f"frontmatter '{key}'"
                )
                return None
        elif len(value) >= 2 and value[0] == value[-1] == "'":
            value = value[1:-1].replace("''", "'")
        values[key] = value

    for field in ("name", "description"):
        value = values.get(field)
        if not isinstance(value, str) or not value.strip():
            print(
                f"Error in {context}: skill frontmatter requires a non-empty "
                f"'{field}'"
            )
            return None
        values[field] = value.strip()
    return values


def validate_skill(skill_text, capabilities, context):
    """Require embedded SKILL.md metadata to match capabilities.skills."""
    frontmatter = parse_skill_frontmatter(skill_text, context)
    if frontmatter is None:
        return False

    skills = capabilities.get("skills") if isinstance(capabilities, dict) else None
    if not isinstance(skills, list) or not skills:
        print(
            f"Error in {context}: embedded skill requires a non-empty "
            "'capabilities.skills' array"
        )
        return False

    matches = [
        skill
        for skill in skills
        if isinstance(skill, dict)
        and skill.get("name") == frontmatter["name"]
        and skill.get("description") == frontmatter["description"]
    ]
    if len(matches) != 1:
        print(
            f"Error in {context}: skill frontmatter name/description must match "
            "exactly one capabilities.skills entry"
        )
        return False
    return True


def validate_docs(docs, context):
    """Validate the optional docs object (v2)."""
    if not isinstance(docs, dict):
        print(f"Error in {context}: 'docs' must be a dictionary")
        return False

    valid = True

    if "readme" in docs and not isinstance(docs["readme"], str):
        print(f"Error in {context}: 'docs.readme' must be a string")
        valid = False
    if "changelog" in docs and not isinstance(docs["changelog"], str):
        print(f"Error in {context}: 'docs.changelog' must be a string")
        valid = False

    if "links" in docs:
        links = docs["links"]
        if not isinstance(links, list):
            print(f"Error in {context}: 'docs.links' must be an array")
            valid = False
        else:
            for idx, link in enumerate(links):
                lc = f"{context} -> links[{idx}]"
                if not isinstance(link, dict):
                    print(f"Error in {lc}: each link must be an object")
                    valid = False
                    continue
                if "label" not in link or not isinstance(link["label"], str):
                    print(f"Error in {lc}: link must have a string 'label'")
                    valid = False
                if "url" not in link or not isinstance(link["url"], str):
                    print(f"Error in {lc}: link must have a string 'url'")
                    valid = False

    return valid


def validate_artifact(artifact, context):
    missing = REQUIRED_ARTIFACT_LEVEL - set(artifact.keys())
    if missing:
        print(f"Error in {context}: Missing required artifact fields: {missing}")
        return False
    
    if artifact["os"] not in VALID_OS:
        print(f"Error in {context}: Invalid OS '{artifact['os']}'. Must be one of {VALID_OS}")
        return False
        
    if artifact["arch"] not in VALID_ARCH:
        print(f"Error in {context}: Invalid Architecture '{artifact['arch']}'. Must be one of {VALID_ARCH}")
        return False

    # URL Check: Verify urls are HTTPS
    if not artifact["url"].startswith("https://"):
        print(f"Error in {context}: URL must start with https://")
        return False
        
    if not re.match(r"^[a-fA-F0-9]{64}$", artifact["sha256"]):
        print(f"Error in {context}: Invalid SHA256 checksum format")
        return False
    
    # Validate minisign signature object
    if not validate_minisign_signature(artifact["minisign"], f"{context} -> minisign"):
        return False
        
    return True

def validate_version(entry, context, public_key=None, verify_signatures=False):
    missing = REQUIRED_VERSION_LEVEL - set(entry.keys())
    if missing:
        print(f"Error in {context}: Missing required version fields: {missing}")
        return False
        
    if not validate_semver(entry["version"]):
        print(f"Error in {context}: Invalid Semantic Version '{entry['version']}'")
        return False
        
    if not isinstance(entry["artifacts"], list) or not entry["artifacts"]:
        print(f"Error in {context}: 'artifacts' must be a non-empty list")
        return False

    valid = True
    has_macos_arm64 = False
    
    for idx, artifact in enumerate(entry["artifacts"]):
        artifact_context = f"{context} -> artifact[{idx}]"
        if not validate_artifact(artifact, artifact_context):
            valid = False
        else:
            if artifact["os"] == "macos" and artifact["arch"] == "arm64":
                has_macos_arm64 = True
            
            # Verify signature if enabled and public key available
            if verify_signatures and public_key:
                if not verify_artifact_signature(artifact, public_key, artifact_context):
                    valid = False
            
    # Artifact Check: Ensure at least one macos/arm64 artifact exists per version
    if not has_macos_arm64:
        print(f"Error in {context}: Must contain at least one artifact for macos/arm64")
        valid = False
            
    # Check requirements if present
    if "requires" in entry:
        reqs = entry["requires"]
        if "osaurus_min_version" in reqs:
            if not validate_semver(reqs["osaurus_min_version"]):
                 print(f"Error in {context}: Invalid osaurus_min_version '{reqs['osaurus_min_version']}'")
                 valid = False
                 
    return valid

def validate_plugin_file(filepath, seen_ids):
    print(f"Validating {filepath}...")
    try:
        with open(filepath, 'r') as f:
            data = json.load(f)
    except json.JSONDecodeError as e:
        print(f"Error: Invalid JSON in {filepath}: {e}")
        return False
        
    missing = REQUIRED_TOP_LEVEL - set(data.keys())
    if missing:
        print(f"Error: Missing required top-level fields in {filepath}: {missing}")
        return False
    
    plugin_id = data.get("plugin_id", "")
    
    # Consistency Check: Ensure plugin_id matches the filename
    filename = os.path.basename(filepath)
    if not filename.endswith(".json"):
        print(f"Error: File {filepath} must end in .json")
        return False
        
    expected_id = filename[:-5] # remove .json
    if plugin_id != expected_id:
        print(f"Error: plugin_id '{plugin_id}' does not match filename '{filename}' (expected '{expected_id}')")
        return False
        
    if plugin_id != plugin_id.lower():
        print(f"Error: plugin_id '{plugin_id}' must be lower-case")
        return False

    if not re.match(r"^[a-z0-9]+(\.[a-z0-9_-]+)+$", plugin_id):
        print(
            f"Error: plugin_id '{plugin_id}' must be in dot-separated format "
            "(e.g., com.example.plugin)"
        )
        return False

    # Unique Constraint: Ensure no duplicate plugin_ids (case-insensitive)
    lower_id = plugin_id.lower()
    if lower_id in seen_ids:
        print(f"Error: Duplicate plugin_id found: '{plugin_id}'. Another file already uses this ID (case-insensitive match).")
        return False
    seen_ids.add(lower_id)

    if not isinstance(data["versions"], list):
        print(f"Error: 'versions' must be a list in {filepath}")
        return False

    # Validate public_keys (required even for unreleased plugins)
    if not validate_public_keys(data["public_keys"], filepath):
        return False
    
    public_key = data["public_keys"]["minisign"]
    
    # Check public key immutability (only in PR context)
    if not check_public_key_immutability(filepath, public_key):
        return False

    # Validate optional v2 fields
    if "secrets" in data:
        if not validate_secrets(data["secrets"], filepath):
            return False

    if "capabilities" in data:
        if not validate_capabilities(data["capabilities"], filepath):
            return False

    if "skill" in data:
        if not validate_skill(data["skill"], data.get("capabilities"), filepath):
            return False

    if "docs" in data:
        if not validate_docs(data["docs"], filepath):
            return False

    if not validate_requires(data, filepath):
        return False

    # Empty versions array is allowed for unreleased plugins
    if len(data["versions"]) == 0:
        print(f"  Note: No versions published yet for {plugin_id}")
        return True

    if not validate_versions_order(data["versions"], filepath):
        return False

    # Check if signature verification is enabled (via environment variable)
    verify_signatures = os.environ.get("VERIFY_SIGNATURES", "").lower() in ("1", "true", "yes")
    
    if verify_signatures:
        # Check if minisign is available
        if shutil.which("minisign") is None:
            print("Error: VERIFY_SIGNATURES is enabled but minisign is not installed")
            return False
        print(f"  Signature verification enabled for {plugin_id}")

    valid = True
    for idx, version_entry in enumerate(data["versions"]):
        if not validate_version(version_entry, f"{filepath} -> version[{idx}]", public_key, verify_signatures):
            valid = False
            
    return valid

def main():
    # Look for plugins directory relative to this script
    script_dir = os.path.dirname(os.path.abspath(__file__))
    plugins_dir = os.path.join(os.path.dirname(script_dir), "plugins")
    
    if not os.path.isdir(plugins_dir):
        print(f"Error: plugins directory not found at {plugins_dir}")
        sys.exit(1)

    json_files = glob.glob(os.path.join(plugins_dir, "*.json"))
    
    if not json_files:
        print("No plugin files found to validate.")
        # Not an error, just empty repo check
        return 0 

    failed = False
    seen_ids = set()
    
    for json_file in json_files:
        if not validate_plugin_file(json_file, seen_ids):
            failed = True

    if failed:
        print("\nValidation FAILED.")
        sys.exit(1)
    else:
        print("\nAll plugins validated successfully.")
        sys.exit(0)

if __name__ == "__main__":
    main()

