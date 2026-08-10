ADD="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/bin/add-site.sh"
HOME_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_add_site() { # optional --no-schedule
  local schedule_arg="${1:-}"
  setup_mocks
  SEO_AUTOPILOT_HOME="$(mktemp -d)"; export SEO_AUTOPILOT_HOME
  mkdir -p "$SEO_AUTOPILOT_HOME/sites" "$SEO_AUTOPILOT_HOME/logs" "$SEO_AUTOPILOT_HOME/bin" "$SEO_AUTOPILOT_HOME/lib"
  cp -R "$HOME_DIR/templates" "$SEO_AUTOPILOT_HOME/templates"
  cp "$HOME_DIR/lib/remote.sh" "$SEO_AUTOPILOT_HOME/lib/remote.sh"
  cp "$HOME_DIR/bin/run.sh" "$SEO_AUTOPILOT_HOME/bin/run.sh" 2>/dev/null || touch "$SEO_AUTOPILOT_HOME/bin/run.sh"
  LAUNCH_AGENTS_DIR="$(mktemp -d)"; export LAUNCH_AGENTS_DIR
  make_mock launchctl 'exit 0'
  repo="$(mktemp -d)"; ( cd "$repo" && git init -q && git remote add origin https://github.com/acme/demo.git )
  AS_DOMAIN="demo.com" AS_REPO_PATH="$repo" AS_UBERSUGGEST_TARGET="demo.com" \
  AS_SCHEDULE_HOUR=12 AS_SCHEDULE_WEEKDAY=1 AS_EXCLUDE_GLOBS="components/campus/**" AS_MAX_FILES=12 \
    bash "$ADD" demo ${schedule_arg:+"$schedule_arg"} >/dev/null 2>&1
}

( run_add_site

  assert_eq "$(grep -c 'DOMAIN="demo.com"' "$SEO_AUTOPILOT_HOME/sites/demo.conf")" "1" "profile written"
  assert_contains "$(cat "$SEO_AUTOPILOT_HOME/sites/demo.conf")" 'EXCLUDE_GLOBS="components/campus/**"' "exclude glob substituted"
  assert_eq "$(stat -f '%Lp' "$SEO_AUTOPILOT_HOME/sites/demo.secrets")" "600" "secrets chmod 600"
  plist="$LAUNCH_AGENTS_DIR/com.seo-autopilot.demo.plist"
  assert_contains "$(cat "$plist")" "<integer>12</integer>" "plist hour set"
  assert_contains "$(cat "$plist")" "<key>PATH</key>" "plist bakes a PATH for launchd"
  assert_not_contains "$(cat "$plist")" "__PATH__" "PATH placeholder substituted"

  gitdir="$(cd "$(dirname "$(command -v git)")" && pwd)"
  assert_contains "$(cat "$plist")" "$gitdir" "plist PATH includes a real resolved tool dir"

  TESTS_RUN=$((TESTS_RUN + 1))
  if printf '%s\n' "$(mock_calls launchctl)" | grep -q '^load '; then pass "launchctl load invoked"; else fail "launchctl load not invoked"; fi
)

( run_add_site --no-schedule
  assert_eq "$(mock_calls launchctl)" "" "--no-schedule does not invoke launchctl"
  plist="$LAUNCH_AGENTS_DIR/com.seo-autopilot.demo.plist"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -e "$plist" ]]; then
    fail "--no-schedule created a launchd plist"
  else
    pass "--no-schedule leaves scheduling to the user"
  fi
  assert_contains "$(cat "$SEO_AUTOPILOT_HOME/sites/demo.conf")" \
    'DOMAIN="demo.com"' "--no-schedule still creates the site profile"
)

( # Bug 4 regression: special chars in NOTES must not corrupt the generated .conf
  setup_mocks
  SEO_AUTOPILOT_HOME="$(mktemp -d)"; export SEO_AUTOPILOT_HOME
  mkdir -p "$SEO_AUTOPILOT_HOME/sites" "$SEO_AUTOPILOT_HOME/logs" "$SEO_AUTOPILOT_HOME/bin" "$SEO_AUTOPILOT_HOME/lib"
  cp -R "$HOME_DIR/templates" "$SEO_AUTOPILOT_HOME/templates"
  cp "$HOME_DIR/lib/remote.sh" "$SEO_AUTOPILOT_HOME/lib/remote.sh"
  cp "$HOME_DIR/bin/run.sh" "$SEO_AUTOPILOT_HOME/bin/run.sh" 2>/dev/null || touch "$SEO_AUTOPILOT_HOME/bin/run.sh"
  LAUNCH_AGENTS_DIR="$(mktemp -d)"; export LAUNCH_AGENTS_DIR
  make_mock launchctl 'exit 0'
  repo="$(mktemp -d)"; ( cd "$repo" && git init -q && git remote add origin https://github.com/acme/demo.git )
  AS_DOMAIN="demo.com" AS_REPO_PATH="$repo" AS_UBERSUGGEST_TARGET="demo.com" \
  AS_SCHEDULE_HOUR=12 AS_SCHEDULE_WEEKDAY=1 AS_EXCLUDE_GLOBS="components/campus/**" AS_MAX_FILES=12 \
  AS_NOTES='Ship it & keep it | quote "this" $now' \
    bash "$ADD" demo >/dev/null 2>&1

  conf="$SEO_AUTOPILOT_HOME/sites/demo.conf"

  TESTS_RUN=$((TESTS_RUN + 1))
  if ( set -e; source "$conf" ); then pass "conf with special-char NOTES sources without error"; else fail "conf with special-char NOTES sources without error"; fi

  domain_readback="$(bash -c "source '$conf' >/dev/null 2>&1; printf '%s' \"\$DOMAIN\"")"
  assert_eq "$domain_readback" "demo.com" "DOMAIN still reads back correctly after special-char NOTES"
  assert_not_contains "$(cat "$conf")" "__NOTES__" "no literal __NOTES__ placeholder remains"
)

