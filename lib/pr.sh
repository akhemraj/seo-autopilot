#!/usr/bin/env bash
set -euo pipefail
CURL=${CURL:-curl}
GIT=${GIT:-git}
: "${SEO_AUTOPILOT_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
# shellcheck disable=SC1091
source "$SEO_AUTOPILOT_HOME/lib/remote.sh"

repo_slug() { # -> owner/repo from origin remote
  local u; u="$($GIT -C "$REPO_PATH" config --get remote.origin.url)"
  github_repo_slug_from_url "$u"
}

push_branch() { # branch — token read from env by the helper, never in argv
  local origin_url slug; origin_url="$($GIT -C "$REPO_PATH" config --get remote.origin.url)"
  slug="$(github_repo_slug_from_url "$origin_url")" || return 1
  if [[ "$origin_url" == git@* || "$origin_url" == *ssh://* ]]; then
    echo "push_branch: origin '$origin_url' is an SSH remote — the fine-grained GH_TOKEN credential helper does NOT apply; git will use the ambient SSH key instead. The scoped-token threat model is not in effect for this push." >&2
  fi
  ( cd "$REPO_PATH"
    export SEO_GITHUB_PATH="$slug"
    export GIT_TERMINAL_PROMPT=0
    $GIT -c credential.helper='' \
         -c credential.useHttpPath=true \
         -c core.hooksPath=/dev/null \
         -c "credential.helper=!$SEO_AUTOPILOT_HOME/bin/git-credential-github" \
         push -u origin "$1" --quiet )
}

# _gh_api METHOD URL [json-body] — token via stdin config (never argv)
_gh_api() {
  local method="$1" url="$2" data="${3:-}" cfg
  cfg="$(printf 'header = "Authorization: Bearer %s"\nheader = "Accept: application/vnd.github+json"\nheader = "X-GitHub-Api-Version: 2022-11-28"\n' "$GH_TOKEN")"
  if [[ -n "$data" ]]; then
    printf '%s' "$cfg" | "$CURL" -q --proto '=https' --tlsv1.2 --max-redirs 0 --fail-with-body -sS --config - -X "$method" "$url" -d "$data"
  else
    printf '%s' "$cfg" | "$CURL" -q --proto '=https' --tlsv1.2 --max-redirs 0 --fail-with-body -sS --config - -X "$method" "$url"
  fi
}

_apply_labels() { # api num
  [[ -n "$PR_LABELS" ]] || return 0
  # Normalize: drop empty entries from leading/trailing/duplicate commas
  # (e.g. a site with PR_LABELS="" plus bin/run.sh's ",needs-fix" append),
  # so we never send an empty label to the API.
  local labels; labels="$(printf '%s' "$PR_LABELS" | jq -Rc 'split(",") | map(select(. != ""))')"
  [[ "$labels" == "[]" ]] && return 0
  _gh_api POST "$1/issues/$2/labels" "$(jq -nc --argjson l "$labels" '{labels:$l}')" >/dev/null
}

open_or_update_pr() { # branch title body_file draft(0|1)
  local branch="$1" title="$2" body_file="$3" draft="$4"
  local slug owner repo; slug="$(repo_slug)" || return 1; owner="${slug%%/*}"; repo="${slug##*/}"
  local api="https://api.github.com/repos/$owner/$repo"
  local body; body="$(cat "$body_file")" || return 1
  local num search
  search="$(_gh_api GET "$api/pulls?head=$owner:$branch&state=open")" || return 1
  num="$(printf '%s' "$search" \
    | jq -er 'if type != "array" then error("expected pull request array") elif length == 0 then "" else .[0].number end')" \
    || return 1
  if [[ -n "$num" ]]; then
    # NOTE: intentionally not sending `draft` here. GitHub's REST API cannot
    # convert an already-open PR to draft — `draft` is create-only via REST;
    # flipping an existing PR to draft requires the GraphQL
    # convertPullRequestToDraft mutation, which this script doesn't use. So on
    # a re-run where the build fails against an existing (already non-draft)
    # PR, we can't represent that regression as draft state here — the
    # `[needs-fix]` title prefix + `needs-fix` label that bin/run.sh adds are
    # the failure signal instead.
    local update_payload existing
    update_payload="$(jq -nc --arg b "$body" '{body:$b}')" || return 1
    _gh_api PATCH "$api/pulls/$num" "$update_payload" >/dev/null || return 1
    _apply_labels "$api" "$num" || return 1
    existing="$(_gh_api GET "$api/pulls/$num")" || return 1
    printf '%s' "$existing" \
      | jq -er '.html_url | select(type == "string" and length > 0)' \
      || return 1
    return 0
  fi
  local draftb=false; [[ "$draft" == "1" ]] && draftb=true
  local payload resp url
  payload="$(jq -nc --arg t "$title" --arg h "$branch" --arg base "$BASE_BRANCH" --arg b "$body" --argjson d "$draftb" \
    '{title:$t,head:$h,base:$base,body:$b,draft:$d}')" || return 1
  resp="$(_gh_api POST "$api/pulls" "$payload")" || return 1
  num="$(printf '%s' "$resp" | jq -er '.number | select(type == "number")')" || return 1
  url="$(printf '%s' "$resp" | jq -er '.html_url | select(type == "string" and length > 0)')" || return 1
  _apply_labels "$api" "$num" || return 1
  printf '%s' "$url"
}
