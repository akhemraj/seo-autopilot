RUN="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/run.sh"
HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

setup_site() { # builds a fake toolkit home + fake target repo, all mocks
  # usage: setup_site [build_cmd_template] [exclude_globs]
  # build_cmd_template may embed the literal token __REPO__, substituted with
  # the generated target repo's absolute path once it's known (needed so a
  # BUILD_CMD can point at a marker file inside that repo, e.g. a self-fix
  # marker). Leave args unset to keep the original BUILD_CMD="true" / default
  # EXCLUDE_GLOBS behavior used by the pre-existing scenarios below.
  local build_cmd_tmpl="${1:-true}" exclude_globs="${2:-}"
  setup_mocks
  SEO_AUTOPILOT_HOME="$(mktemp -d)"; export SEO_AUTOPILOT_HOME
  mkdir -p "$SEO_AUTOPILOT_HOME/sites" "$SEO_AUTOPILOT_HOME/logs"
  cp -R "$HOME_DIR/lib" "$SEO_AUTOPILOT_HOME/lib"
  cp -R "$HOME_DIR/commands" "$SEO_AUTOPILOT_HOME/commands"
  mkdir -p "$SEO_AUTOPILOT_HOME/bin"
  cp "$HOME_DIR/bin/run.sh" "$HOME_DIR/bin/git-credential-github" "$SEO_AUTOPILOT_HOME/bin/"
  local repo bare; repo="$(mktemp -d)"; bare="$(mktemp -d)/origin.git"; git init -q --bare "$bare"
  ( cd "$repo"; git init -q -b main; git config user.email t@t.co; git config user.name t
    git remote add origin https://github.com/a/b.git
    git config "url.$bare.insteadOf" https://github.com/a/b.git
    mkdir -p app; echo x > app/a.txt; git add -A; git commit -q -m base )
  local build_cmd="${build_cmd_tmpl//__REPO__/$repo}"
  cat > "$SEO_AUTOPILOT_HOME/sites/demo.conf" <<EOF
DOMAIN="demo.com"
REPO_PATH="$repo"
UBERSUGGEST_TARGET="demo.com"
BUILD_CMD="$build_cmd"
EOF
  [[ -n "$exclude_globs" ]] && echo "EXCLUDE_GLOBS=\"$exclude_globs\"" >> "$SEO_AUTOPILOT_HOME/sites/demo.conf"
  cat > "$SEO_AUTOPILOT_HOME/sites/demo.secrets" <<EOF
SLACK_WEBHOOK_URL="https://hooks.slack.com/services/T/B/X"
GH_TOKEN="ghtok"
EOF
  chmod 600 "$SEO_AUTOPILOT_HOME/sites/demo.secrets"
  # Role-aware agent mock. The trusted orchestrator, not this mock, commits.
  CLAUDE_MAKE_CHANGE=1; export CLAUDE_MAKE_CHANGE
  make_mock claude 'args="$*"
pwd > "'"$MOCK_LOG"'/claude.cwd"
prev=""
for arg in "$@"; do
  if [[ "$prev" == "--settings" ]]; then
    cp "$arg" "'"$MOCK_LOG"'/agent-settings.json"
    break
  fi
  prev="$arg"
done
[ -n "${GH_TOKEN:-}" ] && touch "'"$MOCK_LOG"'/agent-secret-leak"
[ -n "${SLACK_WEBHOOK_URL:-}" ] && touch "'"$MOCK_LOG"'/agent-secret-leak"
[ "${CLAUDE_CODE_DISABLE_AUTO_MEMORY:-}" == 1 ] || touch "'"$MOCK_LOG"'/agent-memory-enabled"
if [[ "$args" == *"seo-research"* ]]; then
  echo '"'"'{"findings":[],"tools_used":["mcp__ubersuggest__site_audit"],"summary":"ok"}'"'"'
elif [[ "$args" == *"seo-plan"* ]]; then
  echo '"'"'{"tasks":[{"finding_id":"f1","category":"meta","paths":["app/a.txt"],"change":"test"}],"deferred":[],"summary":"ok"}'"'"'
elif [[ "$args" == *"seo-implement-meta"* ]]; then
  [[ "${CLAUDE_MAKE_CHANGE:-1}" == 1 ]] && echo change >> app/a.txt
  echo '"'"'{"category":"meta","changed":["app/a.txt"],"skipped":[],"blocked":[],"summary":"ok"}'"'"'
elif [[ "$args" == *"seo-implement-schema"* ]]; then
  echo '"'"'{"category":"schema","changed":[],"skipped":[],"blocked":[],"summary":"none"}'"'"'
elif [[ "$args" == *"seo-implement-a11y"* ]]; then
  echo '"'"'{"category":"a11y","changed":[],"skipped":[],"blocked":[],"summary":"none"}'"'"'
elif [[ "$args" == *"seo-implement-content"* ]]; then
  echo '"'"'{"category":"content","changed":[],"skipped":[],"blocked":[],"summary":"none"}'"'"'
elif [[ "$args" == *"seo-report"* ]]; then
  mkdir -p tasks/seo/reports
  printf "# SEO report\n" > "tasks/seo/reports/$SEO_RUN_DATE.md"
  echo '"'"'{"written":"report","summary":"ok"}'"'"'
elif [[ "$args" == *"seo-review"* ]]; then
  review_count="$(grep -c "seo-review" "'"$MOCK_LOG"'/claude.log")"
  if [[ "${CLAUDE_REVIEW_REJECT_ONCE:-0}" == 1 && "$review_count" -eq 1 ]]; then
    echo '"'"'{"approved":false,"findings":[{"severity":"high","path":"app/a.txt","reason":"contradiction"}],"summary":"revise"}'"'"'
  else
    echo '"'"'{"approved":true,"findings":[],"summary":"ok"}'"'"'
  fi
elif [[ "$args" == *"seo-revise"* ]]; then
  echo review-fix >> app/a.txt
  echo '"'"'{"changed":["app/a.txt"],"skipped":[],"blocked":[],"summary":"fixed review finding"}'"'"'
elif [[ "$args" == *"seo-fix"* ]]; then
  touch app/.build_ok
  echo '"'"'{"changed":["app/.build_ok"],"summary":"fixed"}'"'"'
fi'
  make_mock gitleaks "exit 0"
  make_mock docker 'mount=""
prev=""
for arg in "$@"; do
  [[ "$prev" == "-v" && -z "$mount" ]] && mount="${arg%%:*}"
  prev="$arg"
done
cmd="${*: -1}"
( cd "$mount" && bash -c "$cmd" )'
  make_mock curl "args=\"\$*\"
if [[ \"\$args\" == *'pulls?head'* ]]; then echo '[]'
elif [[ \"\$args\" == *'/pulls'* ]]; then echo '{\"number\":1,\"html_url\":\"https://github.com/a/b/pull/1\"}'
else echo 'ok'; fi"
  TARGET_REPO="$repo"
}

# dry-run: edits + commit happen, but NO push/pr/slack
( setup_site
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo --dry-run >/dev/null 2>&1
  assert_eq "$(mock_calls curl)" "" "dry-run makes no PR/Slack calls"
  ( cd "$TARGET_REPO"; git branch --list 'seo/weekly-*' ) | grep -q "seo/weekly-" \
    && pass "dry-run created seo branch" || fail "expected seo branch"
  TESTS_RUN=$((TESTS_RUN + 1))
  branch_after="$(cd "$TARGET_REPO"; git rev-parse --abbrev-ref HEAD)"
  assert_eq "$branch_after" "main" "dry-run restores HEAD to BASE_BRANCH after the run"
  claude_cwd="$(cat "$MOCK_LOG/claude.cwd")"
  assert_not_contains "$claude_cwd" "$TARGET_REPO" "claude never runs inside REPO_PATH"
  assert_not_contains "$claude_cwd" "/.git" "claude receives a tracked-only workspace"
  assert_contains "$(mock_calls claude)" "--setting-sources " \
    "agent invocations ignore user, project, and local settings sources"
  assert_contains "$(mock_stdin claude)" \
    "TRUSTED EXACT PATH ALLOWLIST FOR meta" \
    "implementation agent receives an explicit category path allowlist"
  research_call="$(head -1 "$MOCK_LOG/claude.log")"
  assert_not_contains "$research_call" "--safe-mode" \
    "research agent keeps its explicit Ubersuggest MCP server enabled"
  permission_allow="$(jq -r '.permissions.allow[]' "$MOCK_LOG/agent-settings.json")"
  assert_contains "$permission_allow" "Edit(/**)" \
    "implementation permissions use project-relative workspace paths"
  permission_deny="$(jq -r '.permissions.deny[]' "$MOCK_LOG/agent-settings.json")"
  assert_contains "$permission_deny" "Edit(/${TARGET_REPO}/**)" \
    "real repository deny rule uses filesystem-absolute path syntax"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -e "$MOCK_LOG/agent-memory-enabled" ]]; then
    fail "agent auto-memory was enabled"
  else
    pass "agent auto-memory is disabled"
  fi
  audit="$(find "$SEO_AUTOPILOT_HOME/logs/demo" -name '*.agents.json' -print -quit)"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -f "$audit" ]]; then pass "structured agent audit is persisted"; else fail "missing structured agent audit"; fi
  assert_eq "$(jq '.summary.tasks' "$audit")" "1" "agent audit records task count"
  run_log="$(find "$SEO_AUTOPILOT_HOME/logs/demo" -name '*.log' -print -quit)"
  assert_contains "$(cat "$run_log")" \
    "plan: 1 task(s)" "run log records planning counts"
  assert_eq "$(stat -f '%Lp' "$audit")" "600" "agent audit has mode 600"
)

