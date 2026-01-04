#!/usr/bin/env bash
# context.sh - Collect all context into JSON for the decision agent
#
# Usage:
#   source context.sh
#   collect_context "$TASK" "$MAIN_REPO" "$EXEC_REPO"

set -euo pipefail

# JSON escape helper
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"     # Backslash
  s="${s//\"/\\\"}"     # Quote
  s="${s//$'\n'/\\n}"   # Newline
  s="${s//$'\t'/\\t}"   # Tab
  s="${s//$'\r'/}"      # Carriage return
  printf '%s' "$s"
}

# Get beads task JSON
collect_beads_context() {
  local task="$1" main_repo="$2"
  
  local show_json comments_json
  
  # Get task details as JSON
  show_json="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null || echo '{"error":"show failed"}')"
  
  # Get comments as JSON
  comments_json="$(cd "$main_repo" && bd comments "$task" --json 2>/dev/null || echo '[]')"
  
  cat <<EOF
"task": $show_json,
"comments": $comments_json
EOF
}

# Get git state as JSON
collect_git_context() {
  local exec_repo="$1"
  
  cd "$exec_repo"
  
  local branch uncommitted commits_ahead status_short
  branch="$(git branch --show-current 2>/dev/null || echo "detached")"
  uncommitted="$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')"
  
  # Calculate commits ahead of origin/master (or origin/main)
  local base_branch="master"
  git rev-parse "origin/$base_branch" >/dev/null 2>&1 || base_branch="main"
  commits_ahead="$(git rev-list --count "origin/${base_branch}..HEAD" 2>/dev/null || echo 0)"
  
  # Get short status for context
  status_short="$(git status --short 2>/dev/null | head -20 | tr '\n' ';')"
  
  cat <<EOF
"git": {
  "branch": "$(json_escape "$branch")",
  "uncommitted": $uncommitted,
  "commits_ahead": $commits_ahead,
  "status_short": "$(json_escape "$status_short")"
}
EOF
}

# Get graphite state as JSON
collect_graphite_context() {
  local exec_repo="$1" task="$2"
  
  cd "$exec_repo"
  
  local is_tracked="false" needs_restack="false" pr_number="" gt_log_output
  
  # Check if branch is tracked by graphite
  local current_branch
  current_branch="$(git branch --show-current 2>/dev/null || echo "")"
  if [ -n "$current_branch" ]; then
    if gt ls 2>/dev/null | grep -qF "$current_branch"; then
      is_tracked="true"
    fi
  fi
  
  # Check if needs restack (gt log output)
  gt_log_output="$(gt log 2>&1 || true)"
  if echo "$gt_log_output" | grep -qi "needs restack\|diverged"; then
    needs_restack="true"
  fi
  
  # Extract PR number if exists
  pr_number="$(echo "$gt_log_output" | grep -i "$task" -A10 | grep -oE 'PR #[0-9]+' | head -1 | tr -d 'PR #' || true)"
  
  cat <<EOF
"graphite": {
  "is_tracked": $is_tracked,
  "needs_restack": $needs_restack,
  "pr_number": "$(json_escape "${pr_number:-}")"
}
EOF
}

# Get run history from beads comments
collect_history_context() {
  local task="$1" main_repo="$2"
  
  local comments_json run_count last_result
  comments_json="$(cd "$main_repo" && bd comments "$task" --json 2>/dev/null || echo '[]')"
  
  # Count runs (comments starting with "Run")
  run_count="$(echo "$comments_json" | jq '[.[] | select(.text | startswith("Run"))] | length' 2>/dev/null || echo 0)"
  
  # Get last result
  last_result="$(echo "$comments_json" | jq -r 'if length > 0 then last.text else "none" end' 2>/dev/null || echo "none")"
  
  cat <<EOF
"history": {
  "run_count": $run_count,
  "last_result": "$(json_escape "$last_result")"
}
EOF
}

# Get epic context if task belongs to an epic
collect_epic_context() {
  local task="$1" main_repo="$2"
  
  cd "$main_repo"
  
  # Extract epic from dependencies (looking for parent with Type: epic)
  local task_details epic_id="" epic_title=""
  task_details="$(bd show "$task" 2>/dev/null || true)"
  
  # Search up the dependency tree for an epic
  local deps d
  deps="$(echo "$task_details" | grep -E '→ ' | sed 's/.*→ //' | cut -d: -f1 | tr -d ' ' | head -10)"
  
  while IFS=$'\n' read -r d; do
    [ -n "$d" ] || continue
    local d_details
    d_details="$(bd show "$d" 2>/dev/null || true)"
    if echo "$d_details" | grep -qiE '^\s*(Issue\s*)?Type:\s*epic'; then
      epic_id="$d"
      epic_title="$(echo "$d_details" | grep -iE '^\s*Title:' | head -1 | sed 's/^[^:]*:\s*//' || true)"
      break
    fi
  done <<< "$deps"
  
  cat <<EOF
"epic": {
  "id": "$(json_escape "${epic_id:-}")",
  "title": "$(json_escape "${epic_title:-}")"
}
EOF
}

# Main context collection function
# Outputs valid JSON with all context needed for decision agent
collect_context() {
  local task="$1"
  local main_repo="${2:-$MAIN_REPO}"
  local exec_repo="${3:-$EXEC_REPO}"
  
  # Validate inputs
  [ -n "$task" ] || { echo '{"error":"no task specified"}'; return 1; }
  [ -d "$main_repo/.beads" ] || { echo '{"error":"main_repo has no .beads"}'; return 1; }
  
  # Collect all contexts
  local beads_ctx git_ctx graphite_ctx history_ctx epic_ctx
  
  beads_ctx="$(collect_beads_context "$task" "$main_repo")"
  git_ctx="$(collect_git_context "$exec_repo")"
  graphite_ctx="$(collect_graphite_context "$exec_repo" "$task")"
  history_ctx="$(collect_history_context "$task" "$main_repo")"
  epic_ctx="$(collect_epic_context "$task" "$main_repo")"
  
  # Build final JSON
  cat <<EOF
{
  $beads_ctx,
  $git_ctx,
  $graphite_ctx,
  $history_ctx,
  $epic_ctx,
  "timestamp": "$(date -Iseconds)"
}
EOF
}



