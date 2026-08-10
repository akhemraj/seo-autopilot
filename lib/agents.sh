#!/usr/bin/env bash
set -euo pipefail

AGENT_CATEGORIES=(meta schema a11y content)

init_agent_audit() {
  AGENT_AUDIT="$SEO_AUTOPILOT_HOME/logs/$SLUG/$SEO_RUN_DATE.agents.json"
  mkdir -p "$(dirname "$AGENT_AUDIT")"
  jq -n \
    --arg slug "$SLUG" \
    --arg domain "$DOMAIN" \
    --arg run_date "$SEO_RUN_DATE" \
    '{
      schema_version: 1,
      slug: $slug,
      domain: $domain,
      run_date: $run_date,
      agents: {},
      summary: {
        findings: 0,
        tasks: 0,
        deferred: 0,
        tasks_by_category: {meta:0,schema:0,a11y:0,content:0}
      }
    }' > "$AGENT_AUDIT" || return 1
  chmod 600 "$AGENT_AUDIT"
  export AGENT_AUDIT
  log_info "agent audit: $AGENT_AUDIT"
}

_audit_output_is_safe() {
  local file="$1" secret
  for secret in "${GH_TOKEN:-}" "${SLACK_WEBHOOK_URL:-}"; do
    [[ -z "$secret" ]] && continue
    if printf '%s\n' "$secret" | grep -F -q -f - "$file"; then
      return 1
    fi
  done
  command -v "${GITLEAKS:-gitleaks}" >/dev/null 2>&1 || return 1
  "${GITLEAKS:-gitleaks}" stdin --no-banner --redact < "$file" >/dev/null
}

_audit_set_agent() {
  local role="$1" file="$2" tmp
  [[ -n "${AGENT_AUDIT:-}" && -f "$AGENT_AUDIT" && -f "$file" ]] || return 0
  tmp="$(mktemp "$(dirname "$AGENT_AUDIT")/.agents.XXXXXX")"
  if _audit_output_is_safe "$file"; then
    jq --arg role "$role" --slurpfile value "$file" \
      '.agents[$role] = $value[0]' "$AGENT_AUDIT" > "$tmp" || {
        rm -f "$tmp"; return 1;
      }
  else
    jq --arg role "$role" \
      '.agents[$role] = {redacted:true, reason:"secret-like content omitted"}' \
      "$AGENT_AUDIT" > "$tmp" || {
        rm -f "$tmp"; return 1;
      }
    log_warn "$role audit output omitted because it matched a secret detector"
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$AGENT_AUDIT"
}

_audit_set_summary() {
  local findings="$1" tasks="$2" deferred="$3" tmp
  tmp="$(mktemp "$(dirname "$AGENT_AUDIT")/.agents.XXXXXX")"
  jq \
    --argjson findings "$findings" \
    --argjson tasks "$tasks" \
    --argjson deferred "$deferred" \
    --slurpfile plan "$AGENT_OUTPUTS/plan.json" \
    '.summary.findings = $findings |
     .summary.tasks = $tasks |
     .summary.deferred = $deferred |
     .summary.tasks_by_category = {
       meta: ([$plan[0].tasks[] | select(.category=="meta")] | length),
       schema: ([$plan[0].tasks[] | select(.category=="schema")] | length),
       a11y: ([$plan[0].tasks[] | select(.category=="a11y")] | length),
       content: ([$plan[0].tasks[] | select(.category=="content")] | length)
     }' "$AGENT_AUDIT" > "$tmp" || {
       rm -f "$tmp"; return 1;
     }
  chmod 600 "$tmp"
  mv -f "$tmp" "$AGENT_AUDIT"
}