# full run: REST PR create + slack success called
( setup_site
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  assert_contains "$(mock_calls curl)" "/pulls" "full run opens PR via REST"
  assert_contains "$(mock_stdin curl)" "hooks.slack.com" "full run posts slack (URL via stdin)"
)

# One fixable critical/high review rejection gets a single path-locked revision
# pass, a refreshed report, and an independent second review.
( setup_site
  CLAUDE_REVIEW_REJECT_ONCE=1; export CLAUDE_REVIEW_REJECT_ONCE
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" \
    bash "$RUN" demo --dry-run >/dev/null 2>&1
  assert_contains "$(mock_calls claude)" "seo-revise" \
    "rejected review invokes the path-locked revision agent"
  review_branch="$(git -C "$TARGET_REPO" for-each-ref \
    --format='%(refname:short)' 'refs/heads/seo/weekly-*' | head -1)"
  assert_contains "$(git -C "$TARGET_REPO" log --format=%s \
    "$review_branch" -10)" "seo(review-fix): automated improvements" \
    "accepted review revision is committed separately"
  audit="$(find "$SEO_AUTOPILOT_HOME/logs/demo" -name '*.agents.json' -print -quit)"
  assert_eq "$(jq '.agents.review_initial.approved' "$audit")" "false" \
    "initial rejected review is retained in the audit"
  assert_eq "$(jq '.agents.review.approved' "$audit")" "true" \
    "revised candidate passes an independent review"
)

