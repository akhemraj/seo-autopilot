#!/usr/bin/env bash
set -euo pipefail

: "${SEO_AUTOPILOT_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

load_profile() {
  local slug="$1"
  local conf="$SEO_AUTOPILOT_HOME/sites/${slug}.conf"
  local secrets="$SEO_AUTOPILOT_HOME/sites/${slug}.secrets"
  [[ -f "$conf" ]] || { echo "profile not found: $conf" >&2; return 1; }

  # Reset then source (conf is trusted, user-authored KEY="value")
  DOMAIN=""; REPO_PATH=""; UBERSUGGEST_TARGET=""
  BASE_BRANCH=""; SCHEDULE_HOUR=""; SCHEDULE_WEEKDAY=""
  EDITABLE_GLOBS=""; EXCLUDE_GLOBS=""; MAX_FILES=""; MAX_NEW_PAGES=""
  MAX_DIFF_LINES=""; BUILD_CMD=""; PR_LABELS=""; PR_REVIEWERS=""; NOTES=""
  SLACK_WEBHOOK_URL=""; GH_TOKEN=""
  # shellcheck disable=SC1090
  source "$conf"
  # shellcheck disable=SC1090
  [[ -f "$secrets" ]] && source "$secrets"

  # Defaults
  BASE_BRANCH="${BASE_BRANCH:-main}"
  SCHEDULE_HOUR="${SCHEDULE_HOUR:-12}"
  SCHEDULE_WEEKDAY="${SCHEDULE_WEEKDAY:-1}"
  EDITABLE_GLOBS="${EDITABLE_GLOBS:-app/** components/** public/**}"
  EXCLUDE_GLOBS="${EXCLUDE_GLOBS:-node_modules/** .next/** *.lock *.env* next.config.* package.json}"
  MAX_FILES="${MAX_FILES:-12}"
  MAX_NEW_PAGES="${MAX_NEW_PAGES:-2}"
  MAX_DIFF_LINES="${MAX_DIFF_LINES:-1500}"
  BUILD_CMD="${BUILD_CMD:-yarn build}"
  PR_LABELS="${PR_LABELS:-seo,automated}"
  PR_REVIEWERS="${PR_REVIEWERS:-}"
  NOTES="${NOTES:-}"

  # Validate required
  local missing=()
  [[ -n "$DOMAIN" ]] || missing+=("DOMAIN")
  [[ -n "$REPO_PATH" ]] || missing+=("REPO_PATH")
  [[ -n "$UBERSUGGEST_TARGET" ]] || missing+=("UBERSUGGEST_TARGET")
  if [[ ${#missing[@]} -gt 0 ]]; then
    echo "profile '$slug' missing required: ${missing[*]}" >&2; return 1
  fi
  if [[ ! -d "$REPO_PATH/.git" ]]; then
    echo "profile '$slug': REPO_PATH is not a git repo: $REPO_PATH" >&2; return 1
  fi

  export DOMAIN BASE_BRANCH REPO_PATH UBERSUGGEST_TARGET SCHEDULE_HOUR \
    SCHEDULE_WEEKDAY EDITABLE_GLOBS EXCLUDE_GLOBS MAX_FILES MAX_NEW_PAGES \
    MAX_DIFF_LINES BUILD_CMD PR_LABELS PR_REVIEWERS NOTES SLACK_WEBHOOK_URL GH_TOKEN
}
