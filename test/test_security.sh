ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

( source "$ROOT/lib/remote.sh"
  assert_eq "$(github_repo_slug_from_url https://github.com/acme/site.git)" \
    "acme/site" "strict remote parser accepts GitHub HTTPS"
  assert_eq "$(github_repo_slug_from_url git@github.com:acme/site.git)" \
    "acme/site" "strict remote parser accepts GitHub SSH"

  TESTS_RUN=$((TESTS_RUN + 1))
  if github_repo_slug_from_url https://github.com.evil.example/acme/site >/dev/null 2>&1; then
    fail "GitHub lookalike host was accepted"
  else
    pass "GitHub lookalike host is rejected"
  fi

  TESTS_RUN=$((TESTS_RUN + 1))
  if github_repo_slug_from_url https://user@github.com/acme/site >/dev/null 2>&1; then
    fail "embedded remote credentials were accepted"
  else
    pass "embedded remote credentials are rejected"
  fi
)

( helper="$ROOT/bin/git-credential-github"
  GH_TOKEN="github_pat_TEST_SECRET"; SEO_GITHUB_PATH="acme/site"
  export GH_TOKEN SEO_GITHUB_PATH
  allowed="$(printf 'protocol=https\nhost=github.com\npath=acme/site.git\n\n' | "$helper" get)"
  assert_contains "$allowed" "password=github_pat_TEST_SECRET" \
    "credential helper serves the exact GitHub repository"

  denied="$(printf 'protocol=https\nhost=attacker.example\npath=acme/site.git\n\n' | "$helper" get)"
  assert_eq "$denied" "" "credential helper refuses a different host"

  denied="$(printf 'protocol=https\nhost=github.com\npath=acme/other.git\n\n' | "$helper" get)"
  assert_eq "$denied" "" "credential helper refuses a different repository"
)

( source "$ROOT/lib/security.sh"
  tree="$(mktemp -d)"
  ( cd "$tree"; git init -q -b main; git config user.email t@t.co
    git config user.name t; echo "github_pat_TEST_SECRET" > tracked.txt
    git add -A; git commit -qm secret )
  GH_TOKEN="github_pat_TEST_SECRET"; SLACK_WEBHOOK_URL=""; GITLEAKS=true; GIT=git
  export GH_TOKEN SLACK_WEBHOOK_URL GITLEAKS GIT
  TESTS_RUN=$((TESTS_RUN + 1))
  if scan_workspace_secrets "$tree" >/dev/null 2>&1; then
    fail "exact loaded token in tracked source passed the secret gate"
  else
    pass "exact loaded token is blocked by the secret gate"
  fi
)

( source "$ROOT/lib/security.sh"
  tree="$(mktemp -d)"
  ( cd "$tree"; git init -q -b main; git config user.email t@t.co
    git config user.name t
    mkdir -p app
    printf 'BASELINE_GENERIC_FINDING\n' > app/existing.js
    printf 'base\n' > app/change.js
    git add -A
    git commit -qm base
    printf 'safe candidate change\n' >> app/change.js )
  detector="$(mktemp)"
  cat > "$detector" <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
[[ "$input" != *BASELINE_GENERIC_FINDING* ]] || exit 1
[[ "$input" != *CANDIDATE_GENERIC_FINDING* ]] || exit 1
EOF
  chmod +x "$detector"
  BASE_BRANCH=main GH_TOKEN="" SLACK_WEBHOOK_URL="" GITLEAKS="$detector" GIT=git
  export BASE_BRANCH GH_TOKEN SLACK_WEBHOOK_URL GITLEAKS GIT
  TESTS_RUN=$((TESTS_RUN + 1))
  if scan_workspace_secrets "$tree" >/dev/null 2>&1; then
    pass "pre-existing generic findings do not block a safe candidate diff"
  else
    fail "baseline-only generic finding blocked the candidate"
  fi

  printf 'CANDIDATE_GENERIC_FINDING\n' > "$tree/app/new.js"
  TESTS_RUN=$((TESTS_RUN + 1))
  if scan_workspace_secrets "$tree" >/dev/null 2>&1; then
    fail "secret detector missed an untracked candidate file"
  else
    pass "untracked candidate content is included in the secret scan"
  fi
)

( source "$ROOT/lib/security.sh"
  log_info() { :; }
  log_skip() { :; }
  tree="$(mktemp -d)"
  printf '{}\n' > "$tree/package.json"
  printf '{}\n' > "$tree/package-lock.json"
  DEPENDENCY_CMD=auto
  _isolated_container() {
    printf 'network=%s command=%s' "$2" "$3"
  }
  prepared="$(prepare_build_dependencies "$tree")"
  assert_contains "$prepared" "network=bridge" \
    "dependency preparation receives network only in its isolated phase"
  assert_contains "$prepared" "npm ci --ignore-scripts" \
    "automatic npm preparation disables lifecycle scripts"
)

( source "$ROOT/lib/security.sh"
  tree="$(mktemp -d)"
  ( cd "$tree"; git init -q -b agent-base; git config user.email t@t.co
    git config user.name t; mkdir app; echo base > app/a
    git add -A; git commit -qm base )
  AGENT_WORKSPACE="$tree"; GIT=git
  mkdir -p "$tree/node_modules/pkg" "$tree/.next"
  echo generated > "$tree/node_modules/pkg/index.js"
  echo generated > "$tree/.next/output"
  cleanup_build_workspace "$tree"
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ -e "$tree/node_modules" || -e "$tree/.next" ]]; then
    fail "dependency/build artifacts survived workspace cleanup"
  else
    pass "dependency/build artifacts are removed before agents and final scans"
  fi
)
