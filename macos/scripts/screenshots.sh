#!/bin/bash
# Regenerates the README screenshots from made-up demo data (no account, no real logs).
# Usage: macos/scripts/screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
swift build --product ClaudeUsageBar
OUT="$(cd .. && pwd)/docs/screenshots"
"$(swift build --show-bin-path)/ClaudeUsageBar" --render-screenshots "$OUT"
