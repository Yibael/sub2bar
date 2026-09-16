#!/usr/bin/env python3
"""Validate stable tag/version agreement before any release publication."""
import pathlib
import plistlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parents[1]


def main():
    if len(sys.argv) != 2 or not re.fullmatch(r"v\d+\.\d+\.\d+", sys.argv[1]):
        raise SystemExit("Expected a stable release tag such as v1.5.0.")
    version = sys.argv[1][1:]
    with (ROOT / "Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleShortVersionString") != version:
        raise SystemExit("Tag does not match Resources/Info.plist.")
    if not str(info.get("CFBundleVersion", "")).isdigit():
        raise SystemExit("CFBundleVersion must be a build number.")
    if "## [{}]".format(version) not in (ROOT / "CHANGELOG.md").read_text():
        raise SystemExit("Add this release to CHANGELOG.md before tagging.")
    print("Release metadata verified: " + sys.argv[1])


if __name__ == "__main__":
    main()
