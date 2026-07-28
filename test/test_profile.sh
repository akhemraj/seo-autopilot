PROFILE_SH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/profile.sh"

setup_profile_home() { # writes a fixture profile; sets SEO_AUTOPILOT_HOME
  SEO_AUTOPILOT_HOME="$(mktemp -d)"; export SEO_AUTOPILOT_HOME
  mkdir -p "$SEO_AUTOPILOT_HOME/sites"
  local repo; repo="$(mktemp -d)"; ( cd "$repo" && git init -q )
  cat > "$SEO_AUTOPILOT_HOME/sites/demo.conf" <<EOF
DOMAIN="demo.com"
REPO_PATH="$repo"
UBERSUGGEST_TARGET="demo.com"
MAX_FILES=7
EOF
}

# defaults applied + required parsed
( setup_profile_home
  source "$PROFILE_SH"
  load_profile demo
  assert_eq "$DOMAIN" "demo.com" "reads DOMAIN"
  assert_eq "$BASE_BRANCH" "main" "defaults BASE_BRANCH"
  assert_eq "$SCHEDULE_HOUR" "12" "defaults SCHEDULE_HOUR to 12"
  assert_eq "$SCHEDULE_WEEKDAY" "1" "defaults SCHEDULE_WEEKDAY to Mon"
  assert_eq "$MAX_FILES" "7" "profile overrides MAX_FILES"
  assert_eq "$MAX_NEW_PAGES" "2" "defaults MAX_NEW_PAGES"
  assert_eq "$BUILD_CMD" "yarn build" "defaults BUILD_CMD"
)

# missing required -> failure
( setup_profile_home
  echo 'DOMAIN=""' >> "$SEO_AUTOPILOT_HOME/sites/demo.conf"
  cat > "$SEO_AUTOPILOT_HOME/sites/bad.conf" <<EOF
REPO_PATH="/tmp"
EOF
  source "$PROFILE_SH"
  if load_profile bad 2>/dev/null; then fail "missing DOMAIN should fail"; else pass "missing DOMAIN fails"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)

# secrets must not leak across profiles (regression: SLACK_WEBHOOK_URL/GH_TOKEN reset)
( SEO_AUTOPILOT_HOME="$(mktemp -d)"; export SEO_AUTOPILOT_HOME; mkdir -p "$SEO_AUTOPILOT_HOME/sites"
  repo_a="$(mktemp -d)"; ( cd "$repo_a" && git init -q )
  repo_b="$(mktemp -d)"; ( cd "$repo_b" && git init -q )
  cat > "$SEO_AUTOPILOT_HOME/sites/siteA.conf" <<EOF
DOMAIN="a.com"
REPO_PATH="$repo_a"
UBERSUGGEST_TARGET="a.com"
EOF
  cat > "$SEO_AUTOPILOT_HOME/sites/siteA.secrets" <<EOF
SLACK_WEBHOOK_URL="AAA"
EOF
  cat > "$SEO_AUTOPILOT_HOME/sites/siteB.conf" <<EOF
DOMAIN="b.com"
REPO_PATH="$repo_b"
UBERSUGGEST_TARGET="b.com"
EOF
  # siteB intentionally has no .secrets file
  source "$PROFILE_SH"
  load_profile siteA
  load_profile siteB
  assert_eq "$SLACK_WEBHOOK_URL" "" "secrets do not leak between profiles"
)

# REPO_PATH not a git repo -> failure
( SEO_AUTOPILOT_HOME="$(mktemp -d)"; export SEO_AUTOPILOT_HOME; mkdir -p "$SEO_AUTOPILOT_HOME/sites"
  cat > "$SEO_AUTOPILOT_HOME/sites/nogit.conf" <<EOF
DOMAIN="x.com"
REPO_PATH="$(mktemp -d)"
UBERSUGGEST_TARGET="x.com"
EOF
  source "$PROFILE_SH"
  if load_profile nogit 2>/dev/null; then fail "non-git REPO_PATH should fail"; else pass "non-git REPO_PATH fails"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)
