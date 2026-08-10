#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

DATE=${DATE:-date}
CLAUDE=${CLAUDE:-claude}
GIT=${GIT:-git}
: "${SEO_AUTOPILOT_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

# shellcheck disable=SC1090
source "$SEO_AUTOPILOT_HOME/lib/profile.sh"
source "$SEO_AUTOPILOT_HOME/lib/log.sh"
source "$SEO_AUTOPILOT_HOME/lib/notify.sh"
source "$SEO_AUTOPILOT_HOME/lib/git_ops.sh"
source "$SEO_AUTOPILOT_HOME/lib/pr.sh"
source "$SEO_AUTOPILOT_HOME/lib/workspace.sh"
source "$SEO_AUTOPILOT_HOME/lib/security.sh"
source "$SEO_AUTOPILOT_HOME/lib/agents.sh"

SLUG="${1:?usage: run.sh <site-slug> [--dry-run]}"
[[ "$SLUG" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
  echo "invalid site slug: use lowercase letters, digits, and hyphens" >&2
  exit 2
}
DRY_RUN=0
case "${2:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  *) echo "usage: run.sh <site-slug> [--dry-run]" >&2; exit 2 ;;
esac

SEO_RUN_DATE="$($DATE +%F)"; export SEO_RUN_DATE
LOGFILE="$SEO_AUTOPILOT_HOME/logs/$SLUG/$SEO_RUN_DATE.log"
MDLOG="${LOGFILE%.log}.md"
log_init "$LOGFILE"
md_init "$MDLOG"

on_error() {
  local rc=$?
  if [[ -n "${TICKER_PID:-}" ]]; then
    kill "$TICKER_PID" 2>/dev/null || true
    wait "$TICKER_PID" 2>/dev/null || true
    TICKER_PID=""
  fi
  KEEP_AGENT_WORKSPACE=1
  log_err "run failed (rc=$rc) — see $LOGFILE"
  [[ "$DRY_RUN" -eq 0 ]] &&
    slack_failure "$SLUG" "$LOGFILE" "run failed (rc=$rc); see log" || true
  exit "$rc"
}
trap on_error ERR
trap cleanup_agent_workspace EXIT

load_profile "$SLUG"
export GH_TOKEN

MODE="$([[ "$DRY_RUN" -eq 1 ]] && echo 'DRY-RUN (no push / PR / Slack)' || echo 'LIVE (opens PR + Slack)')"
log_banner "SEO Autopilot · $SLUG · $SEO_RUN_DATE"
log_info "mode:   $MODE"
log_info "repo:   $REPO_PATH"
log_info "domain: $DOMAIN  →  Ubersuggest '$UBERSUGGEST_TARGET'"
log_info "agents: research → plan → meta/schema/a11y/content → report → review"
log_info "caps:   <= $MAX_FILES files · <= $MAX_NEW_PAGES new pages · <= $MAX_DIFF_LINES lines"

restore_base() {
  ( cd "$REPO_PATH"; $GIT checkout --quiet "$BASE_BRANCH" 2>/dev/null || true )
}

md_commit_report() {
  (
    cd "$REPO_PATH"
    local sha subject commits_file
    commits_file="$(mktemp)"
    $GIT log --reverse --format='%h%x09%s' "${BASE_BRANCH}..HEAD" > "$commits_file"
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
    done < "$commits_file"
    rm -f "$commits_file"
  )
}

log_step "[1/8] Preflight — refresh '$BASE_BRANCH'"
preflight_repo
create_agent_workspace
log_ok "tracked-only workspace created from $BASE_BRANCH"

_progress_ticker() {
  local start="$SECONDS" elapsed commits changed
  while true; do
    sleep 20
    elapsed=$(( SECONDS - start ))
    commits="$($GIT -C "$AGENT_WORKSPACE" rev-list --count "${AGENT_BASE_SHA}..HEAD" 2>/dev/null || echo '?')"
    changed="$($GIT -C "$AGENT_WORKSPACE" status --porcelain 2>/dev/null | grep -c . || true)"
    log_beat "agents working... ${elapsed}s · ${commits} accepted category commit(s) · ${changed} pending file(s)"
  done
}

log_step "[2/8] Agent team — research, plan, implement, report, review"
_progress_ticker & TICKER_PID=$!
AGENT_START="$SECONDS"
run_agentic_workflow
kill "$TICKER_PID" 2>/dev/null || true
wait "$TICKER_PID" 2>/dev/null || true
TICKER_PID=""
log_ok "agent team complete in $(( SECONDS - AGENT_START ))s"

AGENT_COMMIT_COUNT="$($GIT -C "$AGENT_WORKSPACE" rev-list --count "${AGENT_BASE_SHA}..HEAD")"
if [[ "$AGENT_COMMIT_COUNT" -eq 0 ]]; then
  log_step "[3/8] Result"
  log_warn "no changes recommended this week — nothing to commit, no PR"
  [[ "$DRY_RUN" -eq 0 ]] &&
    slack_send "🟡 *SEO Autopilot — $SLUG*: no changes recommended this week."
  log_info "pretty run log: $MDLOG"
  KEEP_AGENT_WORKSPACE=0
  log_banner "Done (no changes) · $SLUG · $SEO_RUN_DATE"
  exit 0
fi

log_step "[3/8] Candidate safety — scope, caps, modes, secrets"
validate_agent_workspace
log_ok "candidate passed deterministic safety gates"

log_step "[4/8] Isolated build gate"
DRAFT=0
BUILD_LOG="$AGENT_OUTPUTS/build.log"
if [[ -z "${BUILD_CMD:-}" ]]; then
  log_skip "no BUILD_CMD set — skipping build validation"
elif run_isolated_build_cycle "$AGENT_WORKSPACE" > "$BUILD_LOG" 2>&1; then
  log_ok "isolated build passed"
else
  log_warn "isolated build failed — one edit-only fixer pass"
  BEFORE_FIX="$($GIT -C "$AGENT_WORKSPACE" rev-parse HEAD)"
  if run_fix_agent "$BUILD_LOG" && agent_workspace_has_changes; then
    validate_agent_workspace
    commit_agent_changes fix
    run_review_agent
  else
    $GIT -C "$AGENT_WORKSPACE" reset --hard -q "$BEFORE_FIX"
  fi
  if run_isolated_build_cycle "$AGENT_WORKSPACE" > "$BUILD_LOG" 2>&1; then
    log_ok "isolated build passed after fixer"
  else
    DRAFT=1
    log_warn "build still failing — PR will open as DRAFT (needs-fix)"
  fi
fi

log_step "[5/8] Final isolated safety check"
validate_agent_workspace
ensure_review_approved
log_ok "final candidate approved and passed deterministic gates"

log_step "[6/8] Materialize validated commits"
BRANCH="$(create_branch)"
materialize_agent_commits
assert_clean_worktree
scope_guard
scan_workspace_secrets "$REPO_PATH"
log_ok "validated commits copied to $BRANCH"

log_step "[7/8] Final real-repository safety check"
assert_clean_worktree
scope_guard
scan_workspace_secrets "$REPO_PATH"
log_ok "real branch matches validated scope and contains no detected secrets"

if [[ "$DRY_RUN" -eq 1 ]]; then
  log_step "[8/8] Dry-run — skipping push / PR / Slack"
  log_ok "branch '$BRANCH' is ready to review in $REPO_PATH"
  DIFFSTAT="$(cd "$REPO_PATH"; $GIT --no-pager diff --stat "${BASE_BRANCH}...HEAD")"
  echo "$DIFFSTAT"
  printf '%s\n' "$DIFFSTAT" | md_block "Summary — files changed"
  md_commit_report
  [[ -f "$REPO_PATH/tasks/seo/reports/$SEO_RUN_DATE.md" ]] &&
    log_info "SEO report: $REPO_PATH/tasks/seo/reports/$SEO_RUN_DATE.md"
  log_info "pretty run log: $MDLOG"
  restore_base
  KEEP_AGENT_WORKSPACE=0
  log_banner "Dry-run done · $SLUG · $SEO_RUN_DATE"
  exit 0
fi

log_step "[8/8] Publish — push branch, open PR, notify Slack"
push_branch "$BRANCH"
log_ok "pushed $BRANCH to origin"
REPORT="tasks/seo/reports/${SEO_RUN_DATE}.md"
BODY="$REPO_PATH/$REPORT"
[[ -f "$BODY" ]] || {
  BODY="$(mktemp)"
  printf 'SEO Autopilot %s — see commits.\n' "$SEO_RUN_DATE" > "$BODY"
}
TITLE="seo: weekly improvements ($SEO_RUN_DATE) — $DOMAIN"
if [[ "$DRAFT" -eq 1 ]]; then
  TITLE="[needs-fix] $TITLE"
  PR_LABELS="${PR_LABELS:+$PR_LABELS,}needs-fix"
fi
PR_URL="$(open_or_update_pr "$BRANCH" "$TITLE" "$BODY" "$DRAFT")"
[[ -n "$PR_URL" ]] || {
  echo "GitHub API returned no pull request URL" >&2
  exit 1
}
log_ok "PR ready: $PR_URL"
( cd "$REPO_PATH"; $GIT --no-pager diff --stat "${BASE_BRANCH}...HEAD" ) |
  md_block "Summary — files changed"
md_commit_report

REPORT_URL=""
if [[ -f "$BODY" && "$BODY" == "$REPO_PATH/$REPORT" ]]; then
  REPORT_URL="https://github.com/$(repo_slug)/blob/${BRANCH}/${REPORT}"
  log_ok "report on GitHub: $REPORT_URL"
fi
SUMMARY="$(cd "$REPO_PATH"; $GIT log --oneline "${BASE_BRANCH}..HEAD" | head -6)"
[[ -n "$REPORT_URL" ]] && SUMMARY="${SUMMARY}
📄 Report: ${REPORT_URL}"
slack_success "$SLUG" "$PR_URL" "$SUMMARY"
log_ok "Slack notified"
log_info "pretty run log: $MDLOG"
restore_base
KEEP_AGENT_WORKSPACE=0
log_banner "Done · $SLUG · $SEO_RUN_DATE · $PR_URL"
