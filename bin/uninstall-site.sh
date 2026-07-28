#!/usr/bin/env bash
set -euo pipefail
: "${SEO_AUTOPILOT_HOME:="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"}"
LAUNCHCTL=${LAUNCHCTL:-launchctl}
LAUNCH_AGENTS_DIR="${LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}"
SLUG="${1:?usage: uninstall-site.sh <slug>}"
PLIST="$LAUNCH_AGENTS_DIR/com.seo-autopilot.$SLUG.plist"
"$LAUNCHCTL" unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"
echo "Unloaded + removed schedule for '$SLUG'. Profile/secrets kept in sites/."
