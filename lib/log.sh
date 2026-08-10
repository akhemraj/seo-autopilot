#!/usr/bin/env bash
set -euo pipefail

log_init() { # logfile
  LOG_FILE="$1"
  mkdir -p "$(dirname "$LOG_FILE")"
  : > "$LOG_FILE"
}
_ts() { date '+%H:%M:%S'; }
_emit() {
  printf '%s\n' "$*" | tee -a "${LOG_FILE:-/dev/null}"
}
_emit_err() {
  printf '%s\n' "$*" | tee -a "${LOG_FILE:-/dev/null}" >&2
}

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
  _emit ""
  _emit "  ┌────────────────────────────────────────────────────────┐"
  printf '  │  %-54s│\n' "$*" | tee -a "${LOG_FILE:-/dev/null}"
  _emit "  └────────────────────────────────────────────────────────┘"
  _md ""; _md "## $*"
}
log_step() { _emit ""; _emit "[$(_ts)] ▶  $*"; _md ""; _md "### ▶ $*"; }
log_info() { _emit "[$(_ts)]    •  $*"; _md "- $*"; }
log_ok()   { _emit "[$(_ts)]    ✓  $*"; _md "- ✅ $*"; }
log_warn() { _emit "[$(_ts)]    ⚠  $*"; _md "- ⚠️ $*"; }
log_skip() { _emit "[$(_ts)]    ⏭  $*"; _md "- ⏭️ $*"; }
log_err()  { _emit_err "[$(_ts)]    ✗  $*"; _md "- ❌ $*"; }
# Heartbeat pulse — console only, so the 20s cadence doesn't spam the .md
log_beat() { _emit "[$(_ts)]    •  $*"; }
