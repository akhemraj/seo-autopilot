#!/usr/bin/env bash
set -euo pipefail

github_repo_slug_from_url() {
  local url="$1" slug=""
  case "$url" in
    https://github.com/*)
      [[ "$url" != *'?'* && "$url" != *'#'* && "$url" != *'@github.com'* ]] || return 1
      slug="${url#https://github.com/}"
      ;;
    git@github.com:*)
      slug="${url#git@github.com:}"
      ;;
    ssh://git@github.com/*)
      slug="${url#ssh://git@github.com/}"
      ;;
    *) return 1 ;;
  esac
  slug="${slug%.git}"
  [[ "$slug" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 1
  [[ "$slug" != */.* && "$slug" != *..* ]] || return 1
  printf '%s' "$slug"
}

assert_github_remote_url() {
  github_repo_slug_from_url "$1" >/dev/null || {
    echo "unsupported Git remote; use an exact github.com HTTPS or SSH repository URL" >&2
    return 1
  }
}
