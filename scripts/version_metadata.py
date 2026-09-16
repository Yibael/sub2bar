#!/usr/bin/env python3
"""Single-source public versions and automatically generated bundle metadata."""
import argparse
import datetime
import os
import pathlib
import plistlib
import re

ROOT = pathlib.Path(__file__).resolve().parents[1]
VERSION_PATTERN = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-(alpha|beta|rc)\.([1-9][0-9]*))?")
BUILD_PATTERN = re.compile(r"([1-9][0-9]{0,3})\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)")
GENERATED_FIELDS = {"CFBundleShortVersionString", "CFBundleVersion", "Sub2BarVersion", "Sub2BarBuildSource"}
EPOCH = datetime.datetime(2020, 1, 1, tzinfo=datetime.timezone.utc)


def parse_version(value):
    match = VERSION_PATTERN.fullmatch(value)
    if not match:
        raise ValueError("Expected X.Y.Z or X.Y.Z-alpha.N / beta.N / rc.N (no leading zeros).")
    return ".".join(match.group(1, 2, 3)), match.group(4) is not None


def read_version(root=ROOT):
    value = (root / "VERSION").read_text(encoding="utf-8").strip()
    parse_version(value)
    return value


def read_template(root=ROOT):
    with (root / "Resources/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if not isinstance(info, dict) or GENERATED_FIELDS.intersection(info):
        raise ValueError("Keep generated version fields out of Resources/Info.plist; edit VERSION instead.")
    return info


def automatic_build(environment, previous=None, now=None):
    if environment.get("GITHUB_ACTIONS") == "true":
        run = environment.get("GITHUB_RUN_NUMBER", "")
        attempt = environment.get("GITHUB_RUN_ATTEMPT", "")
        if not re.fullmatch(r"[1-9][0-9]{0,3}", run) or not re.fullmatch(r"[1-9][0-9]?", attempt):
            raise ValueError("GitHub build requires run number 1..9999 and attempt 1..99.")
        # Run numbers are scoped to a workflow, and attempts distinguish reruns.
        return f"{run}.{attempt}.0", "github"

    # Local IDs encode UTC minutes as three Apple-compatible numeric groups.
    # Rebuilds in the same destination advance even within the same minute.
    date = now if now is not None else datetime.datetime.now(datetime.timezone.utc)
    sequence = int((date - EPOCH).total_seconds() // 60)
    if previous and previous.get("Sub2BarBuildSource") == "local":
        match = BUILD_PATTERN.fullmatch(str(previous.get("CFBundleVersion", "")))
        if not match:
            raise ValueError("Existing local app has an invalid build number.")
        major, minor, patch = map(int, match.groups())
        sequence = max(sequence, (major - 1) * 10000 + minor * 100 + patch + 1)
    if not 0 <= sequence < 9999 * 10000:
        raise ValueError("Local clock is outside the supported build-number range.")
    return f"{sequence // 10000 + 1}.{sequence // 100 % 100}.{sequence % 100}", "local"


def write_bundle_info(output, root=ROOT, environment=None, now=None):
    template = root / "Resources/Info.plist"
    if output.resolve() == template.resolve():
        raise ValueError("Cannot overwrite the source Info.plist template.")
    version = read_version(root)
    base, _ = parse_version(version)
    info = read_template(root)
    previous = None
    if output.exists():
        with output.open("rb") as stream:
            previous = plistlib.load(stream)
        if not isinstance(previous, dict):
            raise ValueError("Existing app Info.plist must be a dictionary.")
    build, source = automatic_build(os.environ if environment is None else environment, previous, now)
    info.update(CFBundleShortVersionString=base, CFBundleVersion=build,
                Sub2BarVersion=version, Sub2BarBuildSource=source)
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.open("wb") as stream:
        plistlib.dump(info, stream, sort_keys=False)
    return info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--write-plist", type=pathlib.Path)
    args = parser.parse_args()
    try:
        if args.write_plist:
            info = write_bundle_info(args.write_plist)
            print(f"App version: {info['Sub2BarVersion']}; build: {info['CFBundleVersion']}")
        else:
            print(read_version())
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Version metadata error: {error}\n")


if __name__ == "__main__":
    main()