_write_agent_runtime_config() {
  local settings="$AGENT_RUN_DIR/settings.json"
  local mcp="$AGENT_RUN_DIR/mcp.json"
  jq -n --arg real "$REPO_PATH" \
    --arg home "$SEO_AUTOPILOT_HOME" '{
    permissions: {
      # In Claude Code permission rules, one leading slash is relative to the
      # project root and two leading slashes mean filesystem-absolute. Agents
      # start in the isolated workspace, so these rules grant access only there.
      allow: ["Read(/**)", "Edit(/**)"],
      deny: [
        "Read(//**/.env)", "Read(//**/.env.*)", "Read(//**/*.secrets)",
        "Read(//**/.git/**)", "Edit(//**/.git/**)",
        "Read(//**/.ssh/**)", "Read(//**/.aws/**)",
        "Read(//**/.npmrc)", "Read(//**/.netrc)",
        "Read(//**/.docker/**)", "Read(//**/.kube/**)",
        "Read(//**/.azure/**)", "Read(//**/.config/gh/**)",
        "Read(//**/.config/gcloud/**)", "Read(//**/*history)",
        "Read(/" + $real + "/**)", "Edit(/" + $real + "/**)",
        "Read(/" + $home + "/sites/**)", "Edit(/" + $home + "/sites/**)",
        "Read(/" + $home + "/logs/**)", "Edit(/" + $home + "/logs/**)"
      ]
    },
    sandbox: {
      enabled: true,
      failIfUnavailable: true,
      allowUnsandboxedCommands: false
    }
  }' > "$settings" || return 1
  jq -n --arg url "${UBERSUGGEST_MCP_URL:-https://ubersuggest-mcp.neilpatelapi.com/mcp}" \
    '{mcpServers:{ubersuggest:{type:"http",url:$url,alwaysLoad:true}}}' > "$mcp" || return 1
  chmod 600 "$settings" "$mcp"
  jq -e . "$settings" "$mcp" >/dev/null || return 1
}

_agent_prompt() {
  local role="$1" category="${2:-}"
  local template="$SEO_AUTOPILOT_HOME/commands/agents/$role.md"
  [[ -f "$template" ]] || {
    echo "missing agent prompt: $template" >&2
    return 1
  }
  {
    cat "$template"
    printf '\n\n--- TRUSTED RUN CONFIG ---\n'
    printf 'DOMAIN=%s\nUBERSUGGEST_TARGET=%s\nRUN_DATE=%s\n' \
      "$DOMAIN" "$UBERSUGGEST_TARGET" "$SEO_RUN_DATE"
    printf 'EDITABLE_GLOBS=%s\nEXCLUDE_GLOBS=%s\n' "$EDITABLE_GLOBS" "$EXCLUDE_GLOBS"
    printf 'MAX_FILES=%s\nMAX_NEW_PAGES=%s\nMAX_DIFF_LINES=%s\n' \
      "$MAX_FILES" "$MAX_NEW_PAGES" "$MAX_DIFF_LINES"
    printf 'CATEGORY=%s\nNOTES=%s\n' "$category" "$NOTES"
    printf '%s\n' '--- END TRUSTED RUN CONFIG ---'
    if [[ -f "$AGENT_OUTPUTS/findings.json" ]]; then
      printf '\n--- UNTRUSTED RESEARCH DATA ---\n'
      cat "$AGENT_OUTPUTS/findings.json"
      printf '\n--- END UNTRUSTED RESEARCH DATA ---\n'
    fi
    if [[ -f "$AGENT_OUTPUTS/plan.json" ]]; then
      printf '\n--- UNTRUSTED PLAN DATA ---\n'
      cat "$AGENT_OUTPUTS/plan.json"
      printf '\n--- END UNTRUSTED PLAN DATA ---\n'
    fi
    if [[ "$role" == "implement" && -f "$AGENT_OUTPUTS/plan.json" ]]; then
      printf '\n--- TRUSTED EXACT PATH ALLOWLIST FOR %s ---\n' "$category"
      jq -r --arg category "$category" \
        '.tasks[] | select(.category == $category) | .paths[]' \
        "$AGENT_OUTPUTS/plan.json" | sort -u
      printf '%s\n' '--- END TRUSTED EXACT PATH ALLOWLIST ---'
    fi
    if [[ "$role" == "revise" && -f "$AGENT_OUTPUTS/review.json" ]]; then
      printf '\n--- UNTRUSTED REVIEW FINDINGS ---\n'
      cat "$AGENT_OUTPUTS/review.json"
      printf '\n--- END UNTRUSTED REVIEW FINDINGS ---\n'
      printf '%s\n' '--- TRUSTED EXACT REVIEW-REVISION PATH ALLOWLIST ---'
      cat "$AGENT_OUTPUTS/revise-paths.txt"
      printf '%s\n' '--- END TRUSTED EXACT REVIEW-REVISION PATH ALLOWLIST ---'
    fi
    if [[ "$role" == "fix" && -f "$AGENT_OUTPUTS/build.log" ]]; then
      printf '\n--- UNTRUSTED BUILD OUTPUT (LAST 200 LINES) ---\n'
      tail -200 "$AGENT_OUTPUTS/build.log"
      printf '\n--- END UNTRUSTED BUILD OUTPUT ---\n'
    fi
    if [[ "$role" == "report" || "$role" == "review" || "$role" == "revise" ]]; then
      printf '\n--- UNTRUSTED CANDIDATE DIFF ---\n'
      $GIT -C "$AGENT_WORKSPACE" --no-pager diff --no-ext-diff \
        "${AGENT_BASE_SHA}...HEAD"
      printf '\n--- END UNTRUSTED CANDIDATE DIFF ---\n'
    fi
  }
}

