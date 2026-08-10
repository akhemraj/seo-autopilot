#!/usr/bin/env bash
set -euo pipefail

: "${SEO_AUTOPILOT_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"

_decode_quoted_value() {
  local input="$1" out="" i c escaped=0
  for (( i=0; i<${#input}; i++ )); do
    c="${input:$i:1}"
    if [[ "$escaped" -eq 1 ]]; then
      out+="$c"; escaped=0
    elif [[ "$c" == '\' ]]; then
      escaped=1
    else
      out+="$c"
    fi
  done
  [[ "$escaped" -eq 0 ]] || return 1
  printf '%s' "$out"
}

_load_assignments() {
  local file="$1" allowed="$2" line key raw value
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=\"(.*)\"$ ]]; then
      key="${BASH_REMATCH[1]}"; raw="${BASH_REMATCH[2]}"
      value="$(_decode_quoted_value "$raw")" || return 1
    elif [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=([0-9]+)$ ]]; then
      key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
    else
      echo "unsafe profile syntax in $file" >&2
      return 1
    fi
    [[ " $allowed " == *" $key "* ]] || {
      echo "unknown profile key '$key' in $file" >&2
      return 1
    }
    printf -v "$key" '%s' "$value"
  done < "$file"
}

load_profile() {
  local slug="$1"
  local conf="$SEO_AUTOPILOT_HOME/sites/${slug}.conf"
  local secrets="$SEO_AUTOPILOT_HOME/sites/${slug}.secrets"
  [[ -f "$conf" ]] || { echo "profile not found: $conf" >&2; return 1; }

  # Reset then parse strict KEY="value" assignments. Profiles are data, not
  # shell programs.
  DOMAIN=""; REPO_PATH=""; UBERSUGGEST_TARGET=""
  UBER_TOOLS=""; UBERSUGGEST_MCP_URL=""
  BASE_BRANCH=""; SCHEDULE_HOUR=""; SCHEDULE_WEEKDAY=""
  EDITABLE_GLOBS=""; EXCLUDE_GLOBS=""; MAX_FILES=""; MAX_NEW_PAGES=""
  MAX_DIFF_LINES=""; BUILD_CMD=""; PR_LABELS=""; PR_REVIEWERS=""; NOTES=""
  BUILD_ISOLATION=""; BUILD_IMAGE=""; BUILD_MEMORY=""; BUILD_CPUS=""
  DEPENDENCY_CMD=""
  SLACK_WEBHOOK_URL=""; GH_TOKEN=""
  _load_assignments "$conf" \
    "DOMAIN REPO_PATH UBERSUGGEST_TARGET UBER_TOOLS UBERSUGGEST_MCP_URL BASE_BRANCH SCHEDULE_HOUR SCHEDULE_WEEKDAY EDITABLE_GLOBS EXCLUDE_GLOBS MAX_FILES MAX_NEW_PAGES MAX_DIFF_LINES BUILD_CMD DEPENDENCY_CMD PR_LABELS PR_REVIEWERS NOTES BUILD_ISOLATION BUILD_IMAGE BUILD_MEMORY BUILD_CPUS" \
    || return 1
  if [[ -e "$secrets" ]]; then
    [[ -f "$secrets" && ! -L "$secrets" && -O "$secrets" ]] || {
      echo "secrets file must be a regular, user-owned, non-symlink file: $secrets" >&2
      return 1
    }
    local secret_mode
    secret_mode="$(stat -f '%Lp' "$secrets" 2>/dev/null || stat -c '%a' "$secrets")"
    [[ "$secret_mode" == "600" ]] || {
      echo "secrets file must have mode 600: $secrets" >&2
      return 1
    }
    _load_assignments "$secrets" "SLACK_WEBHOOK_URL GH_TOKEN" || return 1
  fi

  # Defaults
  BASE_BRANCH="${BASE_BRANCH:-main}"
  SCHEDULE_HOUR="${SCHEDULE_HOUR:-12}"
  SCHEDULE_WEEKDAY="${SCHEDULE_WEEKDAY:-1}"
  EDITABLE_GLOBS="${EDITABLE_GLOBS:-app/** components/** public/**}"
  EXCLUDE_GLOBS="${EXCLUDE_GLOBS:-node_modules/** **/node_modules/** .next/** **/.next/** *.lock **/*.lock *.env* **/*.env* *.secrets **/*.secrets next.config.* **/next.config.* package.json **/package.json package-lock.json **/package-lock.json npm-shrinkwrap.json **/npm-shrinkwrap.json pnpm-lock.yaml **/pnpm-lock.yaml yarn.lock **/yarn.lock bun.lock* **/bun.lock*}"
  MAX_FILES="${MAX_FILES:-12}"
  MAX_NEW_PAGES="${MAX_NEW_PAGES:-2}"
  MAX_DIFF_LINES="${MAX_DIFF_LINES:-1500}"
  BUILD_CMD="${BUILD_CMD:-yarn build}"
  PR_LABELS="${PR_LABELS:-seo,automated}"
  PR_REVIEWERS="${PR_REVIEWERS:-}"
  NOTES="${NOTES:-}"
  BUILD_ISOLATION="${BUILD_ISOLATION:-docker}"
  BUILD_IMAGE="${BUILD_IMAGE:-node:22-bookworm}"
  BUILD_MEMORY="${BUILD_MEMORY:-2g}"
  BUILD_CPUS="${BUILD_CPUS:-2}"
  DEPENDENCY_CMD="${DEPENDENCY_CMD:-auto}"
  UBER_TOOLS="${UBER_TOOLS:-mcp__ubersuggest__*}"
  UBERSUGGEST_MCP_URL="${UBERSUGGEST_MCP_URL:-https://ubersuggest-mcp.neilpatelapi.com/mcp}"

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
  [[ "$MAX_FILES" =~ ^[0-9]+$ && "$MAX_NEW_PAGES" =~ ^[0-9]+$ && "$MAX_DIFF_LINES" =~ ^[0-9]+$ ]] || {
    echo "profile '$slug': MAX_FILES, MAX_NEW_PAGES, and MAX_DIFF_LINES must be non-negative integers" >&2
    return 1
  }
  [[ "$BUILD_ISOLATION" == "docker" ]] || {
    echo "profile '$slug': BUILD_ISOLATION must be docker" >&2
    return 1
  }

  export DOMAIN BASE_BRANCH REPO_PATH UBERSUGGEST_TARGET SCHEDULE_HOUR \
    SCHEDULE_WEEKDAY EDITABLE_GLOBS EXCLUDE_GLOBS MAX_FILES MAX_NEW_PAGES \
    MAX_DIFF_LINES BUILD_CMD PR_LABELS PR_REVIEWERS NOTES BUILD_ISOLATION \
    BUILD_IMAGE BUILD_MEMORY BUILD_CPUS DEPENDENCY_CMD UBER_TOOLS UBERSUGGEST_MCP_URL \
    SLACK_WEBHOOK_URL GH_TOKEN
}
