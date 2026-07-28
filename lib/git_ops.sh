#!/usr/bin/env bash
set -euo pipefail
GIT=${GIT:-git}

glob_to_regex() { # glob -> anchored ERE
  local g="$1" out="" i c
  # escape ERE metacharacters except * ? which we translate
  for (( i=0; i<${#g}; i++ )); do
    c="${g:$i:1}"
    case "$c" in
      '*') out+="__STAR__" ;;
      '?') out+="." ;;
      '.'|'+'|'('|')'|'['|']'|'{'|'}'|'^'|'$'|'|'|'\\') out+="\\$c" ;;
      *) out+="$c" ;;
    esac
  done
  out="${out//__STAR____STAR__/.*}"   # ** -> .*
  out="${out//__STAR__/[^/]*}"        # *  -> [^/]*
  printf '^%s$' "$out"
}

_in_repo() { cd "$REPO_PATH"; }

preflight_repo() {
  _in_repo
  if [[ -n "$($GIT status --porcelain)" ]]; then
    echo "working tree not clean in $REPO_PATH — aborting" >&2; return 1
  fi
  $GIT fetch --quiet
  $GIT checkout --quiet "$BASE_BRANCH"
  # Only pull if the branch actually tracks an upstream (fresh/test repos with
  # a remote but no push yet — e.g. `git init && git remote add` — have none;
  # a normal `git clone` always does). Fail-closed otherwise: a tracked branch
  # still must fast-forward cleanly.
  if $GIT rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    $GIT pull --ff-only --quiet
  fi
}

create_branch() {
  _in_repo
  local b="seo/weekly-${SEO_RUN_DATE}"
  if $GIT show-ref --verify --quiet "refs/heads/$b"; then
    $GIT checkout --quiet "$b"
  else
    $GIT checkout --quiet -b "$b"
  fi
  printf '%s' "$b"
}

changed_files() { _in_repo; $GIT diff --name-only "${BASE_BRANCH}...HEAD"; }

assert_clean_worktree() {
  _in_repo
  if [[ -n "$($GIT status --porcelain)" ]]; then
    echo "working tree became dirty after the edit/build step — refusing to build or publish uncommitted changes" >&2
    return 1
  fi
}

scope_guard() {
  _in_repo
  local files; files="$(changed_files)"
  [[ -z "$files" ]] && return 0
  # exclude-glob check — split EXCLUDE_GLOBS WITHOUT pathname expansion
  local globs; read -ra globs <<< "$EXCLUDE_GLOBS"
  local glob re f offend=()
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    for glob in "${globs[@]}"; do
      re="$(glob_to_regex "$glob")"
      if [[ "$f" =~ $re ]]; then offend+=("$f"); break; fi
    done
  done <<< "$files"
  if [[ ${#offend[@]} -gt 0 ]]; then
    echo "scope_guard: changed files match EXCLUDE_GLOBS: ${offend[*]}" >&2; return 1
  fi
  # positive scope: every changed file must be inside EDITABLE_GLOBS (the tool's own report is always allowed)
  local eglobs; read -ra eglobs <<< "$EDITABLE_GLOBS"
  local outside=() ok
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    [[ "$f" == tasks/seo/reports/* ]] && continue
    ok=0
    for glob in "${eglobs[@]}"; do
      re="$(glob_to_regex "$glob")"
      if [[ "$f" =~ $re ]]; then ok=1; break; fi
    done
    [[ "$ok" -eq 0 ]] && outside+=("$f")
  done <<< "$files"
  if [[ ${#outside[@]} -gt 0 ]]; then
    echo "scope_guard: changed files outside EDITABLE_GLOBS: ${outside[*]}" >&2; return 1
  fi
  # reject binary changes (not reviewable by line count; would evade MAX_DIFF_LINES)
  if $GIT diff --numstat "${BASE_BRANCH}...HEAD" | awk '$1=="-"||$2=="-"{b=1} END{exit !b}'; then
    echo "scope_guard: binary file changes are not permitted" >&2; return 1
  fi
  # file-count cap
  local n; n="$(printf '%s\n' "$files" | grep -c . || true)"; n=${n:-0}
  if [[ "$n" -gt "$MAX_FILES" ]]; then
    echo "scope_guard: $n files > MAX_FILES=$MAX_FILES" >&2; return 1
  fi
  # New Next.js route cap. Count added App Router page entrypoints plus added
  # Pages Router entries (excluding API and framework-reserved files).
  [[ "$MAX_NEW_PAGES" =~ ^[0-9]+$ ]] || {
    echo "scope_guard: MAX_NEW_PAGES must be a non-negative integer" >&2; return 1
  }
  local new_pages=0 base
  while IFS= read -r f; do
    [[ -z "$f" ]] && continue
    if [[ "$f" =~ ^(src/)?app/(.*/)?page\.(js|jsx|ts|tsx|md|mdx)$ ]]; then
      new_pages=$((new_pages + 1))
    elif [[ "$f" =~ ^pages/.*\.(js|jsx|ts|tsx|md|mdx)$ && ! "$f" =~ ^pages/api/ ]]; then
      base="${f##*/}"
      [[ "$base" == _* ]] || new_pages=$((new_pages + 1))
    fi
  done < <($GIT diff --diff-filter=A --name-only "${BASE_BRANCH}...HEAD")
  if [[ "$new_pages" -gt "$MAX_NEW_PAGES" ]]; then
    echo "scope_guard: $new_pages new pages > MAX_NEW_PAGES=$MAX_NEW_PAGES" >&2; return 1
  fi
  # diff-line cap (text files)
  local lines
  lines="$($GIT diff --numstat "${BASE_BRANCH}...HEAD" | awk '{a+=$1; d+=$2} END{print a+d+0}')"
  if [[ "$lines" -gt "$MAX_DIFF_LINES" ]]; then
    echo "scope_guard: $lines changed lines > MAX_DIFF_LINES=$MAX_DIFF_LINES" >&2; return 1
  fi
  return 0
}

has_commits() {
  _in_repo
  [[ "$($GIT rev-list --count "${BASE_BRANCH}..HEAD")" -gt 0 ]]
}
