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
  cp "$HOME_DIR/bin/run.sh" "$SEO_AUTOPILOT_HOME/run.sh" 2>/dev/null || true
  local repo bare; repo="$(mktemp -d)"; bare="$(mktemp -d)/origin.git"; git init -q --bare "$bare"
  ( cd "$repo"; git init -q -b main; git config user.email t@t.co; git config user.name t
    git remote add origin "$bare"
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
  # mocks: claude makes an in-scope edit+commit; git real; curl fake (GitHub REST + Slack)
  make_mock claude "pwd > \"$MOCK_LOG/claude.cwd\"; echo change >> app/a.txt; git commit -qam 'seo(meta): x'"
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
  assert_eq "$(cat "$MOCK_LOG/claude.cwd")" "$TARGET_REPO" "claude runs inside REPO_PATH"
)

# full run: REST PR create + slack success called
( setup_site
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  assert_contains "$(mock_calls curl)" "/pulls" "full run opens PR via REST"
  assert_contains "$(mock_stdin curl)" "hooks.slack.com" "full run posts slack (URL via stdin)"
)

# no-changes run: claude makes no commit -> no PR, slack 'no changes'
( setup_site
  make_mock claude "true"   # no edits
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  assert_not_contains "$(mock_calls curl)" "/pulls" "no-changes run skips PR"
  assert_contains "$(mock_stdin curl)" "hooks.slack.com" "no-changes still notifies (URL via stdin)"
)

# build fails, self-fix repairs it -> PR opens non-draft
# (marker lives at app/.build_ok, not repo-root — the self-fix commit must
# stay inside EDITABLE_GLOBS now that scope_guard enforces it, Fix 3)
( setup_site 'test -f __REPO__/app/.build_ok' ''
  make_mock claude "args=\"\$*\"
if [[ \"\$args\" == *'/seo-weekly'* ]]; then
  cd \"$TARGET_REPO\"; echo change >> app/a.txt; git commit -qam 'seo(meta): x'
elif [[ \"\$args\" == *'Fix ONLY'* ]]; then
  cd \"$TARGET_REPO\"; touch app/.build_ok; git add -A; git commit -qam 'seo(fix): build'
fi"
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  assert_contains "$(mock_calls claude)" "Fix ONLY" "build-fail run invokes the self-fix claude pass"
  assert_contains "$(mock_calls curl)" "/pulls" "self-fix-repaired run opens a PR"
  assert_not_contains "$(mock_calls curl)" '"draft":true' "repaired build opens PR non-draft"
)

# build fails, self-fix does NOT repair it -> PR opens as draft
( setup_site 'false' ''
  make_mock claude "args=\"\$*\"
if [[ \"\$args\" == *'/seo-weekly'* ]]; then
  cd \"$TARGET_REPO\"; echo change >> app/a.txt; git commit -qam 'seo(meta): x'
elif [[ \"\$args\" == *'Fix ONLY'* ]]; then
  true   # self-fix pass makes no repair
fi"
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  assert_contains "$(mock_calls claude)" "Fix ONLY" "still-failing build still invokes the self-fix claude pass"
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
  make_mock claude "[ -n \"\${GH_TOKEN:-}\" ] && echo LEAK >> \"$TARGET_REPO/.claude_env\"
[ -n \"\${SLACK_WEBHOOK_URL:-}\" ] && echo LEAK >> \"$TARGET_REPO/.claude_env\"
cd \"$TARGET_REPO\"; echo change >> app/a.txt; git commit -qam 'seo(meta): x'"
  SEO_AUTOPILOT_HOME="$SEO_AUTOPILOT_HOME" bash "$RUN" demo >/dev/null 2>&1
  if [[ -f "$TARGET_REPO/.claude_env" ]]; then
    fail "GH_TOKEN/SLACK_WEBHOOK_URL leaked into claude's env ($(cat "$TARGET_REPO/.claude_env" | tr '\n' ' '))"
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
)
