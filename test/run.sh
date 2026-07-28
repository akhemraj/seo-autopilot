#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
RESULTS="$(mktemp)"; export SEO_TEST_RESULTS="$RESULTS"; : > "$RESULTS"
for t in test_*.sh; do
  [[ -e "$t" ]] || continue
  echo "== $t =="
  # shellcheck disable=SC1090
  # Redirect stdin from /dev/null so a mock invoked without a pipe gets immediate
  # EOF (the make_mock stdin-capture `cat` would otherwise block when stdin is a
  # non-tty, non-closed handle, e.g. under CI or a nested non-interactive shell).
  # Piped stdin from within a test (printf | curl) still overrides this per-command.
  ( source lib.sh; source "$t" ) < /dev/null || echo "  (test file errored)"
done
total=$(grep -c . "$RESULTS" 2>/dev/null || true); total=${total:-0}
failed=$(grep -c '^F' "$RESULTS" 2>/dev/null || true); failed=${failed:-0}
echo "---"
echo "Total: $total assertions, $failed failed"
rm -f "$RESULTS"
[[ "$failed" -eq 0 ]]