# no-findings run: planner has no actionable tasks -> no PR, Slack 'no changes'
( setup_site
  make_mock claude 'args="$*"
if [[ "$args" == *"seo-research"* ]]; then
  echo '"'"'{"findings":[],"tools_used":["mcp__ubersuggest__site_audit"],"summary":"clean audit"}'"'"'
elif [[ "$args" == *"seo-plan"* ]]; then
  echo '"'"'{"tasks":[],"deferred":[],"summary":"no actionable tasks"}'"'"'
fi'
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  assert_not_contains "$(mock_calls curl)" "/pulls" "no-changes run skips PR"
  assert_contains "$(mock_stdin curl)" "hooks.slack.com" "no-changes still notifies (URL via stdin)"
)

# Planned tasks with no resulting edits are a failed implementation, not a
# successful "no changes" run.
( setup_site
  CLAUDE_MAKE_CHANGE=0; export CLAUDE_MAKE_CHANGE
  TESTS_RUN=$((TESTS_RUN + 1))
  if SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1; then
    fail "planned tasks without edits were reported as a successful no-op"
  else
    pass "planned tasks without edits fail closed"
  fi
  assert_not_contains "$(mock_calls curl)" "/pulls" \
    "blocked implementation does not open a PR"
  assert_contains "$(mock_calls curl)" "failed" \
    "blocked implementation sends a failure notification"
)

# A machine-readable blocked result fails even if another category could have
# produced edits, preventing publication of a silently partial plan.
( setup_site
  make_mock claude 'args="$*"
if [[ "$args" == *"seo-research"* ]]; then echo '"'"'{"findings":[],"tools_used":["mcp__ubersuggest__site_audit"]}'"'"'
elif [[ "$args" == *"seo-plan"* ]]; then echo '"'"'{"tasks":[{"finding_id":"f1","category":"meta","paths":["app/a.txt"],"change":"test"}]}'"'"'
elif [[ "$args" == *"seo-implement-meta"* ]]; then
  echo '"'"'{"category":"meta","changed":[],"skipped":[],"blocked":[{"path":"app/a.txt","reason":"Edit permission denied"}]}'"'"'
fi'
  TESTS_RUN=$((TESTS_RUN + 1))
  if SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo --dry-run >/dev/null 2>&1; then
    fail "blocked implementation status was accepted"
  else
    pass "blocked implementation status fails closed"
  fi
)

