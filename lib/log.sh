#!/usr/bin/env bash
set -euo pipefail

log_init() { # logfile
  local f="$1"; mkdir -p "$(dirname "$f")"
  exec > >(tee -a "$f") 2>&1
}
_ts() { date '+%H:%M:%S'; }

# ── Markdown mirror ────────────────────────────────────────────────
# Every run also writes a pretty, GitHub-flavored .md of the whole log so it
# renders nicely (headings, checkmarks, code blocks) instead of raw text.
md_init() { # mdfile — call right after log_init
  MD_FILE="$1"; mkdir -p "$(dirname "$MD_FILE")"
  { echo "# 🚀 SEO Autopilot — run log"; echo; echo "_$(date '+%Y-%m-%d %H:%M:%S')_"; echo; } > "$MD_FILE"
}
_md() { printf '%s\n' "$*" >> "${MD_FILE:-/dev/null}"; }
md_block() { # title  (body piped on stdin) -> a fenced code block in the .md
  { echo; echo "#### $1"; echo '```'; cat; echo '```'; echo; } >> "${MD_FILE:-/dev/null}"
}

# ── Beautified console output (mirrored to Markdown) ───────────────
# Symbols read at a glance:  ▶ phase   • detail   ✓ ok   ⚠ warning   ⏭ skipped   ✗ error
log_banner() {                                   # run header / section divider
  echo ""
  echo "  ┌────────────────────────────────────────────────────────┐"
  printf '  │  %-54s│\n' "$*"
  echo "  └────────────────────────────────────────────────────────┘"
  _md ""; _md "## $*"
}
log_step() { echo ""; echo "[$(_ts)] ▶  $*"; _md ""; _md "### ▶ $*"; }
log_info() { echo "[$(_ts)]    •  $*"; _md "- $*"; }
log_ok()   { echo "[$(_ts)]    ✓  $*"; _md "- ✅ $*"; }
log_warn() { echo "[$(_ts)]    ⚠  $*"; _md "- ⚠️ $*"; }
log_skip() { echo "[$(_ts)]    ⏭  $*"; _md "- ⏭️ $*"; }
log_err()  { echo "[$(_ts)]    ✗  $*" >&2; _md "- ❌ $*"; }
# Heartbeat pulse — console only, so the 20s cadence doesn't spam the .md
log_beat() { echo "[$(_ts)]    •  $*"; }
