#!/usr/bin/env python3
# Regression tests for scripts/validate.py.
#
# Run with:
#   python3 scripts/test_validate.py
#
# No network access, credentials, or minisign installation required.

import hashlib
import importlib.util
import os
import sys
import tempfile
import unittest

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

_spec = importlib.util.spec_from_file_location(
    "validate", os.path.join(SCRIPT_DIR, "validate.py")
)
validate = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(validate)


def _artifact(url, sha256):
    return {
        "os": "macos",
        "arch": "arm64",
        "url": url,
        "sha256": sha256,
        "minisign": {
            "signature": (
                "untrusted comment: sig\n"
                "RWTdummydummydummydummydummydummydummydummydummydummy==\n"
                "trusted comment: ts\n"
                "RWTdummydummydummydummydummydummydummydummydummydummy==\n"
            )
        },
    }


class TestSemverOrdering(unittest.TestCase):
    def test_sort_key_orders_numerically_not_lexicographically(self):
        versions = ["1.0.4", "1.0.10", "1.0.9"]
        ordered = sorted(versions, key=validate.semver_sort_key, reverse=True)
        self.assertEqual(ordered, ["1.0.10", "1.0.9", "1.0.4"])

    def test_prerelease_sorts_below_release(self):
        versions = ["1.0.0", "1.0.0-beta", "1.0.0-alpha"]
        ordered = sorted(versions, key=validate.semver_sort_key, reverse=True)
        self.assertEqual(ordered, ["1.0.0", "1.0.0-beta", "1.0.0-alpha"])

    def test_descending_order_passes(self):
        versions = [{"version": v} for v in ["2.0.0", "1.0.10", "1.0.2"]]
        self.assertTrue(validate.validate_versions_order(versions, "test.json"))

    def test_ascending_order_fails(self):
        versions = [{"version": v} for v in ["1.0.0", "1.0.1", "2.0.0"]]
        self.assertFalse(validate.validate_versions_order(versions, "test.json"))

    def test_lexicographic_order_fails(self):
        # jq's unique_by produces this order; it is wrong for semver.
        versions = [{"version": v} for v in ["1.0.10", "1.0.4", "1.0.9"]]
        self.assertFalse(validate.validate_versions_order(versions, "test.json"))

    def test_duplicate_versions_fail(self):
        versions = [{"version": v} for v in ["1.0.1", "1.0.1", "1.0.0"]]
        self.assertFalse(validate.validate_versions_order(versions, "test.json"))


class TestRequires(unittest.TestCase):
    def test_top_level_requires_passes(self):
        data = {"requires": {"min_macos": "13.0", "osaurus_min_version": "0.5.0"}}
        self.assertTrue(validate.validate_requires(data, "test.json"))

    def test_core_tool_min_osaurus_passes(self):
        data = {"min_osaurus": "0.5.0", "min_macos": "13.0"}
        self.assertTrue(validate.validate_requires(data, "test.json"))

    def test_missing_requires_fails(self):
        self.assertFalse(validate.validate_requires({}, "test.json"))

    def test_requires_without_min_version_fails(self):
        data = {"requires": {"min_macos": "13.0"}}
        self.assertFalse(validate.validate_requires(data, "test.json"))

    def test_invalid_semver_fails(self):
        data = {"requires": {"osaurus_min_version": "not-a-version"}}
        self.assertFalse(validate.validate_requires(data, "test.json"))


class TestCapabilitiesToolNames(unittest.TestCase):
    @staticmethod
    def _caps(tools):
        return {"tools": tools}

    def test_unique_named_tools_pass(self):
        caps = self._caps(
            [
                {"name": "search", "description": "Web search."},
                {"name": "search_news", "description": "News search."},
            ]
        )
        self.assertTrue(validate.validate_capabilities(caps, "test.json"))

    def test_duplicate_tool_names_fail(self):
        caps = self._caps(
            [
                {"name": "search", "description": "Web search."},
                {"name": "search", "description": "Web search again."},
            ]
        )
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_missing_tool_name_fails(self):
        caps = self._caps([{"description": "No name here."}])
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_empty_tool_name_fails(self):
        caps = self._caps([{"name": "   ", "description": "Blank name."}])
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_non_string_tool_name_fails(self):
        caps = self._caps([{"name": 42, "description": "Numeric name."}])
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_non_object_tool_fails(self):
        caps = self._caps(["search"])
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_missing_tool_description_fails(self):
        caps = self._caps([{"name": "search"}])
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_empty_tool_description_fails(self):
        caps = self._caps([{"name": "search", "description": "  "}])
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_empty_tools_array_passes(self):
        self.assertTrue(validate.validate_capabilities(self._caps([]), "test.json"))