( # Fresh setup: a missing REPO_PATH is cloned automatically
  setup_mocks
  SEO_AUTOPILOT_HOME="$(mktemp -d)"; export SEO_AUTOPILOT_HOME
  mkdir -p "$SEO_AUTOPILOT_HOME/sites" "$SEO_AUTOPILOT_HOME/logs" "$SEO_AUTOPILOT_HOME/bin" "$SEO_AUTOPILOT_HOME/lib"
  cp -R "$HOME_DIR/templates" "$SEO_AUTOPILOT_HOME/templates"
  cp "$HOME_DIR/lib/remote.sh" "$SEO_AUTOPILOT_HOME/lib/remote.sh"
  cp "$HOME_DIR/bin/run.sh" "$SEO_AUTOPILOT_HOME/bin/run.sh"
  LAUNCH_AGENTS_DIR="$(mktemp -d)"; export LAUNCH_AGENTS_DIR
  make_mock launchctl 'exit 0'

  source_repo="$(mktemp -d)"
  ( cd "$source_repo"; git init -q -b main; git config user.email t@t.co; git config user.name t
    echo seed > README.md; git add README.md; git commit -q -m seed )
  clone_path="$(mktemp -d)/demo"
  real_git="$(command -v git)"
  make_mock git 'if [[ "${1:-}" == "clone" ]]; then
  target="${@: -1}"
  "'"$real_git"'" clone -q -- "'"$source_repo"'" "$target"
  "'"$real_git"'" -C "$target" remote set-url origin https://github.com/acme/demo.git
  exit 0
fi
exec "'"$real_git"'" "$@"'

  AS_DOMAIN="demo.com" AS_REPO_PATH="$clone_path" AS_REPO_URL="https://github.com/acme/demo.git" \
  AS_UBERSUGGEST_TARGET="demo.com" AS_SCHEDULE_HOUR=12 AS_SCHEDULE_WEEKDAY=1 \
  AS_EXCLUDE_GLOBS="components/campus/**" AS_MAX_FILES=12 \
    bash "$ADD" demo >/dev/null 2>&1

  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -d "$clone_path/.git" ]]; then pass "fresh setup clones a missing repository"; else fail "fresh setup did not clone repository"; fi
  assert_eq "$(git -C "$clone_path" remote get-url origin)" "https://github.com/acme/demo.git" "fresh clone records the requested origin"
  assert_contains "$(cat "$SEO_AUTOPILOT_HOME/sites/demo.conf")" "REPO_PATH=\"$clone_path\"" "fresh clone path is written to profile"
)

( # Safety: onboarding must not overwrite an unrelated directory
  setup_mocks
  SEO_AUTOPILOT_HOME="$(mktemp -d)"; export SEO_AUTOPILOT_HOME
  mkdir -p "$SEO_AUTOPILOT_HOME/sites" "$SEO_AUTOPILOT_HOME/logs" "$SEO_AUTOPILOT_HOME/bin" "$SEO_AUTOPILOT_HOME/lib"
  cp -R "$HOME_DIR/templates" "$SEO_AUTOPILOT_HOME/templates"
  cp "$HOME_DIR/lib/remote.sh" "$SEO_AUTOPILOT_HOME/lib/remote.sh"
  cp "$HOME_DIR/bin/run.sh" "$SEO_AUTOPILOT_HOME/bin/run.sh"
  LAUNCH_AGENTS_DIR="$(mktemp -d)"; export LAUNCH_AGENTS_DIR
  make_mock launchctl 'exit 0'
  occupied="$(mktemp -d)"; touch "$occupied/user-file"

  TESTS_RUN=$((TESTS_RUN + 1))
  if AS_DOMAIN="demo.com" AS_REPO_PATH="$occupied" AS_REPO_URL="https://github.com/acme/demo.git" \
    AS_UBERSUGGEST_TARGET="demo.com" AS_SCHEDULE_HOUR=12 AS_SCHEDULE_WEEKDAY=1 \
    AS_EXCLUDE_GLOBS="components/campus/**" AS_MAX_FILES=12 \
      bash "$ADD" demo >/dev/null 2>&1; then
    fail "fresh setup overwrote a non-git directory"
  else
    pass "fresh setup rejects a non-empty non-git directory"
  fi
  assert_eq "$(cat "$occupied/user-file")" "" "existing directory contents are preserved"
)
