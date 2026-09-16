#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
git rev-parse --show-toplevel >/dev/null
EXISTING_HOOKS="$(git config --local --get core.hooksPath || true)"
if [[ -n "$EXISTING_HOOKS" && "$EXISTING_HOOKS" != .githooks ]]; then
    echo "Existing hooksPath found; review it before replacing hooks." >&2
    exit 1
fi
bash scripts/install-audit-tools.sh .tools
chmod +x .githooks/pre-commit
git config --local core.hooksPath .githooks
echo "Local hooks enabled. Audit tools stay in ignored .tools/."
