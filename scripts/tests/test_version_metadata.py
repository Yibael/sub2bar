import datetime
import importlib.util
import os
import pathlib
import plistlib
import sys
import subprocess
import tempfile
import textwrap
import unittest

SCRIPTS = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import version_metadata as metadata

spec = importlib.util.spec_from_file_location("verify_release", SCRIPTS / "verify-release.py")
release = importlib.util.module_from_spec(spec)
spec.loader.exec_module(release)


class VersionMetadataTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = pathlib.Path(self.directory.name)
        (self.root / "Resources").mkdir()
        self.template = self.root / "Resources/Info.plist"
        self.template.write_bytes(plistlib.dumps({"CFBundleIdentifier": "com.sub2bar.app", "LSUIElement": True}))
        (self.root / "VERSION").write_text("0.1.0-beta.1\n")
        (self.root / "CHANGELOG.md").write_text("# Changelog\n\n## [0.1.0-beta.1]\n")

    def test_supported_versions(self):
        for version in ["0.1.0", "0.1.0-alpha.1", "0.1.0-beta.1", "0.1.0-rc.12"]:
            with self.subTest(version=version):
                self.assertEqual(metadata.parse_version(version), ("0.1.0", "-" in version))

    def test_rejects_ambiguous_or_unsafe_versions(self):
        for version in ["v0.1.0", "01.1.0", "0.01.0", "0.1.00", "0.1", "0.1.0-beta", "0.1.0-beta.0",
                        "0.1.0-beta.01", "0.1.0-preview.1", "0.1.0+build", "0.1.0\n", "../0.1.0", "0.1.0;echo"]:
            with self.subTest(version=version), self.assertRaises(ValueError):
                metadata.parse_version(version)

    def test_ci_build_increases_for_runs_and_attempts(self):
        builds = []
        for run, attempt in [(11, 1), (11, 2), (12, 1)]:
            number, source = metadata.automatic_build({"GITHUB_ACTIONS": "true", "GITHUB_RUN_NUMBER": str(run), "GITHUB_RUN_ATTEMPT": str(attempt)})
            self.assertEqual(source, "github")
            self.assertRegex(number, metadata.BUILD_PATTERN)
            builds.append(tuple(map(int, number.split("."))))
        self.assertEqual(builds, [(11, 1, 0), (11, 2, 0), (12, 1, 0)])

    def test_ci_metadata_never_silently_falls_back(self):
        for run, attempt in [("", "1"), ("1", ""), ("0", "1"), ("01", "1"), ("10000", "1"), ("1", "100"), ("oops", "1")]:
            with self.subTest(run=run, attempt=attempt), self.assertRaises(ValueError):
                metadata.automatic_build({"GITHUB_ACTIONS": "true", "GITHUB_RUN_NUMBER": run, "GITHUB_RUN_ATTEMPT": attempt})

    def test_local_rebuild_increments_even_with_clock_rollback(self):
        now = datetime.datetime(2026, 9, 16, tzinfo=datetime.timezone.utc)
        number, source = metadata.automatic_build({}, now=now)
        previous = {"CFBundleVersion": number, "Sub2BarBuildSource": source}
        next_number, _ = metadata.automatic_build({}, previous, now - datetime.timedelta(hours=1))
        self.assertGreater(tuple(map(int, next_number.split("."))), tuple(map(int, number.split("."))))
        self.assertRegex(next_number, metadata.BUILD_PATTERN)

    def test_local_number_rollover_and_range(self):
        previous = {"CFBundleVersion": "1.99.99", "Sub2BarBuildSource": "local"}
        self.assertEqual(metadata.automatic_build({}, previous, metadata.EPOCH), ("2.0.0", "local"))
        with self.assertRaises(ValueError):
            metadata.automatic_build({}, now=metadata.EPOCH - datetime.timedelta(minutes=1))
        with self.assertRaises(ValueError):
            metadata.automatic_build({}, {"CFBundleVersion": "invalid", "Sub2BarBuildSource": "local"}, metadata.EPOCH)

    def test_writes_metadata_without_mutating_source(self):
        original = self.template.read_bytes()
        output = self.root / "output/Sub2Bar.app/Contents/Info.plist"
        env = {"GITHUB_ACTIONS": "true", "GITHUB_RUN_NUMBER": "12", "GITHUB_RUN_ATTEMPT": "2"}
        info = metadata.write_bundle_info(output, self.root, env)
        self.assertEqual(info["Sub2BarVersion"], "0.1.0-beta.1")
        self.assertEqual(info["CFBundleShortVersionString"], "0.1.0")
        self.assertEqual(info["CFBundleVersion"], "12.2.0")
        self.assertEqual(info["CFBundleIdentifier"], "com.sub2bar.app")
        self.assertTrue(info["LSUIElement"])
        self.assertEqual(plistlib.loads(output.read_bytes()), info)
        self.assertEqual(self.template.read_bytes(), original)
        self.assertEqual((self.root / "VERSION").read_text(), "0.1.0-beta.1\n")

    def test_local_output_rebuild_uses_previous_number(self):
        output = self.root / "output/Info.plist"
        first = metadata.write_bundle_info(output, self.root, {}, metadata.EPOCH)
        second = metadata.write_bundle_info(output, self.root, {}, metadata.EPOCH)
        self.assertEqual(first["CFBundleVersion"], "1.0.0")
        self.assertEqual(second["CFBundleVersion"], "1.0.1")

    def test_cannot_overwrite_source_template_or_duplicate_version(self):
        with self.assertRaises(ValueError):
            metadata.write_bundle_info(self.template, self.root, {})
        self.template.write_bytes(plistlib.dumps({"CFBundleVersion": "10"}))
        with self.assertRaises(ValueError):
            metadata.read_template(self.root)

    def test_release_accepts_beta_and_stable(self):
        self.assertTrue(release.verify_release("v0.1.0-beta.1", self.root))
        (self.root / "VERSION").write_text("0.1.0\n")
        (self.root / "CHANGELOG.md").write_text("## [0.1.0]\n")
        self.assertFalse(release.verify_release("v0.1.0", self.root))

    def test_release_rejects_mismatch_or_missing_heading(self):
        for tag in ["0.1.0-beta.1", "v0.1.0-beta.2", "v0.1.0"]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.verify_release(tag, self.root)
        (self.root / "CHANGELOG.md").write_text("Mention ## [0.1.0-beta.1] inline only\n")
        with self.assertRaises(ValueError):
            release.verify_release("v0.1.0-beta.1", self.root)

    def run_publish_step(self, classification):
        # Execute the actual workflow shell with an in-process gh stub. This
        # cannot access credentials, GitHub, or create a real release.
        workflow = (SCRIPTS.parent / ".github/workflows/release.yml").read_text()
        step = workflow.split("- name: Create draft, then publish complete release", 1)[1]
        script = textwrap.dedent(step.split("run: |\n", 1)[1])
        stub = "gh() { printf '%s\\0' COMMAND \"$@\"; }\n"
        return subprocess.run(["bash", "-euo", "pipefail", "-c", stub + script], cwd=self.root,
                              env={"PATH": os.defpath, "IS_PRERELEASE": classification,
                                   "RELEASE_TAG": "v0.1.0-beta.1" if classification == "true" else "v0.1.0",
                                   "GH_REPO": "example/fixture"}, capture_output=True)

    def test_publish_beta_keeps_prerelease_and_never_latest_in_both_steps(self):
        result = self.run_publish_step("true")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        calls = result.stdout.decode().split("COMMAND\0")[1:]
        self.assertEqual(len(calls), 2)
        for call in calls:
            args = call.split("\0")
            self.assertIn("--prerelease", args)
            self.assertIn("--latest=false", args)
        self.assertIn("--draft=false", calls[1].split("\0"))

    def test_publish_stable_does_not_set_prerelease_or_override_latest(self):
        result = self.run_publish_step("false")
        self.assertEqual(result.returncode, 0, result.stderr.decode())
        self.assertEqual(result.stdout.count(b"--prerelease=false\0"), 2)
        self.assertNotIn(b"--latest", result.stdout)

    def test_release_title_is_only_the_version_tag(self):
        for classification, tag in [("true", "v0.1.0-beta.1"), ("false", "v0.1.0")]:
            with self.subTest(classification=classification):
                result = self.run_publish_step(classification)
                self.assertEqual(result.returncode, 0, result.stderr.decode())
                create_args = result.stdout.decode().split("COMMAND\0")[1].split("\0")
                self.assertEqual(create_args[create_args.index("--title") + 1], tag)

    def test_workflows_run_all_tests_on_apple_silicon_and_keep_universal_build(self):
        for name in ["ci.yml", "release.yml"]:
            with self.subTest(workflow=name):
                workflow = (SCRIPTS.parent / ".github/workflows" / name).read_text()
                self.assertNotIn("macos-15-intel", workflow)
                self.assertNotIn("--skip", workflow)
                self.assertIn("runs-on: macos-26", workflow)
                self.assertIn('run: swift test --scratch-path "$RUNNER_TEMP/sub2bar-tests"', workflow)
                self.assertRegex(workflow, r"run: bash scripts/build-app\.sh [^\n]+ universal")

    def test_publish_rejects_missing_classification_before_any_gh_command(self):
        result = self.run_publish_step("")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"COMMAND\0", result.stdout)


if __name__ == "__main__":
    unittest.main()
