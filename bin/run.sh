#!/usr/bin/env bash
set -euo pipefail

DATE=${DATE:-date}
CLAUDE=${CLAUDE:-claude}
: "${SEO_AUTOPILOT_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

# shellcheck disable=SC1090
source "$SEO_AUTOPILOT_HOME/lib/profile.sh"
source "$SEO_AUTOPILOT_HOME/lib/log.sh"
source "$SEO_AUTOPILOT_HOME/lib/notify.sh"
source "$SEO_AUTOPILOT_HOME/lib/git_ops.sh"
source "$SEO_AUTOPILOT_HOME/lib/pr.sh"

SLUG="${1:?usage: run.sh <site-slug> [--dry-run]}"
DRY_RUN=0; [[ "${2:-}" == "--dry-run" ]] && DRY_RUN=1

# Compute run-date + logfile from $SLUG alone (no profile needed yet), and get
# logging + the failure trap installed BEFORE load_profile — so a profile
# failure (missing .conf, missing required keys, bad REPO_PATH) is still
# logged and, once secrets are sourced, Slack-alerted. A totally-missing
# .conf can't notify (no webhook yet) — that's an acceptable limit.
SEO_RUN_DATE="$($DATE +%F)"; export SEO_RUN_DATE
LOGFILE="$SEO_AUTOPILOT_HOME/logs/$SLUG/$SEO_RUN_DATE.log"
MDLOG="${LOGFILE%.log}.md"
log_init "$LOGFILE"
md_init "$MDLOG"

# Failure trap -> Slack (skips in dry-run)
on_error() {
  local rc=$?
  [[ -n "${TICKER_PID:-}" ]] && { kill "$TICKER_PID" 2>/dev/null || true; }
  log_err "run failed (rc=$rc) — see $LOGFILE"
  [[ "$DRY_RUN" -eq 0 ]] && slack_failure "$SLUG" "$LOGFILE" "run failed (rc=$rc); see log" || true
  exit "$rc"
}
trap on_error ERR

load_profile "$SLUG"
export GH_TOKEN   # read by curl (PR REST) + git push credential helper

MODE="$([[ "$DRY_RUN" -eq 1 ]] && echo 'DRY-RUN (no push / PR / Slack)' || echo 'LIVE (opens PR + Slack)')"
log_banner "SEO Autopilot · $SLUG · $SEO_RUN_DATE"
log_info "mode:   $MODE"
log_info "repo:   $REPO_PATH"
log_info "domain: $DOMAIN  →  Ubersuggest '$UBERSUGGEST_TARGET'"
log_info "caps:   <= $MAX_FILES files · <= $MAX_NEW_PAGES new pages · <= $MAX_DIFF_LINES lines"

restore_base() { ( cd "$REPO_PATH"; $GIT checkout --quiet "$BASE_BRANCH" 2>/dev/null || true ); }

# Per-commit breakdown into the .md: each commit as its own section with its
# file stat and a collapsible full diff (GitHub renders <details>).
md_commit_report() {
  ( cd "$REPO_PATH"
    local sha subject
    _md ""
    _md "## 📦 What changed — by commit"
    while IFS=$'\t' read -r sha subject; do
      [[ -z "${sha:-}" ]] && continue
      _md ""
      _md "### \`$sha\` — $subject"
      { echo; echo '```'; $GIT log -1 --format='' --stat "$sha" | sed '/^[[:space:]]*$/d'; echo '```'; } >> "${MD_FILE:-/dev/null}"
      _md "<details><summary>Show full diff</summary>"
      { echo; echo '```diff'; $GIT show --format='' "$sha"; echo '```'; echo; } >> "${MD_FILE:-/dev/null}"
      _md "</details>"
    done < <($GIT log --reverse --format='%h%x09%s' "${BASE_BRANCH}..HEAD")
  )
}

# ── [1/6] Preflight ────────────────────────────────────────────────
log_step "[1/6] Preflight — refresh '$BASE_BRANCH', cut the work branch"
preflight_repo
BRANCH="$(create_branch)"
log_ok "on $BRANCH (cut from $BASE_BRANCH)"

# ── [2/6] Analysis ─────────────────────────────────────────────────
# The Ubersuggest MCP must be added as a LOCAL user-scoped server named
# `ubersuggest` — claude.ai connectors are NOT loaded in headless `claude -p`:
#   claude mcp add --transport http --scope user ubersuggest https://ubersuggest-mcp.neilpatelapi.com/mcp
# A bare `mcp__*` wildcard is rejected in allow rules, so we name the server and
# glob the tool position. Override UBER_TOOLS if your local server has a different name.
UBER_TOOLS="${UBER_TOOLS:-mcp__ubersuggest__*}"