_agent_raw_is_transient_error() {
  local raw="$1"
  [[ -s "$raw" ]] || return 1
  jq -e '
    (.is_error == true or .terminal_reason == "api_error") and
    (
      ((.api_error_status // 0) as $status |
        ([429, 500, 502, 503, 504, 529] | index($status)) != null) or
      ((.result // "") | test(
        "overload|rate.?limit|temporar|try again|service unavailable|gateway timeout";
        "i"
      ))
    )
  ' "$raw" >/dev/null 2>&1
}

_invoke_agent() {
  local role="$1" tools="$2" output="$3" category="${4:-}"
  local prompt="$AGENT_RUN_DIR/$role${category:+-$category}.prompt"
  local raw="$AGENT_RUN_DIR/$role${category:+-$category}.raw"
  local schema="$SEO_AUTOPILOT_HOME/commands/agents/schemas/$role.json"
  local attempt rc status max_attempts=3
  _agent_prompt "$role" "$category" > "$prompt" || return 1
  chmod 600 "$prompt"

  local args=(
    -p
    --setting-sources ""
    --disable-slash-commands
    --no-session-persistence
    --name "seo-$role${category:+-$category}"
    --permission-mode dontAsk
    --settings "$AGENT_RUN_DIR/settings.json"
    --tools "$tools"
    --disallowedTools "Bash,Skill,WebFetch,WebSearch,NotebookEdit"
    --output-format json
  )
  # Safe mode disables all MCP servers, including the explicit strict config.
  # The research agent instead uses empty filesystem setting sources, no
  # built-in tools, disabled slash commands, and the single strict MCP config.
  [[ "$role" == "research" ]] || args+=(--safe-mode)
  [[ -f "$schema" ]] || {
    echo "missing agent output schema: $schema" >&2
    return 1
  }
  args+=(--json-schema "$(jq -c . "$schema")")
  if [[ "$role" == "research" ]]; then
    args+=(--mcp-config "$AGENT_RUN_DIR/mcp.json" --strict-mcp-config
      --allowedTools "${UBER_TOOLS:-mcp__ubersuggest__*}")
  else
    args+=(--mcp-config '{"mcpServers":{}}' --strict-mcp-config)
  fi

  for (( attempt=1; attempt<=max_attempts; attempt++ )); do
    rc=0
    (
      cd "$AGENT_WORKSPACE"
      env -u GH_TOKEN -u SLACK_WEBHOOK_URL \
        CLAUDE_CODE_DISABLE_AUTO_MEMORY=1 \
        "$CLAUDE" "${args[@]}" < "$prompt" > "$raw"
    ) || rc=$?

    if _agent_raw_is_transient_error "$raw"; then
      status="$(jq -r '.api_error_status // "unknown"' "$raw" 2>/dev/null || echo unknown)"
      if [[ "$attempt" -lt "$max_attempts" ]]; then
        log_warn "$role${category:+/$category} agent received transient API error $status; retrying ($attempt/$max_attempts)"
        "${SLEEP:-sleep}" "$(( attempt * 5 ))"
        continue
      fi
      log_err "$role${category:+/$category} agent failed after $max_attempts attempts (transient API error $status)"
      return 1
    fi

    if [[ "$rc" -ne 0 ]]; then
      log_err "$role${category:+/$category} agent process failed (rc=$rc)"
      return "$rc"
    fi
    if ! jq -e . "$raw" >/dev/null 2>&1; then
      log_err "$role${category:+/$category} agent returned invalid JSON"
      return 1
    fi
    if jq -e '.is_error == true or .terminal_reason == "api_error"' \
      "$raw" >/dev/null 2>&1; then
      status="$(jq -r '.api_error_status // "unknown"' "$raw")"
      log_err "$role${category:+/$category} agent returned API error $status"
      return 1
    fi
    break
  done

  jq -e '
    if has("structured_output") then .structured_output
    elif (.result? | type) == "string" then
      (.result as $result |
        try ($result | fromjson) catch {summary:$result})
    else . end
  ' "$raw" > "$output" || return 1
  chmod 600 "$output"
}

run_research_agent() {
  _invoke_agent research "" "$AGENT_OUTPUTS/findings.json" || return 1
  jq -e '.findings | type == "array"' "$AGENT_OUTPUTS/findings.json" >/dev/null \
    || return 1
  jq -e '.tools_used | type == "array" and
    any(.[]; startswith("mcp__ubersuggest__"))' \
    "$AGENT_OUTPUTS/findings.json" >/dev/null || {
      echo "research agent did not report any Ubersuggest tool usage" >&2
      return 1
    }
  _audit_set_agent research "$AGENT_OUTPUTS/findings.json" || return 1
  local findings tools
  findings="$(jq '.findings | length' "$AGENT_OUTPUTS/findings.json")"
  tools="$(jq -r '.tools_used | join(", ")' "$AGENT_OUTPUTS/findings.json")"
  log_info "research: $findings finding(s) · tools: $tools"
}

