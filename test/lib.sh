#!/usr/bin/env bash
set -euo pipefail

TESTS_RUN=0
TESTS_FAILED=0

fail() { echo "F" >> "${SEO_TEST_RESULTS:-/dev/null}"; echo "  ✗ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }
pass() { echo "P" >> "${SEO_TEST_RESULTS:-/dev/null}"; echo "  ✓ $1"; }

assert_eq() { # actual expected msg
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected '[$2]', got '[$1]')"; fi
}

assert_contains() { # haystack needle msg
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$1" == *"$2"* ]]; then pass "$3"; else fail "$3 (missing '$2' in '$1')"; fi
}

assert_not_contains() { # haystack needle msg
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$1" != *"$2"* ]]; then pass "$3"; else fail "$3 (found '$2' in '$1')"; fi
}

# make_mock <name> <body>: create executable <name> in $MOCK_BIN (prepended to PATH),
# appends each invocation's args to $MOCK_LOG/<name>.log and any piped stdin to
# $MOCK_LOG/<name>.stdin.log (so tests can assert on secrets passed via `curl --config -`).
# The `[ -t 0 ]` guard skips stdin capture when there is no pipe, preventing hangs.
setup_mocks() {
  MOCK_BIN="$(mktemp -d)"; MOCK_LOG="$(mktemp -d)"; PATH="$MOCK_BIN:$PATH"
}
make_mock() { # name body
  local name="$1" body="$2"
  cat > "$MOCK_BIN/$name" <<EOF
#!/usr/bin/env bash
echo "\$@" >> "$MOCK_LOG/$name.log"
[ -t 0 ] || cat >> "$MOCK_LOG/$name.stdin.log" 2>/dev/null
$body
EOF
  chmod +x "$MOCK_BIN/$name"
}
mock_calls() { cat "$MOCK_LOG/$1.log" 2>/dev/null || true; }
mock_stdin() { cat "$MOCK_LOG/$1.stdin.log" 2>/dev/null || true; }
