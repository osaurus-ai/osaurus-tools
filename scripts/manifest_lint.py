#!/usr/bin/env python3
"""Static conformance checks for extracted Osaurus plugin manifests."""

from __future__ import annotations

import argparse
import json
import re
import sys
from typing import Any

PLUGIN_ID_RE = re.compile(r"^[a-z0-9]+(?:\.[a-z0-9_-]+)+$")
IDENTIFIER_RE = re.compile(r"^[a-z][a-z0-9]*(?:_[a-z0-9]+)*$")
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)"
    r"(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)

TOOL_FIELDS = {
    "id",
    "description",
    "parameters",
    "requirements",
    "permission_policy",
}
CAPABILITY_FIELDS = {"tools", "routes", "config", "web", "artifact_handler"}
ROUTE_FIELDS = {"id", "path", "methods", "description", "auth"}
PERMISSION_POLICIES = {"ask", "auto", "deny"}
ROUTE_AUTH_LEVELS = {"none", "verify", "owner"}
HTTP_METHOD_RE = re.compile(r"^[A-Z]+$")


def _non_empty_string(value: Any) -> bool:
    return isinstance(value, str) and bool(value.strip())


def _lint_nested_schema(schema: Any, context: str, errors: list[str]) -> None:
    if not isinstance(schema, dict):
        errors.append(f"{context} schema must be an object")
        return

    if schema.get("type") == "object":
        properties = schema.get("properties")
        if not isinstance(properties, dict):
            errors.append(f"{context} must declare an object 'properties'")
            properties = {}
        if schema.get("additionalProperties") is not False:
            errors.append(f"{context} must set additionalProperties to false")
        required = schema.get("required")
        if not isinstance(required, list):
            errors.append(f"{context} must declare a 'required' array")
        else:
            unknown = sorted(
                field
                for field in required
                if isinstance(field, str) and field not in properties
            )
            if unknown:
                errors.append(
                    f"{context}.required references unknown properties: {unknown}"
                )
        for name, child in properties.items():
            _lint_nested_schema(child, f"{context}.properties.{name}", errors)

    if schema.get("type") == "array":
        if "items" not in schema:
            errors.append(f"{context} array schema must declare 'items'")
        else:
            _lint_nested_schema(schema["items"], f"{context}.items", errors)

    for keyword in ("allOf", "anyOf", "oneOf"):
        if keyword not in schema:
            continue
        branches = schema[keyword]
        if not isinstance(branches, list) or not branches:
            errors.append(f"{context}.{keyword} must be a non-empty array")
            continue
        for index, branch in enumerate(branches):
            _lint_nested_schema(branch, f"{context}.{keyword}[{index}]", errors)


def _lint_parameters(parameters: Any, context: str, errors: list[str]) -> None:
    if not isinstance(parameters, dict):
        errors.append(f"{context} 'parameters' must be an object")
        return
    if parameters.get("type") != "object":
        errors.append(f"{context} parameters must declare type 'object'")
    properties = parameters.get("properties")
    if not isinstance(properties, dict):
        errors.append(f"{context} parameters must declare an object 'properties'")
        properties = {}
    if parameters.get("additionalProperties") is not False:
        errors.append(f"{context} parameters must set additionalProperties to false")

    required = parameters.get("required")
    if not isinstance(required, list):
        errors.append(f"{context} parameters must declare a 'required' array")
        return
    if any(not _non_empty_string(field) for field in required):
        errors.append(f"{context} parameters.required must contain non-empty strings")
    if len(required) != len(set(required)):
        errors.append(f"{context} parameters.required contains duplicates")
    unknown = sorted(
        field for field in required if isinstance(field, str) and field not in properties
    )
    if unknown:
        errors.append(
            f"{context} parameters.required references unknown properties: {unknown}"
        )
    for name, schema in properties.items():
        _lint_nested_schema(
            schema, f"{context} parameters.properties.{name}", errors
        )


def _lint_tools(tools: Any, errors: list[str]) -> None:
    if not isinstance(tools, list):
        errors.append("capabilities.tools must be an array")
        return

    seen_ids: set[str] = set()
    for index, tool in enumerate(tools):
        context = f"tool at index {index}"
        if not isinstance(tool, dict):
            errors.append(f"{context} is not an object")
            continue

        unsupported = sorted(set(tool) - TOOL_FIELDS)
        if unsupported:
            errors.append(
                f"{context} has unsupported fields: {unsupported}; "
                f"supported fields are {sorted(TOOL_FIELDS)}"
            )

        missing = sorted(TOOL_FIELDS - set(tool))
        if missing:
            errors.append(f"{context} is missing required fields: {missing}")

        tool_id = tool.get("id")
        if not _non_empty_string(tool_id):
            errors.append(f"{context} has a missing or empty id")
            label = context
        else:
            label = f"tool '{tool_id}'"
            if not IDENTIFIER_RE.fullmatch(tool_id):
                errors.append(f"{label} id must be snake_case")
            if tool_id in seen_ids:
                errors.append(f"duplicate tool id '{tool_id}'")
            seen_ids.add(tool_id)

        if not _non_empty_string(tool.get("description")):
            errors.append(f"{label} lacks a description")

        _lint_parameters(tool.get("parameters"), label, errors)

        requirements = tool.get("requirements")
        if not isinstance(requirements, list):
            errors.append(f"{label} 'requirements' must be an array")
        else:
            invalid = [
                item for item in requirements if not _non_empty_string(item)
            ]
            if invalid:
                errors.append(
                    f"{label} requirements must contain non-empty strings"
                )
            normalized = [
                item.strip() for item in requirements if isinstance(item, str)
            ]
            if len(normalized) != len(set(normalized)):
                errors.append(f"{label} requirements contains duplicates")

        policy = tool.get("permission_policy")
        if policy not in PERMISSION_POLICIES:
            errors.append(
                f"{label} has invalid permission_policy {policy!r}; "
                f"expected one of {sorted(PERMISSION_POLICIES)}"
            )


