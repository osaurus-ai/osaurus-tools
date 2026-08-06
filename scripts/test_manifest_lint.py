#!/usr/bin/env python3
"""Regression tests for scripts/manifest_lint.py."""

import importlib.util
import os
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "manifest_lint", os.path.join(SCRIPT_DIR, "manifest_lint.py")
)
manifest_lint = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(manifest_lint)


def _tool(tool_id="read_items", **overrides):
    tool = {
        "id": tool_id,
        "description": "Read available items.",
        "parameters": {
            "type": "object",
            "properties": {"limit": {"type": "integer"}},
            "required": [],
            "additionalProperties": False,
        },
        "requirements": [],
        "permission_policy": "auto",
    }
    tool.update(overrides)
    return tool


def _manifest(**overrides):
    manifest = {
        "plugin_id": "com.example.items",
        "version": "2.0.0",
        "description": "Example item plugin.",
        "capabilities": {"tools": [_tool()]},
    }
    manifest.update(overrides)
    return manifest


class TestManifestLint(unittest.TestCase):
    def lint(self, manifest=None):
        return manifest_lint.lint_manifest(
            manifest or _manifest(), expected_version="2.0.0"
        )

    def assert_error_contains(self, text, manifest):
        self.assertTrue(
            any(text in error for error in self.lint(manifest)),
            msg=f"expected an error containing {text!r}",
        )

    def test_valid_manifest_passes(self):
        self.assertEqual(self.lint(), [])

    def test_version_must_match_release_tag(self):
        self.assert_error_contains(
            "does not match tag-derived version", _manifest(version="2.0.1")
        )

    def test_plugin_id_must_be_lowercase_dot_separated(self):
        self.assert_error_contains(
            "plugin_id", _manifest(plugin_id="ExamplePlugin")
        )

    def test_description_is_required(self):
        self.assert_error_contains(
            "'description' is missing or empty", _manifest(description=" ")
        )

    def test_duplicate_tool_ids_fail(self):
        manifest = _manifest(
            capabilities={"tools": [_tool(), _tool("read_items")]}
        )
        self.assert_error_contains("duplicate tool id", manifest)

    def test_tool_ids_must_be_snake_case(self):
        manifest = _manifest(capabilities={"tools": [_tool("readItems")]})
        self.assert_error_contains("must be snake_case", manifest)

    def test_tool_description_is_required(self):
        manifest = _manifest(
            capabilities={"tools": [_tool(description="")]}
        )
        self.assert_error_contains("lacks a description", manifest)

    def test_only_supported_tool_fields_are_allowed(self):
        tool = _tool()
        tool["annotations"] = {"readOnlyHint": True}
        tool["outputSchema"] = {"type": "object"}
        manifest = _manifest(capabilities={"tools": [tool]})
        errors = self.lint(manifest)
        self.assertTrue(any("annotations" in error for error in errors))
        self.assertTrue(any("outputSchema" in error for error in errors))

    def test_parameter_schema_requires_closed_object(self):
        tool = _tool(
            parameters={
                "type": "object",
                "properties": {},
                "required": [],
            }
        )
        manifest = _manifest(capabilities={"tools": [tool]})
        self.assert_error_contains("additionalProperties to false", manifest)

    def test_required_parameters_must_exist_in_properties(self):
        tool = _tool(
            parameters={
                "type": "object",
                "properties": {},
                "required": ["missing"],
                "additionalProperties": False,
            }
        )
        manifest = _manifest(capabilities={"tools": [tool]})
        self.assert_error_contains("unknown properties", manifest)

    def test_nested_objects_must_be_closed(self):
        tool = _tool(
            parameters={
                "type": "object",
                "properties": {
                    "filter": {
                        "type": "object",
                        "properties": {},
                        "required": [],
                    }
                },
                "required": [],
                "additionalProperties": False,
            }
        )
        manifest = _manifest(capabilities={"tools": [tool]})
        self.assert_error_contains(
            "parameters.properties.filter must set additionalProperties", manifest
        )

    def test_permission_policy_vocabulary_is_strict(self):
        manifest = _manifest(
            capabilities={"tools": [_tool(permission_policy="allow")]}
        )
        self.assert_error_contains("invalid permission_policy", manifest)

    def test_custom_requirement_names_are_supported(self):
        manifest = _manifest(
            capabilities={"tools": [_tool(requirements=["network"])]}
        )
        self.assertEqual(self.lint(manifest), [])

    def test_requirements_must_be_non_empty_strings(self):
        manifest = _manifest(
            capabilities={"tools": [_tool(requirements=[""])]}
        )
        self.assert_error_contains("requirements must contain", manifest)

    def test_route_requires_full_aligned_shape(self):
        route = {
            "id": "webhook",
            "path": "/webhook",
            "methods": ["POST"],
            "description": "Receive provider events.",
            "auth": "verify",
        }
        manifest = _manifest(
            capabilities={"tools": [_tool()], "routes": [route]}
        )
        self.assertEqual(self.lint(manifest), [])

    def test_route_description_is_required(self):
        route = {
            "id": "webhook",
            "path": "/webhook",
            "methods": ["POST"],
            "description": "",
            "auth": "verify",
        }
        manifest = _manifest(
            capabilities={"tools": [_tool()], "routes": [route]}
        )
        self.assert_error_contains("lacks a description", manifest)

    def test_unknown_capability_is_rejected(self):
        manifest = _manifest(
            capabilities={"tools": [_tool()], "skills": []}
        )
        self.assert_error_contains("capabilities has unsupported fields", manifest)


if __name__ == "__main__":
    unittest.main(verbosity=2)