# Pass the resolved config to the command as $ARGUMENTS. `$VAR` placeholders in a
# slash-command file are NOT interpolated, and the headless agent can't read env
# vars without a permission prompt — so without this the agent flies blind on caps
# and under-delivers. $ARGUMENTS IS interpolated, so this is the reliable channel.
SEO_CONFIG="DOMAIN=${DOMAIN}
UBERSUGGEST_TARGET=${UBERSUGGEST_TARGET}
EDITABLE_GLOBS=${EDITABLE_GLOBS}
EXCLUDE_GLOBS=${EXCLUDE_GLOBS}
MAX_FILES=${MAX_FILES}
MAX_NEW_PAGES=${MAX_NEW_PAGES}
MAX_DIFF_LINES=${MAX_DIFF_LINES}
RUN_DATE=${SEO_RUN_DATE}
NOTES=${NOTES}"

log_step "[2/6] Analysis — Ubersuggest + scoped edits (agent runs silently)"
log_info "heartbeat prints every 20s below so you can see it working"

# Heartbeat: `claude -p` emits nothing to the log until it finishes, so a run can
# look frozen for minutes. This background ticker logs a pulse every 20s with real
# progress — elapsed time plus how many commits/files the agent has produced so far
# (tied to actual work, not a fake spinner). It's killed as soon as claude returns.
_progress_ticker() {
  local start="$SECONDS" elapsed commits changed
  while true; do
    sleep 20
    elapsed=$(( SECONDS - start ))
    commits="$($GIT -C "$REPO_PATH" rev-list --count "${BASE_BRANCH}..HEAD" 2>/dev/null || echo '?')"
    changed="$($GIT -C "$REPO_PATH" status --porcelain 2>/dev/null | grep -c . || true)"
    log_beat "working... ${elapsed}s elapsed · ${commits} commit(s) so far · ${changed} file(s) in progress"
  done
}
_progress_ticker & TICKER_PID=$!
CLAUDE_START="$SECONDS"

# env -u strips GH_TOKEN/SLACK_WEBHOOK_URL from the headless edit agent's
# environment: it has Write+git-commit and consumes untrusted Ubersuggest
# data, so it must never be able to see either secret. The parent shell
# keeps both for the later push/PR/Slack steps below.
( cd "$REPO_PATH"
  env -u GH_TOKEN -u SLACK_WEBHOOK_URL "$CLAUDE" -p "/seo-weekly $SEO_CONFIG" \
    --permission-mode acceptEdits \
    --allowedTools "$UBER_TOOLS,Read,Grep,Glob,Edit,Write,Skill,Bash(git add:*),Bash(git commit:*),Bash(git status:*),Bash(git diff:*)"
) \
  || log_warn "claude run returned non-zero (continuing to inspect commits)"

kill "$TICKER_PID" 2>/dev/null || true; wait "$TICKER_PID" 2>/dev/null || true; TICKER_PID=""
log_ok "analysis complete in $(( SECONDS - CLAUDE_START ))s · $($GIT -C "$REPO_PATH" rev-list --count "${BASE_BRANCH}..HEAD" 2>/dev/null || echo 0) commit(s)"

# ── [3/6] Pre-build safety ─────────────────────────────────────────
log_step "[3/6] Pre-build safety — clean worktree · scope · caps · binaries"
assert_clean_worktree
scope_guard
log_ok "scope OK — safe to execute the build"

# Run project code without exposing the credentials used later for publish and
# notifications. BUILD_CMD is trusted profile configuration, evaluated by bash.
run_build() {
  ( cd "$REPO_PATH"
    env -u GH_TOKEN -u SLACK_WEBHOOK_URL bash -c "$BUILD_CMD"
  )
}

# ── [4/6] Build gate ───────────────────────────────────────────────
DRAFT=0
log_step "[4/6] Build gate"
if [[ -z "${BUILD_CMD:-}" ]]; then
  log_skip "no BUILD_CMD set — skipping build validation"
elif ! has_commits; then
  log_skip "no commits to build"