def _lint_routes(routes: Any, errors: list[str]) -> None:
    if not isinstance(routes, list):
        errors.append("capabilities.routes must be an array")
        return

    seen_ids: set[str] = set()
    for index, route in enumerate(routes):
        context = f"route at index {index}"
        if not isinstance(route, dict):
            errors.append(f"{context} is not an object")
            continue

        unsupported = sorted(set(route) - ROUTE_FIELDS)
        if unsupported:
            errors.append(f"{context} has unsupported fields: {unsupported}")

        route_id = route.get("id")
        if not _non_empty_string(route_id):
            errors.append(f"{context} lacks an id")
            label = context
        else:
            label = f"route '{route_id}'"
            if not IDENTIFIER_RE.fullmatch(route_id):
                errors.append(f"{label} id must be snake_case")
            if route_id in seen_ids:
                errors.append(f"duplicate route id '{route_id}'")
            seen_ids.add(route_id)

        if not _non_empty_string(route.get("description")):
            errors.append(f"{label} lacks a description")

        path = route.get("path")
        if not _non_empty_string(path) or not path.startswith("/"):
            errors.append(f"{label} path must be a non-empty absolute route path")

        methods = route.get("methods")
        if (
            not isinstance(methods, list)
            or not methods
            or any(
                not isinstance(method, str) or not HTTP_METHOD_RE.fullmatch(method)
                for method in methods
            )
        ):
            errors.append(f"{label} methods must be a non-empty array of HTTP verbs")
        elif len(methods) != len(set(methods)):
            errors.append(f"{label} methods contains duplicates")

        if route.get("auth") not in ROUTE_AUTH_LEVELS:
            errors.append(
                f"{label} has invalid auth {route.get('auth')!r}; "
                f"expected one of {sorted(ROUTE_AUTH_LEVELS)}"
            )


def lint_manifest(
    manifest: Any, *, expected_version: str | None = None
) -> list[str]:
    """Return all static conformance errors for an extracted manifest."""
    errors: list[str] = []
    if not isinstance(manifest, dict):
        return ["manifest root must be an object"]

    plugin_id = manifest.get("plugin_id")
    if not _non_empty_string(plugin_id) or not PLUGIN_ID_RE.fullmatch(plugin_id):
        errors.append(
            f"plugin_id {plugin_id!r} is malformed "
            "(expected lowercase dot-separated, e.g. 'com.example.plugin')"
        )

    version = manifest.get("version")
    if not _non_empty_string(version):
        errors.append("manifest 'version' is missing or empty")
    elif not SEMVER_RE.fullmatch(version):
        errors.append(f"manifest version '{version}' is not valid semantic versioning")
    elif expected_version is not None and version != expected_version:
        errors.append(
            f"manifest version '{version}' does not match "
            f"tag-derived version '{expected_version}'"
        )

    if not _non_empty_string(manifest.get("description")):
        errors.append("manifest 'description' is missing or empty")

    capabilities = manifest.get("capabilities")
    if not isinstance(capabilities, dict):
        errors.append("manifest 'capabilities' must be an object")
        return errors

    unsupported_capabilities = sorted(set(capabilities) - CAPABILITY_FIELDS)
    if unsupported_capabilities:
        errors.append(
            "capabilities has unsupported fields: "
            f"{unsupported_capabilities}; supported fields are "
            f"{sorted(CAPABILITY_FIELDS)}"
        )

    if "tools" in capabilities:
        _lint_tools(capabilities["tools"], errors)
    if "routes" in capabilities:
        _lint_routes(capabilities["routes"], errors)
    if "config" in capabilities and not isinstance(capabilities["config"], dict):
        errors.append("capabilities.config must be an object")
    if "web" in capabilities and not isinstance(capabilities["web"], dict):
        errors.append("capabilities.web must be an object")
    if "artifact_handler" in capabilities and not isinstance(
        capabilities["artifact_handler"], bool
    ):
        errors.append("capabilities.artifact_handler must be a boolean")

    return errors


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, help="Path to manifest JSON")
    parser.add_argument(
        "--expected-version",
        required=True,
        help="Version derived from the release tag",
    )
    args = parser.parse_args(argv)

    try:
        with open(args.manifest, "r", encoding="utf-8") as manifest_file:
            manifest = json.load(manifest_file)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"::error::manifest conformance: could not read manifest: {exc}")
        return 1

    errors = lint_manifest(manifest, expected_version=args.expected_version)
    if errors:
        for error in errors:
            print(f"::error::manifest conformance: {error}")
        return 1

    print("Manifest conformance lint passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