run_planning_agent() {
  _invoke_agent plan "Read,Grep,Glob" "$AGENT_OUTPUTS/plan.json" || return 1
  jq -e '.tasks | type == "array"' "$AGENT_OUTPUTS/plan.json" >/dev/null \
    || return 1
  _audit_set_agent plan "$AGENT_OUTPUTS/plan.json" || return 1
  local findings tasks deferred meta schema a11y content
  findings="$(jq '.findings | length' "$AGENT_OUTPUTS/findings.json")"
  tasks="$(jq '.tasks | length' "$AGENT_OUTPUTS/plan.json")"
  deferred="$(jq '(.deferred // []) | length' "$AGENT_OUTPUTS/plan.json")"
  meta="$(jq '[.tasks[] | select(.category=="meta")] | length' "$AGENT_OUTPUTS/plan.json")"
  schema="$(jq '[.tasks[] | select(.category=="schema")] | length' "$AGENT_OUTPUTS/plan.json")"
  a11y="$(jq '[.tasks[] | select(.category=="a11y")] | length' "$AGENT_OUTPUTS/plan.json")"
  content="$(jq '[.tasks[] | select(.category=="content")] | length' "$AGENT_OUTPUTS/plan.json")"
  _audit_set_summary "$findings" "$tasks" "$deferred" || return 1
  log_info "plan: $tasks task(s) · meta $meta · schema $schema · a11y $a11y · content $content · deferred $deferred"
}

