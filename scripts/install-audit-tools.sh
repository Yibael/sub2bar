#!/bin/bash
set -euo pipefail
TOOLS_DIR="${1:-.tools}"
mkdir -p "$TOOLS_DIR"
TOOLS_DIR="$(cd "$TOOLS_DIR" && pwd)"

# Fixed official release assets, SHA-256 verified on 2026-09-16.
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64)
        GITLEAKS_PLATFORM=darwin_arm64
        GITLEAKS_SHA=b40ab0ae55c505963e365f271a8d3846efbc170aa17f2607f13df610a9aeb6a5
        ACTIONLINT_PLATFORM=darwin_arm64
        ACTIONLINT_SHA=aba9ced2dee8d27fecca3dc7feb1a7f9a52caefa1eb46f3271ea66b6e0e6953f
        ;;
    Darwin-x86_64)
        GITLEAKS_PLATFORM=darwin_x64
        GITLEAKS_SHA=dfe101a4db2255fc85120ac7f3d25e4342c3c20cf749f2c20a18081af1952709
        ACTIONLINT_PLATFORM=darwin_amd64
        ACTIONLINT_SHA=5b44c3bc2255115c9b69e30efc0fecdf498fdb63c5d58e17084fd5f16324c644
        ;;
    Linux-x86_64)
        GITLEAKS_PLATFORM=linux_x64
        GITLEAKS_SHA=551f6fc83ea457d62a0d98237cbad105af8d557003051f41f3e7ca7b3f2470eb
        ACTIONLINT_PLATFORM=linux_amd64
        ACTIONLINT_SHA=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
        ;;
    *) echo "Unsupported audit-tools platform." >&2; exit 1 ;;
esac

ARCHIVE_TEMP="$(mktemp -t sub2bar-audit.XXXXXX)"
trap 'rm -f "$ARCHIVE_TEMP"' EXIT
install_tool() {
    local tool="$1" url="$2" expected="$3"
    curl --fail --location --silent --show-error --retry 3 "$url" -o "$ARCHIVE_TEMP"
    python3 - "$ARCHIVE_TEMP" "$expected" <<'PY'
import hashlib
import pathlib
import sys
actual = hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()
if actual != sys.argv[2]:
    raise SystemExit("Audit tool checksum verification failed.")
PY
    tar -xzf "$ARCHIVE_TEMP" -C "$TOOLS_DIR" "$tool"
    chmod +x "$TOOLS_DIR/$tool"
}
install_tool gitleaks "https://github.com/gitleaks/gitleaks/releases/download/v8.30.1/gitleaks_8.30.1_${GITLEAKS_PLATFORM}.tar.gz" "$GITLEAKS_SHA"
install_tool actionlint "https://github.com/rhysd/actionlint/releases/download/v1.7.12/actionlint_1.7.12_${ACTIONLINT_PLATFORM}.tar.gz" "$ACTIONLINT_SHA"
"$TOOLS_DIR/gitleaks" version
"$TOOLS_DIR/actionlint" --version
