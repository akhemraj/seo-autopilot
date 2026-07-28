GITOPS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/git_ops.sh"

mk_repo() { # -> sets REPO_PATH with a base commit on 'main'
  REPO_PATH="$(mktemp -d)"; export REPO_PATH
  ( cd "$REPO_PATH"
    git init -q -b main
    git config user.email t@t.co; git config user.name t
    mkdir -p app/x components/campus
    echo base > app/x/a.txt; git add -A; git commit -q -m base )
  BASE_BRANCH=main; SEO_RUN_DATE=2026-07-23
  EXCLUDE_GLOBS="components/campus/** *.lock"; MAX_FILES=12; MAX_NEW_PAGES=2; MAX_DIFF_LINES=1500
  EDITABLE_GLOBS="app/** components/**"
  export BASE_BRANCH SEO_RUN_DATE EXCLUDE_GLOBS MAX_FILES MAX_NEW_PAGES MAX_DIFF_LINES EDITABLE_GLOBS
}

# glob_to_regex
( source "$GITOPS"
  assert_eq "$(glob_to_regex 'components/campus/**')" '^components/campus/.*$' "glob ** -> .*"
  assert_eq "$(glob_to_regex '*.lock')" '^[^/]*\.lock$' "glob *.lock escaped"
)

# create_branch is idempotent
( mk_repo; source "$GITOPS"
  b1="$(create_branch)"; b2="$(create_branch)"
  assert_eq "$b1" "seo/weekly-2026-07-23" "branch name"
  assert_eq "$b2" "seo/weekly-2026-07-23" "re-create reuses branch"
)

# has_commits false before, true after a commit
( mk_repo; source "$GITOPS"
  create_branch >/dev/null
  if has_commits; then fail "no commits yet"; else pass "has_commits false initially"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
  ( cd "$REPO_PATH"; echo edit >> app/x/a.txt; git commit -qam edit )
  if has_commits; then pass "has_commits true after commit"; else fail "should have commits"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)

# scope_guard: added Next.js route entrypoints cannot exceed MAX_NEW_PAGES
( mk_repo; source "$GITOPS"; MAX_NEW_PAGES=1
  create_branch >/dev/null
  ( cd "$REPO_PATH"; mkdir -p app/one app/two
    echo one > app/one/page.tsx; echo two > app/two/page.jsx
    git add -A; git commit -qam pages )
  if scope_guard 2>/dev/null; then fail "over MAX_NEW_PAGES must fail"; else pass "MAX_NEW_PAGES enforced"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)

# assert_clean_worktree rejects uncommitted agent/build output
( mk_repo; source "$GITOPS"
  create_branch >/dev/null
  ( cd "$REPO_PATH"; echo dirty >> app/x/a.txt )
  if assert_clean_worktree 2>/dev/null; then fail "dirty worktree must fail closed"; else pass "dirty worktree blocked before build"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)

# scope_guard: allowed edit passes, excluded edit fails
( mk_repo; source "$GITOPS"
  create_branch >/dev/null
  ( cd "$REPO_PATH"; echo hi >> app/x/a.txt; git commit -qam ok )
  if scope_guard 2>/dev/null; then pass "in-scope change passes"; else fail "in-scope should pass"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
  ( cd "$REPO_PATH"; echo x > components/campus/c.txt; git add -A; git commit -qam bad )
  if scope_guard 2>/dev/null; then fail "campus edit must fail scope_guard"; else pass "excluded change blocked"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)

# scope_guard: too many files fails
( mk_repo; source "$GITOPS"; MAX_FILES=1
  create_branch >/dev/null
  ( cd "$REPO_PATH"; echo a>app/f1; echo b>app/f2; git add -A; git commit -qam many )
  if scope_guard 2>/dev/null; then fail "over MAX_FILES must fail"; else pass "MAX_FILES enforced"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)

# scope_guard: NESTED file under an excluded glob must fail (regression for pathname-expansion bug)
( mk_repo; source "$GITOPS"
  create_branch >/dev/null
  ( cd "$REPO_PATH"; mkdir -p components/campus/legal; echo x > components/campus/legal/deep.txt; git add -A; git commit -qam nested )
  if scope_guard 2>/dev/null; then fail "nested excluded path must fail scope_guard"; else pass "nested excluded path blocked"; fi
)
# scope_guard: binary file change must fail closed
( mk_repo; source "$GITOPS"
  create_branch >/dev/null
  ( cd "$REPO_PATH"; printf '\x00\x01\x02BIN\xff' > app/logo.bin; git add -A; git commit -qam bin )
  if scope_guard 2>/dev/null; then fail "binary change must fail scope_guard"; else pass "binary change blocked"; fi
)

# scope_guard: positive EDITABLE_GLOBS allowlist — in-scope passes, root-level
# file outside EDITABLE_GLOBS fails, even though it doesn't match EXCLUDE_GLOBS
( mk_repo; source "$GITOPS"
  create_branch >/dev/null
  ( cd "$REPO_PATH"; echo hi >> app/x/a.txt; git commit -qam ok )
  if scope_guard 2>/dev/null; then pass "app/** change is inside EDITABLE_GLOBS"; else fail "in-EDITABLE change should pass"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)
( mk_repo; source "$GITOPS"
  create_branch >/dev/null
  ( cd "$REPO_PATH"; echo x > middleware.js; git add -A; git commit -qam mw )
  if scope_guard 2>/dev/null; then fail "middleware.js outside EDITABLE_GLOBS must fail scope_guard"; else pass "outside-EDITABLE change blocked"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)

# scope_guard: the tool's own report path is always allowed, regardless of EDITABLE_GLOBS
( mk_repo; source "$GITOPS"
  create_branch >/dev/null
  ( cd "$REPO_PATH"; mkdir -p tasks/seo/reports; echo report > "tasks/seo/reports/${SEO_RUN_DATE}.md"
    git add -A; git commit -qam report )
  if scope_guard 2>/dev/null; then pass "report path exempted from EDITABLE_GLOBS"; else fail "report path should always be allowed"; fi
  TESTS_RUN=$((TESTS_RUN + 1))
)
