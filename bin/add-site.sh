#!/usr/bin/env bash
set -euo pipefail
: "${SEO_AUTOPILOT_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
LAUNCHCTL=${LAUNCHCTL:-launchctl}
GIT=${GIT:-git}
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"

SLUG="${1:?usage: add-site.sh <slug>}"

ask() { local var="$1" prompt="$2" def="${3:-}"; local cur="${!var:-}"
  if [[ -n "$cur" ]]; then printf '%s' "$cur"; return; fi
  read -r -p "$prompt${def:+ [$def]}: " val; printf '%s' "${val:-$def}"; }

DOMAIN="$(ask AS_DOMAIN "Domain (e.g. example.com)")"
REPO_PATH="$(ask AS_REPO_PATH "Absolute repo path" "$HOME/seo-autopilot-repos/$SLUG")"
UBERSUGGEST_TARGET="$(ask AS_UBERSUGGEST_TARGET "Ubersuggest target domain" "$DOMAIN")"
SCHEDULE_HOUR="$(ask AS_SCHEDULE_HOUR "Schedule hour (0-23)" 12)"
SCHEDULE_WEEKDAY="$(ask AS_SCHEDULE_WEEKDAY "Schedule weekday (0=Sun..6=Sat)" 1)"
EXCLUDE_GLOBS="$(ask AS_EXCLUDE_GLOBS "Exclude globs" "node_modules/** .next/** *.lock *.env* next.config.* package.json")"
MAX_FILES="$(ask AS_MAX_FILES "Max files per run" 12)"
NOTES="$(ask AS_NOTES "Notes for the SEO worker" "")"

# Reuse an existing clone, or bootstrap a fresh setup by cloning into an absent
# (or empty) target directory. Authentication is deliberately left to the user's
# normal SSH key / Git credential configuration; credentials never enter the URL.
REPO_URL="${AS_REPO_URL:-}"
if [[ -d "$REPO_PATH/.git" ]]; then
  if [[ -n "$REPO_URL" ]]; then
    origin="$("$GIT" -C "$REPO_PATH" remote get-url origin 2>/dev/null || true)"
    _repo_identity() {
      local u="${1%/}"
      u="${u%.git}"
      u="${u#ssh://git@}"; u="${u#git@}"
      u="${u#https://}"; u="${u#http://}"
      u="${u/:/\/}"
      printf '%s' "$u"
    }
    [[ "$(_repo_identity "$origin")" == "$(_repo_identity "$REPO_URL")" ]] || {
      echo "REPO_PATH already contains a different origin: $origin" >&2
      exit 1
    }
  fi
else
  if [[ -e "$REPO_PATH" && ! -d "$REPO_PATH" ]]; then
    echo "REPO_PATH exists and is not a directory: $REPO_PATH" >&2
    exit 1
  fi
  if [[ -d "$REPO_PATH" && -n "$(find "$REPO_PATH" -mindepth 1 -maxdepth 1 -print -quit)" ]]; then
    echo "REPO_PATH exists, is non-empty, and is not a git repo: $REPO_PATH" >&2
    exit 1
  fi
  REPO_URL="$(ask AS_REPO_URL "Git repository URL to clone")"
  [[ -n "$REPO_URL" ]] || { echo "Git repository URL is required for a fresh setup" >&2; exit 1; }
  mkdir -p "$(dirname "$REPO_PATH")"
  echo "Cloning $REPO_URL into $REPO_PATH..."
  "$GIT" clone -- "$REPO_URL" "$REPO_PATH"
fi

[[ -d "$REPO_PATH/.git" ]] || { echo "clone did not create a git repo: $REPO_PATH" >&2; exit 1; }

# Bake a PATH covering the tools the scheduled (launchd) run needs — launchd starts
# with a minimal PATH, so resolve claude/node/yarn/jq/git/curl locations now.
_bindirs() {
  local b p out="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
  for b in claude node yarn jq git curl; do
    p="$(command -v "$b" 2>/dev/null || true)"
    if [[ -n "$p" ]]; then
      out="$out:$(cd "$(dirname "$p")" && pwd)"
    elif [[ "$b" == "claude" ]]; then
      echo "warning: 'claude' not found on PATH; the scheduled run may fail to locate it" >&2
    fi
  done
  printf '%s' "$out" | tr ':' '\n' | awk 'NF && !seen[$0]++' | paste -sd: -
}
RUN_PATH="$(_bindirs)"

# Escape a value for safe embedding inside a double-quoted shell assignment (KEY="...")
_shq() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//\$/\\\$}"; s="${s//\`/\\\`}"; printf '%s' "$s"; }

render() { # template_file  -> stdout
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//__DOMAIN__/$DOMAIN}"
    line="${line//__REPO_PATH__/$REPO_PATH}"
    line="${line//__UBERSUGGEST_TARGET__/$UBERSUGGEST_TARGET}"
    line="${line//__SCHEDULE_HOUR__/$SCHEDULE_HOUR}"
    line="${line//__SCHEDULE_WEEKDAY__/$SCHEDULE_WEEKDAY}"
    line="${line//__EXCLUDE_GLOBS__/$EXCLUDE_GLOBS}"
    line="${line//__MAX_FILES__/$MAX_FILES}"
    line="${line//__NOTES__/$NOTES}"
    line="${line//__SLUG__/$SLUG}"
    line="${line//__HOME__/$SEO_AUTOPILOT_HOME}"
    line="${line//__PATH__/$RUN_PATH}"
    printf '%s\n' "$line"
  done < "$1"
}

# NOTES and EXCLUDE_GLOBS land inside KEY="..." shell assignments in the .conf;
# escape backslash/"/`/$ so a literal special char in free-text input can't break
# that quoting. They never reach the plist, so this is safe to do before rendering.
NOTES="$(_shq "$NOTES")"
EXCLUDE_GLOBS="$(_shq "$EXCLUDE_GLOBS")"

render "$SEO_AUTOPILOT_HOME/templates/profile.template" > "$SEO_AUTOPILOT_HOME/sites/$SLUG.conf"
if [[ ! -f "$SEO_AUTOPILOT_HOME/sites/$SLUG.secrets" ]]; then
  cp "$SEO_AUTOPILOT_HOME/templates/secrets.template" "$SEO_AUTOPILOT_HOME/sites/$SLUG.secrets"
  chmod 600 "$SEO_AUTOPILOT_HOME/sites/$SLUG.secrets"
fi
mkdir -p "$SEO_AUTOPILOT_HOME/logs/$SLUG"
PLIST="$LAUNCH_AGENTS_DIR/com.seo-autopilot.$SLUG.plist"
mkdir -p "$LAUNCH_AGENTS_DIR"
render "$SEO_AUTOPILOT_HOME/templates/plist.template" > "$PLIST"
"$LAUNCHCTL" unload "$PLIST" 2>/dev/null || true
"$LAUNCHCTL" load "$PLIST"

echo "Site '$SLUG' added. Now edit sites/$SLUG.secrets with SLACK_WEBHOOK_URL + GH_TOKEN,"
echo "then validate with: bin/run.sh $SLUG --dry-run"