else
  log_info "running: $BUILD_CMD"
  if run_build; then
    log_ok "build passed"
  else
    log_warn "build failed — attempting one self-fix pass"
    ( cd "$REPO_PATH"
      env -u GH_TOKEN -u SLACK_WEBHOOK_URL "$CLAUDE" -p "Fix ONLY the build errors from '$BUILD_CMD' in this repo. Do not add features. Commit fixes as 'seo(fix): build'." \
        --permission-mode acceptEdits \
        --allowedTools "Read,Grep,Glob,Edit,Write,Bash($BUILD_CMD),Bash(git add:*),Bash(git commit:*)"
    ) || true
    assert_clean_worktree
    scope_guard
    if run_build; then
      log_ok "build passed after self-fix"
    else
      DRAFT=1; log_warn "build still failing — PR will open as DRAFT (needs-fix)"
    fi
  fi
fi

# ── [5/6] Result / final safety ────────────────────────────────────
if ! has_commits; then
  log_step "[5/6] Result"
  log_warn "no changes recommended this week — nothing to commit, no PR"
  [[ "$DRY_RUN" -eq 0 ]] && slack_send "🟡 *SEO Autopilot — $SLUG*: no changes recommended this week."
  log_info "pretty run log: $MDLOG"
  restore_base
  log_banner "Done (no changes) · $SLUG · $SEO_RUN_DATE"
  exit 0
fi

log_step "[5/6] Final safety check — clean worktree · scope · caps · binaries"
assert_clean_worktree
scope_guard
log_ok "scope OK — within EDITABLE_GLOBS, no excluded paths, within caps"

# ── [6/6] Ship (or stop, if dry-run) ───────────────────────────────
if [[ "$DRY_RUN" -eq 1 ]]; then
  log_step "[6/6] Dry-run — skipping push / PR / Slack"
  log_ok "branch '$BRANCH' is ready to review in $REPO_PATH"
  DIFFSTAT="$(cd "$REPO_PATH"; git --no-pager diff --stat "${BASE_BRANCH}...HEAD")"
  echo "$DIFFSTAT"
  printf '%s\n' "$DIFFSTAT" | md_block "Summary — files changed"
  md_commit_report
  [[ -f "$REPO_PATH/tasks/seo/reports/$SEO_RUN_DATE.md" ]] && log_info "SEO report: $REPO_PATH/tasks/seo/reports/$SEO_RUN_DATE.md"
  log_info "pretty run log: $MDLOG"
  restore_base
  log_banner "Dry-run done · $SLUG · $SEO_RUN_DATE"
  exit 0
fi

log_step "[6/6] Publish — push branch, open PR, notify Slack"
push_branch "$BRANCH"
log_ok "pushed $BRANCH to origin"
REPORT="tasks/seo/reports/${SEO_RUN_DATE}.md"
BODY="$REPO_PATH/$REPORT"
[[ -f "$BODY" ]] || { BODY="$(mktemp)"; echo "SEO Autopilot $SEO_RUN_DATE — see commits." > "$BODY"; }
TITLE="seo: weekly improvements ($SEO_RUN_DATE) — $DOMAIN"
[[ "$DRAFT" -eq 1 ]] && { TITLE="[needs-fix] $TITLE"; PR_LABELS="$PR_LABELS,needs-fix"; }
PR_URL="$(open_or_update_pr "$BRANCH" "$TITLE" "$BODY" "$DRAFT")"
[[ -n "$PR_URL" ]] || { echo "GitHub API returned no pull request URL" >&2; exit 1; }
log_ok "PR ready: $PR_URL"
( cd "$REPO_PATH"; git --no-pager diff --stat "${BASE_BRANCH}...HEAD" ) | md_block "Summary — files changed"
md_commit_report

# GitHub link to the report md (pushed with the branch), for the Slack message.
REPORT_URL=""
if [[ -f "$BODY" && "$BODY" == "$REPO_PATH/$REPORT" ]]; then
  REPORT_URL="https://github.com/$(repo_slug)/blob/${BRANCH}/${REPORT}"
  log_ok "report on GitHub: $REPORT_URL"
fi

SUMMARY="$(cd "$REPO_PATH"; git log --oneline "${BASE_BRANCH}..HEAD" | head -6)"
[[ -n "$REPORT_URL" ]] && SUMMARY="${SUMMARY}
📄 Report: ${REPORT_URL}"
slack_success "$SLUG" "$PR_URL" "$SUMMARY"
log_ok "Slack notified"
log_info "pretty run log: $MDLOG"
restore_base
log_banner "Done · $SLUG · $SEO_RUN_DATE · $PR_URL"
