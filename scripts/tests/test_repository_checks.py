import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location("repository_checks", Path(__file__).resolve().parents[1] / "check-repository.py")
checker = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checker)


class RepositoryChecksTests(unittest.TestCase):
    def test_forbidden_files(self):
        for name in ["credential.json", "nested/credentials.json", ".env", ".env.production", "signing.p12", "private.key", "dist/app.zip", "Sub2Bar.app/Contents/MacOS/Sub2Bar", ".build/anything", "work/log.txt"]:
            with self.subTest(name=name):
                self.assertTrue(checker.forbidden_path(name))

    def test_sources_and_examples_allowed(self):
        for name in ["Sources/LocalCredentialStorage.swift", "Resources/Info.plist", "README.md", ".env.example", ".github/workflows/ci.yml"]:
            self.assertFalse(checker.forbidden_path(name))

    def test_credential_literal_never_allowed_in_production(self):
        sample = b'let adminKey = "' + b"placeholder-not-allowed" + b'"'
        self.assertTrue(checker.scan_content("Sources/Example.swift", sample))
        self.assertTrue(checker.scan_content(".env.example", sample))

    def test_provider_token(self):
        sample = b"sk-" + b"a1b2c3d4" * 6
        self.assertTrue(checker.scan_content("README.md", sample))

    def test_fake_values_only_allowed_in_test_files(self):
        sample = b'key: "' + b"fake-secret" + b'"'
        self.assertFalse(checker.scan_content("Tests/Example.swift", sample))
        self.assertTrue(checker.scan_content("Sources/Example.swift", sample))

    def test_variable_and_metadata_identifiers_are_not_credentials(self):
        for sample in [b'let defaultsKey = "sub2bar.configuration.v1"', b'forInfoDictionaryKey: "CFBundleVersion"', b'key: "' + b"${ADMIN_KEY}" + b'"']:
            self.assertFalse(checker.scan_content("Sources/Example.swift", sample))

    def test_private_key_marker(self):
        sample = b"-----BEGIN " + b"PRIVATE KEY-----"
        self.assertTrue(checker.scan_content("README.md", sample))

    def test_userinfo_url_fixture_only_allowed_in_tests(self):
        sample = b"https://user:" + b"secret@example.com"
        self.assertFalse(checker.scan_content("Tests/Example.swift", sample))
        self.assertTrue(checker.scan_content("README.md", sample))

    def test_results_never_contain_candidate_value(self):
        value = b"must-not-appear-in-output"
        findings = checker.scan_content("Sources/Example.swift", b'password = "' + value + b'"')
        self.assertTrue(findings)
        self.assertNotIn(value.decode(), repr(findings))


if __name__ == "__main__":
    unittest.main()