# A scope mismatch reports every path in one failure so the planner/agent
# contract can be corrected without repeated one-path-at-a-time reruns.
( setup_site
  make_mock claude 'args="$*"
if [[ "$args" == *"seo-research"* ]]; then echo '"'"'{"findings":[],"tools_used":["mcp__ubersuggest__site_audit"]}'"'"'
elif [[ "$args" == *"seo-plan"* ]]; then echo '"'"'{"tasks":[{"finding_id":"f1","category":"meta","paths":["app/a.txt"],"change":"test"}]}'"'"'
elif [[ "$args" == *"seo-implement-meta"* ]]; then
  printf "extra\n" > app/b.txt
  printf "extra\n" > app/c.txt
  echo '"'"'{"category":"meta","changed":["app/b.txt","app/c.txt"],"skipped":[],"blocked":[]}'"'"'
fi'
  TESTS_RUN=$((TESTS_RUN + 1))
  if SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo --dry-run >/dev/null 2>&1; then
    fail "multiple unplanned paths were accepted"
  else
    pass "multiple unplanned paths fail closed"
  fi
  run_log="$(find "$SEO_AUTOPILOT_HOME/logs/demo" -name '*.log' -print -quit)"
  assert_contains "$(cat "$run_log")" "app/b.txt app/c.txt" \
    "scope failure reports all unplanned paths together"
)

# A syntactically valid research response without Ubersuggest tool provenance
# must fail instead of being misreported as "no changes."
( setup_site
  make_mock claude 'echo '"'"'{"findings":[],"tools_used":[],"summary":"no tool call"}'"'"
  TESTS_RUN=$((TESTS_RUN + 1))
  if SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo --dry-run >/dev/null 2>&1; then
    fail "research without Ubersuggest tool usage was accepted"
  else
    pass "research without Ubersuggest tool usage fails closed"
  fi
)

# Claude can return exit 0 with an API-error result. Transient overloads are
# retried in place so a temporary 529 does not discard the complete run.
( setup_site
  SLEEP=true; export SLEEP
  make_mock claude 'args="$*"
if [[ "$args" == *"seo-research"* ]]; then
  count="$(grep -c "seo-research" "'"$MOCK_LOG"'/claude.log")"
  if [[ "$count" -eq 1 ]]; then
    echo '"'"'{"is_error":true,"terminal_reason":"api_error","api_error_status":529,"result":"API Error: 529 Overloaded"}'"'"'
  else
    echo '"'"'{"findings":[],"tools_used":["mcp__ubersuggest__site_audit"],"summary":"retry succeeded"}'"'"'
  fi
elif [[ "$args" == *"seo-plan"* ]]; then
  echo '"'"'{"tasks":[],"deferred":[],"summary":"no actionable tasks"}'"'"'
fi'
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" \
    bash "$RUN" demo --dry-run >/dev/null 2>&1
  research_calls="$(grep -c "seo-research" "$MOCK_LOG/claude.log")"
  assert_eq "$research_calls" "2" \
    "transient Claude API errors are retried"
  run_log="$(find "$SEO_AUTOPILOT_HOME/logs/demo" -name '*.log' -print -quit)"
  assert_contains "$(cat "$run_log")" "transient API error 529; retrying" \
    "transient retry is visible in the run log"
)

# A persistent transient failure stops after the bounded retry count and never
# reaches planning or publishing.
( setup_site
  SLEEP=true; export SLEEP
  make_mock claude 'echo '"'"'{"is_error":true,"terminal_reason":"api_error","api_error_status":529,"result":"API Error: 529 Overloaded"}'"'"''
  TESTS_RUN=$((TESTS_RUN + 1))
  if SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" \
    bash "$RUN" demo --dry-run >/dev/null 2>&1; then
    fail "persistent transient API errors were accepted"
  else
    pass "persistent transient API errors fail after bounded retries"
  fi
  research_calls="$(grep -c "seo-research" "$MOCK_LOG/claude.log")"
  assert_eq "$research_calls" "3" \
    "transient API retries are capped at three attempts"
  assert_not_contains "$(mock_calls claude)" "seo-plan" \
    "planning does not run after persistent research API failure"
)

