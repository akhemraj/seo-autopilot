#!/usr/bin/env bash
set -euo pipefail

create_agent_workspace() {
  AGENT_RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/seo-autopilot.${SLUG}.XXXXXX")"
  chmod 700 "$AGENT_RUN_DIR"
  AGENT_WORKSPACE="$AGENT_RUN_DIR/workspace"
  AGENT_OUTPUTS="$AGENT_RUN_DIR/outputs"
  mkdir -m 700 "$AGENT_WORKSPACE" "$AGENT_OUTPUTS"

  local base_sha
  base_sha="$($GIT -C "$REPO_PATH" rev-parse "$BASE_BRANCH^{commit}")" || return 1
  $GIT -C "$REPO_PATH" archive "$base_sha" | tar -x -C "$AGENT_WORKSPACE" || return 1
  (
    cd "$AGENT_WORKSPACE"
    $GIT init -q -b agent-base
    $GIT config user.name "SEO Autopilot"
    $GIT config user.email "seo-autopilot@localhost"
    $GIT config core.hooksPath /dev/null
    $GIT add -A
    $GIT commit -q -m "agent workspace base"
  ) || return 1
  AGENT_BASE_SHA="$($GIT -C "$AGENT_WORKSPACE" rev-parse HEAD)"
  export AGENT_RUN_DIR AGENT_WORKSPACE AGENT_OUTPUTS AGENT_BASE_SHA
}

cleanup_agent_workspace() {
  [[ -n "${AGENT_RUN_DIR:-}" && -d "${AGENT_RUN_DIR:-}" ]] || return 0
  # Keep failed-run artifacts for diagnosis. They contain tracked source and
  # agent output, but never the real .git directory or publishing credentials.
  if [[ "${KEEP_AGENT_WORKSPACE:-0}" == "1" ]]; then
    log_warn "retained isolated agent workspace: $AGENT_RUN_DIR"
    return 0
  fi
  rm -rf -- "$AGENT_RUN_DIR"
}

agent_workspace_has_changes() {
  [[ -n "$($GIT -C "$AGENT_WORKSPACE" status --porcelain)" ]]
}

commit_agent_changes() {
  local category="$1"
  agent_workspace_has_changes || return 0
  $GIT -C "$AGENT_WORKSPACE" add -A
  $GIT -C "$AGENT_WORKSPACE" \
    -c core.hooksPath=/dev/null \
    commit -q -m "seo($category): automated improvements"
}

materialize_agent_commits() {
  local patch="$AGENT_RUN_DIR/validated-series.patch"
  : > "$patch"
  $GIT -C "$AGENT_WORKSPACE" format-patch --stdout \
    "${AGENT_BASE_SHA}..HEAD" > "$patch" || return 1
  [[ -s "$patch" ]] || return 0
  (
    cd "$REPO_PATH"
    $GIT -c core.hooksPath=/dev/null am --3way "$patch"
  ) || return 1
}