run_category_agents() {
  local category before
  for category in "${AGENT_CATEGORIES[@]}"; do
    log_info "agent: $category specialist"
    before="$($GIT -C "$AGENT_WORKSPACE" rev-parse HEAD)"
    if ! _invoke_agent implement "Read,Grep,Glob,Edit,Write" \
      "$AGENT_OUTPUTS/$category.json" "$category"; then
      $GIT -C "$AGENT_WORKSPACE" reset --hard -q "$before"
      echo "$category agent failed; refusing a partial implementation" >&2
      return 1
    fi
    _audit_set_agent "$category" "$AGENT_OUTPUTS/$category.json" || return 1
    jq -e --arg category "$category" '
      .category == $category and
      (.changed | type == "array") and
      (.skipped | type == "array") and
      (.blocked | type == "array")
    ' "$AGENT_OUTPUTS/$category.json" >/dev/null || {
      echo "$category agent returned an invalid implementation status" >&2
      $GIT -C "$AGENT_WORKSPACE" reset --hard -q "$before"
      return 1
    }
    if [[ "$(jq '.blocked | length' "$AGENT_OUTPUTS/$category.json")" -gt 0 ]]; then
      echo "$category agent was blocked; refusing to report a partial success" >&2
      $GIT -C "$AGENT_WORKSPACE" reset --hard -q "$before"
      return 1
    fi
    if agent_workspace_has_changes; then
      local changed planned f
      local unplanned=()
      changed="$($GIT -C "$AGENT_WORKSPACE" status --porcelain --untracked-files=all | sed 's/^...//')"
      planned="$(jq -r --arg category "$category" \
        '.tasks[] | select(.category == $category) | .paths[]' \
        "$AGENT_OUTPUTS/plan.json")"
      while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        printf '%s\n' "$planned" | grep -Fqx -- "$f" ||
          unplanned+=("$f")
      done <<< "$changed"
      if [[ "${#unplanned[@]}" -gt 0 ]]; then
        log_err "$category agent changed ${#unplanned[@]} unplanned path(s): ${unplanned[*]}"
        log_err "planner must explicitly authorize every companion path"
        return 1
      fi
      validate_agent_workspace || return 1
      commit_agent_changes "$category" || return 1
      log_info "$category: $(printf '%s\n' "$changed" | grep -c . || true) changed file(s) accepted"
    else
      log_skip "$category agent made no changes"
    fi
  done
}

run_report_agent() {
  _invoke_agent report "Read,Grep,Glob,Edit,Write" "$AGENT_OUTPUTS/report.json" || return 1
  _audit_set_agent report "$AGENT_OUTPUTS/report.json" || return 1
  if agent_workspace_has_changes; then
    local changed expected="tasks/seo/reports/$SEO_RUN_DATE.md"
    changed="$($GIT -C "$AGENT_WORKSPACE" status --porcelain --untracked-files=all | sed 's/^...//')"
    [[ "$changed" == "$expected" ]] || {
      echo "report agent may write only $expected" >&2
      return 1
    }
    validate_agent_workspace || return 1
    $GIT -C "$AGENT_WORKSPACE" add -A
    $GIT -C "$AGENT_WORKSPACE" -c core.hooksPath=/dev/null \
      commit -q -m "seo(report): $SEO_RUN_DATE findings and changes"
  fi
}

run_review_agent() {
  _invoke_agent review "Read,Grep,Glob" "$AGENT_OUTPUTS/review.json" || return 1
  _audit_set_agent review "$AGENT_OUTPUTS/review.json" || return 1
  jq -e '.approved == true' "$AGENT_OUTPUTS/review.json" >/dev/null || {
    echo "review agent rejected the candidate changes" >&2
    return 1
  }
}

