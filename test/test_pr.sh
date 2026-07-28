PRSH="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/pr.sh"

base_env() { # fake repo with a github-style origin remote
  REPO_PATH="$(mktemp -d)"
  ( cd "$REPO_PATH"; git init -q; git remote add origin "https://github.com/acme/site.git" )
  BASE_BRANCH=main; PR_LABELS="seo,automated"; GH_TOKEN="ghtok_SECRET"
  export REPO_PATH BASE_BRANCH PR_LABELS GH_TOKEN
}

# create path: no existing PR -> POST /pulls, url returned, token NOT in argv
( setup_mocks; base_env
  make_mock curl "args=\"\$*\"
if [[ \"\$args\" == *'pulls?head'* ]]; then echo '[]'
elif [[ \"\$args\" == *'/pulls'* ]]; then echo '{\"number\":9,\"html_url\":\"https://github.com/acme/site/pull/9\"}'
else echo '{}'; fi"
  source "$PRSH"
  body="$(mktemp)"; echo "report" > "$body"
  url="$(open_or_update_pr seo/weekly-2026-07-23 "SEO weekly" "$body" 0)"
  assert_eq "$url" "https://github.com/acme/site/pull/9" "returns created PR url"
  assert_contains "$(mock_calls curl)" "api.github.com/repos/acme/site/pulls" "POSTs to pulls endpoint"
  assert_not_contains "$(mock_calls curl)" "ghtok_SECRET" "token NOT in argv (ps-safe)"
  assert_contains "$(mock_stdin curl)" "Authorization: Bearer ghtok_SECRET" "token passed via stdin config"
)

# draft path sets draft:true in the JSON payload
( setup_mocks; base_env
  make_mock curl "args=\"\$*\"
if [[ \"\$args\" == *'pulls?head'* ]]; then echo '[]'
elif [[ \"\$args\" == *'/pulls'* ]]; then echo '{\"number\":10,\"html_url\":\"https://github.com/acme/site/pull/10\"}'
else echo '{}'; fi"
  source "$PRSH"
  body="$(mktemp)"; echo r > "$body"
  open_or_update_pr seo/weekly-2026-07-23 "t" "$body" 1 >/dev/null
  assert_contains "$(mock_calls curl)" '"draft":true' "draft flag in payload"
)

# update path: existing PR -> PATCH, returns existing url
( setup_mocks; base_env
  make_mock curl "args=\"\$*\"
if [[ \"\$args\" == *'pulls?head'* ]]; then echo '[{\"number\":3}]'
elif [[ \"\$args\" == *'/pulls/3'* ]]; then echo '{\"html_url\":\"https://github.com/acme/site/pull/3\"}'
else echo '{}'; fi"
  source "$PRSH"
  body="$(mktemp)"; echo r > "$body"
  url="$(open_or_update_pr seo/weekly-2026-07-23 "t" "$body" 0)"
  assert_eq "$url" "https://github.com/acme/site/pull/3" "returns existing PR url"
  assert_contains "$(mock_calls curl)" "PATCH" "updates via PATCH"
)

# repo_slug parses an SSH-form origin
( setup_mocks
  REPO_PATH="$(mktemp -d)"
  ( cd "$REPO_PATH"; git init -q; git remote add origin "git@github.com:acme/site.git" )
  export REPO_PATH
  source "$PRSH"
  assert_eq "$(repo_slug)" "acme/site" "repo_slug parses SSH origin"
)

# push_branch: the token never appears in git's argv (ps-safe)
( setup_mocks
  REPO_PATH="$(mktemp -d)"; GH_TOKEN="ghtok_SECRET"; export REPO_PATH GH_TOKEN
  make_mock git 'exit 0'
  source "$PRSH"
  push_branch seo/weekly-2026-07-23
  assert_contains "$(mock_calls git)" "push" "push_branch invokes git push"
  assert_not_contains "$(mock_calls git)" "ghtok_SECRET" "token NOT in git argv (ps-safe)"
)

# push_branch: SSH-form origin gets a non-fatal stderr warning (token auth won't apply)
( setup_mocks
  REPO_PATH="$(mktemp -d)"; GH_TOKEN="ghtok_SECRET"; export REPO_PATH GH_TOKEN
  make_mock git "args=\"\$*\"
if [[ \"\$args\" == *'remote get-url origin'* ]]; then echo 'git@github.com:acme/site.git'
else exit 0; fi"
  source "$PRSH"
  warn="$(push_branch seo/weekly-2026-07-23 2>&1 >/dev/null)"
  assert_contains "$warn" "SSH" "SSH origin push emits a token-auth-won't-apply warning"
  TESTS_RUN=$((TESTS_RUN + 1))
)

# push_branch: HTTPS-form origin does NOT warn
( setup_mocks
  REPO_PATH="$(mktemp -d)"; GH_TOKEN="ghtok_SECRET"; export REPO_PATH GH_TOKEN
  make_mock git "args=\"\$*\"
if [[ \"\$args\" == *'remote get-url origin'* ]]; then echo 'https://github.com/acme/site.git'
else exit 0; fi"
  source "$PRSH"
  warn="$(push_branch seo/weekly-2026-07-23 2>&1 >/dev/null)"
  assert_eq "$warn" "" "HTTPS origin push has no SSH warning"
)

# _apply_labels: a leading-comma value (empty PR_LABELS + appended ",needs-fix")
# must not send an empty label to the API
( setup_mocks; base_env
  make_mock curl "args=\"\$*\"
if [[ \"\$args\" == *'pulls?head'* ]]; then echo '[{\"number\":3}]'
elif [[ \"\$args\" == *'/pulls/3'* ]]; then echo '{\"html_url\":\"https://github.com/acme/site/pull/3\"}'
else echo 'ok'; fi"
  source "$PRSH"
  body="$(mktemp)"; echo r > "$body"
  PR_LABELS=",needs-fix"
  open_or_update_pr seo/weekly-2026-07-23 "t" "$body" 0 >/dev/null
  assert_not_contains "$(mock_calls curl)" '""' "leading-comma PR_LABELS produces no empty label"
  assert_contains "$(mock_calls curl)" "labels" "leading-comma PR_LABELS still applies the real label"
)

# HTTP/API failures and malformed success bodies must fail closed.
( setup_mocks; base_env
  make_mock curl 'echo "{\"message\":\"forbidden\"}"; exit 22'
  source "$PRSH"
  body="$(mktemp)"; echo r > "$body"
  TESTS_RUN=$((TESTS_RUN + 1))
  if open_or_update_pr seo/weekly-2026-07-23 "t" "$body" 0 >/dev/null 2>&1; then
    fail "GitHub HTTP failure was accepted"
  else
    pass "GitHub HTTP failure fails closed"
  fi
  assert_contains "$(mock_calls curl)" "--fail-with-body" "GitHub curl enables HTTP failure handling"
)

( setup_mocks; base_env
  make_mock curl "args=\"\$*\"
if [[ \"\$args\" == *'pulls?head'* ]]; then echo '[]'
else echo '{\"message\":\"missing PR fields\"}'; fi"
  source "$PRSH"
  body="$(mktemp)"; echo r > "$body"
  TESTS_RUN=$((TESTS_RUN + 1))
  if open_or_update_pr seo/weekly-2026-07-23 "t" "$body" 0 >/dev/null 2>&1; then
    fail "malformed PR response was accepted"
  else
    pass "malformed PR response fails closed"
  fi
)
