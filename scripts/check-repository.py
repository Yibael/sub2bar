#!/usr/bin/env python3
"""Fail closed on forbidden staged files and common credential literals.

Only paths, line numbers and rule names are printed; never matched values.
Gitleaks in CI complements this fast, dependency-free local check.
"""
import argparse
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAX_BYTES = 2 * 1024 * 1024
FORBIDDEN_DIRS = {".build", ".swiftpm", "DerivedData", "dist", "build", "work", ".tools", "__pycache__", "xcuserdata"}
FORBIDDEN_SUFFIXES = {".zip", ".dmg", ".pkg", ".ipa", ".o", ".swiftmodule", ".swiftdoc", ".pem", ".key", ".p8", ".p12", ".pfx", ".mobileprovision", ".pyc", ".log", ".local"}
FIXTURES = {b"fake-secret", b"test-admin-key", b"fake-key", b"test-key", b"new-secret", b"old-secret", b"private secret", b"private-secret-error", b"not-a-secret", b"never-retained", b"private-invalid-payload", b"first", b"second", b"new", b"old", b"valid", b"fake", b"test", b"secret", b"password"}
RULES = {
    "private key": re.compile(rb"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"),
    "provider token": re.compile(rb"\b(?:sk-(?:proj-|ant-[\w-]*)?[A-Za-z0-9_-]{20,}|gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,}|AIza[0-9A-Za-z_-]{30,}|(?:AKIA|ASIA)[A-Z0-9]{16})\b"),
    "JWT": re.compile(rb"\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"),
}
LITERAL = re.compile(rb"(?i)(?<![A-Za-z0-9_])(?:[\"']?(?:admin[_-]?key|api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd|secret|key|token|candidateKey)[\"']?)\s*[:=]\s*[\"']([^\"'\r\n]{4,512})[\"']")
URL_PASSWORD = re.compile(rb"https?://[^\s/\"'<>:@]{1,80}:[^\s/\"'<>@]{1,100}@[^\s/\"'<>]+")


def forbidden_path(name):
    path = pathlib.PurePosixPath(name)
    if any(part in FORBIDDEN_DIRS or part.endswith((".app", ".dSYM", ".xcresult")) for part in path.parts):
        return True
    base = path.name.lower()
    return (path.suffix.lower() in FORBIDDEN_SUFFIXES or base in {".ds_store", "id_rsa", "id_ed25519", "credential.json", "credentials.json"}
            or (base.startswith(".env") and base not in {".env.example", ".env.sample"})
            or ("credential" in base and base.endswith(".json")) or base.startswith("._"))


def is_fixture(name, value):
    return (name.startswith("Tests/") or name.startswith("scripts/tests/")) and value.strip().lower() in FIXTURES


def scan_content(name, content):
    findings = []
    if forbidden_path(name):
        findings.append((name, 0, "credential file or generated artifact"))
    if len(content) > MAX_BYTES:
        return findings + [(name, 0, "file exceeds repository size limit")]
    for rule, pattern in RULES.items():
        for match in pattern.finditer(content):
            findings.append((name, content.count(b"\n", 0, match.start()) + 1, rule))
    for match in LITERAL.finditer(content):
        value = match.group(1).strip()
        if is_fixture(name, value) or value.startswith((b"\\(", b"${", b"$")):
            continue
        findings.append((name, content.count(b"\n", 0, match.start()) + 1, "hard-coded credential literal"))
    for match in URL_PASSWORD.finditer(content):
        value = match.group(0)
        if name.startswith("Tests/") and value == b"https://user:" + b"secret@example.com":
            continue
        findings.append((name, content.count(b"\n", 0, match.start()) + 1, "password in URL"))
    return findings


def git(*arguments):
    return subprocess.check_output(["git", "-C", str(ROOT), *arguments], stderr=subprocess.PIPE)


def indexed_files(staged):
    names = git("diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z").split(b"\0") if staged else git("ls-files", "-z").split(b"\0")
    for raw in names:
        if not raw:
            continue
        name = raw.decode("utf-8", "surrogateescape")
        index = git("ls-files", "--stage", "-z", "--", name).split(b"\0")
        entries = [entry for entry in index if entry]
        if len(entries) != 1 or not entries[0].split(b"\t", 1)[0].endswith(b" 0"):
            raise ValueError("unmerged index entry")
        mode = entries[0].split(b" ", 1)[0]
        if mode not in {b"100644", b"100755"}:
            yield name, b"", "symlinks/submodules require explicit review"
            continue
        oid = entries[0].split(b" ")[1].decode("ascii")
        if int(git("cat-file", "-s", oid)) > MAX_BYTES:
            yield name, b"", "file exceeds repository size limit"
            continue
        yield name, git("cat-file", "blob", oid), None


def tree_files():
    for path in sorted(ROOT.rglob("*")):
        relative = path.relative_to(ROOT)
        if any(p in FORBIDDEN_DIRS or p == ".git" for p in relative.parts):
            continue
        if path.is_symlink():
            yield relative.as_posix(), b"", "symlink requires explicit review"
        elif path.is_file():
            if path.stat().st_size > MAX_BYTES:
                yield relative.as_posix(), b"", "file exceeds repository size limit"
            else:
                yield relative.as_posix(), path.read_bytes(), None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--staged", action="store_true", help="scan exactly the staged blobs")
    scope.add_argument("--tree", action="store_true", help="scan source tree before it is a Git repository")
    args = parser.parse_args()
    problems = []
    count = 0
    try:
        for name, content, error in (tree_files() if args.tree else indexed_files(args.staged)):
            count += 1
            problems.extend([(name, 0, error)] if error else scan_content(name, content))
    except (OSError, ValueError, subprocess.CalledProcessError):
        print("Repository check could not finish; no credential content was printed.", file=sys.stderr)
        return 2
    for name, line, rule in sorted(set(problems)):
        print("{}:{}: {} (value redacted)".format(ascii(name), line, rule), file=sys.stderr)
    print("Repository check: {} files, {} finding(s).".format(count, len(set(problems))))
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
