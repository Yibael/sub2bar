#!/usr/bin/env python3
"""Validate stable or prerelease tags before any release publication."""
import pathlib
import re
import sys
from version_metadata import parse_version, read_template, read_version

ROOT = pathlib.Path(__file__).resolve().parents[1]


def verify_release(tag, root=ROOT):
    if not tag.startswith("v"):
        raise ValueError("Expected a release tag such as v0.1.0-beta.1 or v0.1.0.")
    version = tag[1:]
    _, prerelease = parse_version(version)
    if read_version(root) != version:
        raise ValueError("Tag does not match VERSION.")
    read_template(root)
    if not re.search(r"^## \[" + re.escape(version) + r"\]\s*$", (root / "CHANGELOG.md").read_text(), re.MULTILINE):
        raise ValueError("Add this release to CHANGELOG.md before tagging.")
    return prerelease


def main():
    if len(sys.argv) != 2:
        raise SystemExit("Expected one release tag.")
    try:
        verify_release(sys.argv[1])
    except (OSError, ValueError) as error:
        raise SystemExit(str(error))
    print("Release metadata verified: " + sys.argv[1])


if __name__ == "__main__":
    main()