# build fails, self-fix repairs it -> PR opens non-draft
# (marker lives at app/.build_ok, not repo-root — the self-fix commit must
# stay inside EDITABLE_GLOBS now that scope_guard enforces it, Fix 3)
( setup_site 'test -f app/.build_ok' ''
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  assert_contains "$(mock_calls claude)" "seo-fix" "build-fail run invokes the edit-only fixer agent"
  assert_contains "$(mock_calls curl)" "/pulls" "self-fix-repaired run opens a PR"
  assert_not_contains "$(mock_calls curl)" '"draft":true' "repaired build opens PR non-draft"
)

# build fails, self-fix does NOT repair it -> PR opens as draft
( setup_site 'false' ''
  make_mock claude 'args="$*"
if [[ "$args" == *"seo-research"* ]]; then echo '"'"'{"findings":[],"tools_used":["mcp__ubersuggest__site_audit"]}'"'"'
elif [[ "$args" == *"seo-plan"* ]]; then echo '"'"'{"tasks":[{"finding_id":"f1","category":"meta","paths":["app/a.txt"],"change":"test"}]}'"'"'
elif [[ "$args" == *"seo-implement-meta"* ]]; then echo change >> app/a.txt; echo '"'"'{"category":"meta","changed":["app/a.txt"],"skipped":[],"blocked":[]}'"'"'
elif [[ "$args" == *"seo-implement-schema"* ]]; then echo '"'"'{"category":"schema","changed":[],"skipped":[],"blocked":[]}'"'"'
elif [[ "$args" == *"seo-implement-a11y"* ]]; then echo '"'"'{"category":"a11y","changed":[],"skipped":[],"blocked":[]}'"'"'
elif [[ "$args" == *"seo-implement-content"* ]]; then echo '"'"'{"category":"content","changed":[],"skipped":[],"blocked":[]}'"'"'
elif [[ "$args" == *"seo-report"* ]]; then mkdir -p tasks/seo/reports; echo report > "tasks/seo/reports/$SEO_RUN_DATE.md"; echo '"'"'{"written":"report"}'"'"'
elif [[ "$args" == *"seo-review"* ]]; then echo '"'"'{"approved":true}'"'"'
elif [[ "$args" == *"seo-fix"* ]]; then echo '"'"'{"changed":[]}'"'"'; fi'
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  assert_contains "$(mock_calls claude)" "seo-fix" "still-failing build still invokes the fixer agent"
  assert_contains "$(mock_calls curl)" "/pulls" "still-failing build opens a PR anyway"
  assert_contains "$(mock_calls curl)" '"draft":true' "still-failing build opens PR as draft"
)

# scope violation trips the ERR trap -> Slack failure notification, no PR
( setup_site 'true' 'app/**'
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1 || true
  assert_not_contains "$(mock_calls curl)" "/pulls" "scope violation skips PR"
  assert_contains "$(mock_calls curl)" "failed" "scope violation posts a slack failure notification"
)

# Scope violations must stop before any agent-modified project code is built.
( setup_site 'buildcheck' 'app/**'
  make_mock buildcheck "touch \"$MOCK_LOG/build-was-run\""
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo --dry-run >/dev/null 2>&1 || true
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -e "$MOCK_LOG/build-was-run" ]]; then fail "scope violation executed the build"; else pass "scope violation blocks build execution"; fi
)

# secrets must NOT leak into the headless edit agent's environment (Fix 2).
# GH_TOKEN/SLACK_WEBHOOK_URL come from the profile's .secrets file, so without
# `env -u GH_TOKEN -u SLACK_WEBHOOK_URL` wrapping both claude invocations in
# bin/run.sh, this mock would see them set and write LEAK — verified by
# temporarily reverting the fix locally and re-running (see report).
( setup_site
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  if [[ -f "$MOCK_LOG/agent-secret-leak" ]]; then
    fail "GH_TOKEN/SLACK_WEBHOOK_URL leaked into an agent environment"
  else
    pass "GH_TOKEN/SLACK_WEBHOOK_URL stripped from claude's env"
  fi
  TESTS_RUN=$((TESTS_RUN + 1))
)

# Project builds must not inherit publishing/notification secrets.
( setup_site 'buildcheck'
  make_mock buildcheck "[ -z \"\${GH_TOKEN:-}\" ] && [ -z \"\${SLACK_WEBHOOK_URL:-}\" ] || { touch \"$MOCK_LOG/build-secret-leak\"; exit 9; }"
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo --dry-run >/dev/null 2>&1
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -e "$MOCK_LOG/build-secret-leak" ]]; then fail "build inherited publishing secrets"; else pass "build runs with publishing secrets stripped"; fi
  assert_contains "$(mock_calls docker)" "/.git:/workspace/.git:ro" \
    "isolated containers mount orchestrator Git metadata read-only"
)
