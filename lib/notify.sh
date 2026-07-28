#!/usr/bin/env bash
set -euo pipefail
CURL=${CURL:-curl}

# JSON-escape a string for the "text" field
_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//$'\n'/\\n}"; s="${s//$'\t'/\\t}"
  printf '%s' "$s"
}

slack_send() { # text
  local text="$1"
  if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
    log_info "SLACK_WEBHOOK_URL empty — skipping Slack notification"
    return 0
  fi
  local payload
  payload="{\"text\":\"$(_json_escape "$text")\"}"
  # Webhook URL via stdin config (never argv → ps-safe). Message payload is not secret.
  printf 'url = "%s"\n' "$SLACK_WEBHOOK_URL" \
    | "$CURL" --fail-with-body -sS --config - -X POST -H 'Content-type: application/json' --data "$payload" >/dev/null
}

slack_success() { # site pr_url summary
  slack_send "✅ *SEO Autopilot — $1*
PR: $2
$3"
}

slack_failure() { # site logfile reason
  slack_send "❌ *SEO Autopilot — $1* failed
Reason: $3
Log: $2"
}
