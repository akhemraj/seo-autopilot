#!/usr/bin/env bash
set -euo pipefail

_scan_known_secret() {
  local value="$1" label="$2" tree="$3"
  [[ -z "$value" ]] && return 0
  if printf '%s\n' "$value" | $GIT -C "$tree" grep -F -q -f -; then
    echo "secret scan: candidate changes contain the loaded $label" >&2
    return 1
  fi
}

_scan_candidate_additions() {
  local tree="$1" file
  [[ -n "${BASE_BRANCH:-}" ]] || {
    echo "secret scan: BASE_BRANCH is required" >&2
    return 1
  }
  $GIT -C "$tree" rev-parse --verify "${BASE_BRANCH}^{commit}" >/dev/null || {
    echo "secret scan: cannot resolve candidate baseline $BASE_BRANCH" >&2
    return 1
  }

  if ! {
    # Scan only added lines from tracked candidate changes. This avoids making
    # every run fail on a pre-existing Gitleaks finding in the target baseline.
    $GIT -C "$tree" diff --no-color --no-ext-diff --unified=0 \
      "$BASE_BRANCH" -- |
      awk '/^\+\+\+ / { next } /^\+/ { sub(/^\+/, ""); print }'

    # `git diff` omits untracked files, so include every publishable untracked
    # file in full. Ignored files cannot be committed by the orchestrator.
    while IFS= read -r -d '' file; do
      printf '\nFILE:%s\n' "$file"
      command cat -- "$tree/$file"
    done < <($GIT -C "$tree" ls-files --others --exclude-standard -z)
  } | "${GITLEAKS:-gitleaks}" stdin --no-banner --redact \
    --exit-code 1 >/dev/null; then
    return 1
  fi
}

scan_workspace_secrets() {
  local tree="$1"
  # Loaded publishing credentials are checked against the entire tracked tree:
  # finding either exact value is always fatal, even if it predates this run.
  _scan_known_secret "${GH_TOKEN:-}" "GitHub token" "$tree" || return 1
  _scan_known_secret "${SLACK_WEBHOOK_URL:-}" "Slack webhook" "$tree" || return 1

  if ! command -v "${GITLEAKS:-gitleaks}" >/dev/null 2>&1; then
    echo "gitleaks is required for agentic runs (install with: brew install gitleaks)" >&2
    return 1
  fi
  _scan_candidate_additions "$tree"
}

assert_safe_file_modes() {
  local tree="$1" bad
  bad="$($GIT -C "$tree" diff --summary "$AGENT_BASE_SHA...HEAD" |
    awk '/ create mode 120000| create mode 160000| mode change .* => 120000| mode change .* => 160000/{print}')"
  [[ -z "$bad" ]] || {
    echo "safety guard: symlinks and submodules are not permitted" >&2
    return 1
  }
}

validate_agent_workspace() {
  local saved_repo="$REPO_PATH" saved_base="$BASE_BRANCH"
  REPO_PATH="$AGENT_WORKSPACE"
  BASE_BRANCH="$AGENT_BASE_SHA"
  if ! scope_guard ||
     ! assert_safe_file_modes "$AGENT_WORKSPACE" ||
     ! scan_workspace_secrets "$AGENT_WORKSPACE"; then
    REPO_PATH="$saved_repo"
    BASE_BRANCH="$saved_base"
    return 1
  fi
  REPO_PATH="$saved_repo"
  BASE_BRANCH="$saved_base"
}

_dependency_install_command() {
  local tree="$1"
  if [[ "${DEPENDENCY_CMD:-auto}" == "none" ]]; then
    return 0
  elif [[ "${DEPENDENCY_CMD:-auto}" != "auto" ]]; then
    printf '%s' "${DEPENDENCY_CMD:-}"
  elif [[ -f "$tree/pnpm-lock.yaml" ]]; then
    printf '%s' 'corepack pnpm install --frozen-lockfile --ignore-scripts'
  elif [[ -f "$tree/yarn.lock" ]]; then
    printf '%s' 'case "$(corepack yarn --version)" in 1.*) corepack yarn install --frozen-lockfile --ignore-scripts ;; *) corepack yarn install --immutable --mode=skip-build ;; esac'
  elif [[ -f "$tree/package-lock.json" || -f "$tree/npm-shrinkwrap.json" ]]; then
    printf '%s' 'npm ci --ignore-scripts'
  elif [[ -f "$tree/package.json" ]]; then
    echo "automatic dependency preparation requires a lockfile; set a trusted DEPENDENCY_CMD explicitly to override" >&2
    return 1
  fi
}

_isolated_container() {
  local tree="$1" network="$2" command="$3"
  [[ "${BUILD_ISOLATION:-docker}" == "docker" ]] || {
    echo "BUILD_ISOLATION must be 'docker'; host builds of agent-written code are refused" >&2
    return 1
  }
  command -v "${DOCKER:-docker}" >/dev/null 2>&1 || {
    echo "Docker/Colima is required for isolated builds" >&2
    return 1
  }
  env -u GH_TOKEN -u SLACK_WEBHOOK_URL "${DOCKER:-docker}" run --rm \
    --network "$network" \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges \
    --pids-limit 256 \
    --memory "${BUILD_MEMORY:-2g}" \
    --cpus "${BUILD_CPUS:-2}" \
    --tmpfs /tmp:rw,noexec,nosuid,size=256m \
    --user "$(id -u):$(id -g)" \
    -e HOME=/tmp \
    -v "$tree:/workspace:rw" \
    -v "$tree/.git:/workspace/.git:ro" \
    -w /workspace \
    "${BUILD_IMAGE:-node:22-bookworm}" \
    /bin/bash -lc "$command"
}

prepare_build_dependencies() {
  local tree="$1" command
  command="$(_dependency_install_command "$tree")" || return 1
  if [[ -z "$command" ]]; then
    log_skip "no package manifest detected — dependency preparation skipped"
    return 0
  fi
  log_info "preparing dependencies in the isolated build container"
  # The automatic commands refuse lifecycle scripts while network is enabled.
  # package manifests and lockfiles are excluded from agent edits by scope_guard.
  _isolated_container "$tree" bridge "$command"
}

run_isolated_build() {
  local tree="$1"
  [[ -z "${BUILD_CMD:-}" ]] && return 0
  _isolated_container "$tree" none "$BUILD_CMD"
}

cleanup_build_workspace() {
  local tree="$1"
  [[ -n "${AGENT_WORKSPACE:-}" && "$tree" == "$AGENT_WORKSPACE" ]] || {
    echo "refusing to clean an unrecognized build workspace" >&2
    return 1
  }
  local dirty=0
  $GIT -C "$tree" diff --quiet || dirty=1
  $GIT -C "$tree" diff --cached --quiet || dirty=1
  if [[ "$dirty" -eq 1 ]]; then
    echo "isolated build modified tracked files; discarding those side effects" >&2
    $GIT -C "$tree" reset --hard -q HEAD
  fi
  # Dependency directories and build output are untracked in this disposable,
  # tracked-only workspace. Remove them before another agent or final scan.
  $GIT -C "$tree" clean -fdx -q
  [[ "$dirty" -eq 0 ]]
}

run_isolated_build_cycle() {
  local tree="$1" rc=0
  prepare_build_dependencies "$tree" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    run_isolated_build "$tree" || rc=$?
  fi
  cleanup_build_workspace "$tree" || {
    [[ "$rc" -ne 0 ]] || rc=1
  }
  return "$rc"
}