run_review_revision_agent() {
  local paths_file="$AGENT_OUTPUTS/revise-paths.txt"
  local candidate_paths changed path
  local unapproved=()

  jq -r '
    (.findings // [])[] |
    select(.severity == "critical" or .severity == "high") |
    .path
  ' "$AGENT_OUTPUTS/review.json" | sort -u > "$paths_file"
  [[ -s "$paths_file" ]] || {
    echo "review rejected the candidate without an actionable critical/high path" >&2
    return 1
  }

  candidate_paths="$($GIT -C "$AGENT_WORKSPACE" diff --name-only \
    "${AGENT_BASE_SHA}...HEAD")"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    printf '%s\n' "$candidate_paths" | grep -Fqx -- "$path" ||
      unapproved+=("$path")
  done < "$paths_file"
  if [[ "${#unapproved[@]}" -gt 0 ]]; then
    echo "review revision requested paths outside the candidate diff: ${unapproved[*]}" >&2
    return 1
  fi

  _invoke_agent revise "Read,Grep,Glob,Edit,Write" \
    "$AGENT_OUTPUTS/revise.json" || return 1
  _audit_set_agent revise "$AGENT_OUTPUTS/revise.json" || return 1
  jq -e '
    (.changed | type == "array") and
    (.skipped | type == "array") and
    (.blocked | type == "array")
  ' "$AGENT_OUTPUTS/revise.json" >/dev/null || {
    echo "review revision agent returned an invalid status" >&2
    return 1
  }
  [[ "$(jq '.blocked | length' "$AGENT_OUTPUTS/revise.json")" -eq 0 ]] || {
    echo "review revision agent was blocked" >&2
    return 1
  }
  agent_workspace_has_changes || {
    echo "review revision agent made no changes" >&2
    return 1
  }

  changed="$($GIT -C "$AGENT_WORKSPACE" status --porcelain \
    --untracked-files=all | sed 's/^...//')"
  while IFS= read -r path; do
    [[ -n "$path" ]] || continue
    grep -Fqx -- "$path" "$paths_file" || {
      echo "review revision agent changed an unauthorized path: $path" >&2
      return 1
    }
  done <<< "$changed"

  validate_agent_workspace || return 1
  commit_agent_changes review-fix || return 1
  log_info "review revision: $(printf '%s\n' "$changed" | grep -c . || true) changed file(s) accepted"
}

ensure_review_approved() {
  if run_review_agent; then
    return 0
  fi
  [[ "${REVIEW_REVISION_USED:-0}" -eq 0 ]] || return 1

  REVIEW_REVISION_USED=1
  cp "$AGENT_OUTPUTS/review.json" "$AGENT_OUTPUTS/review-initial.json"
  _audit_set_agent review_initial "$AGENT_OUTPUTS/review-initial.json" || return 1
  log_warn "review rejected candidate — attempting one path-locked revision pass"
  run_review_revision_agent || return 1

  # The report was written before review. Refresh it so the final artifact
  # describes the revised candidate rather than the rejected version.
  run_report_agent || return 1
  run_review_agent
}

run_fix_agent() {
  local build_log="$1"
  cp "$build_log" "$AGENT_OUTPUTS/build.log"
  _invoke_agent fix "Read,Grep,Glob,Edit,Write" "$AGENT_OUTPUTS/fix.json" || return 1
  _audit_set_agent fix "$AGENT_OUTPUTS/fix.json"
}

run_agentic_workflow() {
  _write_agent_runtime_config || return 1
  init_agent_audit || return 1
  log_info "agent: Ubersuggest researcher (MCP only)"
  run_research_agent || return 1
  log_info "agent: read-only planner"
  run_planning_agent || return 1
  if [[ "$(jq '.tasks | length' "$AGENT_OUTPUTS/plan.json")" -eq 0 ]]; then
    log_skip "planner produced no actionable tasks; specialists skipped"
    return 0
  fi
  run_category_agents || return 1
  if [[ "$($GIT -C "$AGENT_WORKSPACE" rev-list --count "${AGENT_BASE_SHA}..HEAD")" -eq 0 ]]; then
    echo "planner produced actionable tasks, but specialists produced no source changes" >&2
    return 1
  fi
  log_info "agent: report writer"
  run_report_agent || return 1
  log_info "agent: read-only reviewer"
  ensure_review_approved || return 1
}