class TestCapabilitiesSkills(unittest.TestCase):
    def test_unique_named_skills_pass(self):
        caps = {
            "skills": [
                {"name": "calendar", "description": "Use when managing events."},
                {"name": "mail", "description": "Use when managing email."},
            ]
        }
        self.assertTrue(validate.validate_capabilities(caps, "test.json"))

    def test_null_skills_pass_for_legacy_no_skill_catalogs(self):
        self.assertTrue(
            validate.validate_capabilities({"skills": None}, "test.json")
        )

    def test_duplicate_skill_names_fail(self):
        caps = {
            "skills": [
                {"name": "mail", "description": "Use when reading email."},
                {"name": "mail", "description": "Use when sending email."},
            ]
        }
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_missing_skill_name_fails(self):
        caps = {"skills": [{"description": "Use when managing email."}]}
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_empty_skill_description_fails(self):
        caps = {"skills": [{"name": "mail", "description": ""}]}
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))


class TestRoutes(unittest.TestCase):
    def test_named_described_routes_pass(self):
        caps = {
            "routes": [
                {"name": "webhook", "description": "Receive provider events."}
            ]
        }
        self.assertTrue(validate.validate_capabilities(caps, "test.json"))

    def test_empty_route_description_fails(self):
        caps = {"routes": [{"name": "webhook", "description": " "}]}
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))

    def test_duplicate_route_names_fail(self):
        caps = {
            "routes": [
                {"name": "webhook", "description": "Receive events."},
                {"name": "webhook", "description": "Receive more events."},
            ]
        }
        self.assertFalse(validate.validate_capabilities(caps, "test.json"))


class TestEmbeddedSkill(unittest.TestCase):
    SKILL = (
        "---\n"
        "name: osaurus-mail\n"
        "description: Use when reading or sending email.\n"
        "---\n"
        "\n"
        "# Mail\n"
    )

    def test_matching_skill_metadata_passes(self):
        caps = {
            "skills": [
                {
                    "name": "osaurus-mail",
                    "description": "Use when reading or sending email.",
                }
            ]
        }
        self.assertTrue(validate.validate_skill(self.SKILL, caps, "test.json"))

    def test_skill_must_be_a_string(self):
        self.assertFalse(validate.validate_skill({}, {"skills": []}, "test.json"))

    def test_frontmatter_is_required(self):
        self.assertFalse(
            validate.validate_skill(
                "# Mail\n", {"skills": []}, "test.json"
            )
        )

    def test_frontmatter_description_is_required(self):
        skill = "---\nname: osaurus-mail\n---\n# Mail\n"
        self.assertFalse(
            validate.validate_skill(skill, {"skills": []}, "test.json")
        )

    def test_frontmatter_must_match_capability(self):
        caps = {
            "skills": [
                {
                    "name": "different-name",
                    "description": "Use when reading or sending email.",
                }
            ]
        }
        self.assertFalse(validate.validate_skill(self.SKILL, caps, "test.json"))

    def test_frontmatter_description_must_match_capability(self):
        caps = {
            "skills": [
                {
                    "name": "osaurus-mail",
                    "description": "A different description.",
                }
            ]
        }
        self.assertFalse(validate.validate_skill(self.SKILL, caps, "test.json"))


class TestArtifactVerification(unittest.TestCase):
    PUBKEY = "RWTmCafy0+6ViS/ZFdYN+4v3ATECbUamgj4WDgGz7R2/DD1UEHp1eXwt"

    def test_unreachable_artifact_fails(self):
        artifact = _artifact("file:///nonexistent/osaurus-test-artifact.zip", "0" * 64)
        self.assertFalse(
            validate.verify_artifact_signature(artifact, self.PUBKEY, "test")
        )

    def test_sha256_mismatch_fails(self):
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
            f.write(b"artifact contents")
            path = f.name
        try:
            artifact = _artifact("file://" + path, "0" * 64)
            self.assertFalse(
                validate.verify_artifact_signature(artifact, self.PUBKEY, "test")
            )
        finally:
            os.unlink(path)

    @unittest.skipIf(
        validate.shutil.which("minisign") is None, "minisign not installed"
    )
    def test_correct_sha256_reaches_signature_check(self):
        contents = b"artifact contents"
        with tempfile.NamedTemporaryFile(suffix=".zip", delete=False) as f:
            f.write(contents)
            path = f.name
        try:
            sha = hashlib.sha256(contents).hexdigest()
            # sha256 matches but the dummy signature is invalid, so
            # verification must still fail at the minisign step.
            artifact = _artifact("file://" + path, sha)
            self.assertFalse(
                validate.verify_artifact_signature(artifact, self.PUBKEY, "test")
            )
        finally:
            os.unlink(path)

    def test_key_rotation_allowlist_removed(self):
        self.assertFalse(hasattr(validate, "KEY_ROTATION_ALLOWLIST"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
