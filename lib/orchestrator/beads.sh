#!/usr/bin/env bash
# beads.sh - Beads state tracking functions
#
# Uses beads' native features to persist orchestrator state:
# - comments: Run history (action, result, timestamp)
# - external_ref: Branch and PR links
# - labels: Stack position, epic membership
# - notes: Current state/blockers
#
# Usage:
#   source beads.sh
#   record_run "$TASK" "implement" "success" "3 files changed"
#   set_branch_ref "$TASK" "epic/abc/xyz-feature"
#   set_pr_ref "$TASK" "26882"

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
BEADS_ACTOR="${BEADS_ACTOR:-orchestrator}"

# ──────────────────────────────────────────────────────────────────────────────
# CORE STATE TRACKING
# ──────────────────────────────────────────────────────────────────────────────

# Record a run in beads comments
# Usage: record_run <task> <action> <result> [details]
record_run() {
  local task="$1" action="$2" result="$3" details="${4:-}"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  local msg="Run: action=$action result=$result"
  [ -n "$details" ] && msg="$msg details=\"$details\""
  
  (cd "$main_repo" && bd comments add "$task" "$msg" --actor "$BEADS_ACTOR" 2>/dev/null) || true
}

# Set branch reference in external_ref
# Usage: set_branch_ref <task> <branch_name>
set_branch_ref() {
  local task="$1" branch="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  # Get existing external_ref to preserve PR if set
  local existing
  existing="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.external_ref // ""' || true)"
  
  local new_ref="branch:$branch"
  
  # If existing has pr:, preserve it
  if echo "$existing" | grep -qE 'pr:[0-9]+'; then
    local pr_part
    pr_part="$(echo "$existing" | grep -oE 'pr:[0-9]+' || true)"
    new_ref="$new_ref $pr_part"
  fi
  
  (cd "$main_repo" && bd update "$task" --external-ref "$new_ref" 2>/dev/null) || true
}

# Set PR reference in external_ref
# Usage: set_pr_ref <task> <pr_number>
set_pr_ref() {
  local task="$1" pr_num="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  # Get existing external_ref to preserve branch if set
  local existing
  existing="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.external_ref // ""' || true)"
  
  local new_ref=""
  
  # If existing has branch:, preserve it
  if echo "$existing" | grep -qE 'branch:[^ ]+'; then
    local branch_part
    branch_part="$(echo "$existing" | grep -oE 'branch:[^ ]+' || true)"
    new_ref="$branch_part "
  fi
  
  new_ref="${new_ref}pr:$pr_num"
  
  (cd "$main_repo" && bd update "$task" --external-ref "$new_ref" 2>/dev/null) || true
}

# Set stack position label
# Usage: set_stack_position <task> <position>
set_stack_position() {
  local task="$1" position="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  # Remove any existing stack label and add new one
  (cd "$main_repo" && bd update "$task" --remove-label "stack:*" 2>/dev/null) || true
  (cd "$main_repo" && bd update "$task" --add-label "stack:$position" 2>/dev/null) || true
}

# Set notes (current state/blockers)
# Usage: set_notes <task> <notes>
set_notes() {
  local task="$1" notes="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd update "$task" --notes "$notes" 2>/dev/null) || true
}

# ──────────────────────────────────────────────────────────────────────────────
# READ FUNCTIONS
# ──────────────────────────────────────────────────────────────────────────────

# Get run count from comments
# Usage: get_run_count <task>
get_run_count() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd comments "$task" --json 2>/dev/null | jq '[.[] | select(.text | startswith("Run:"))] | length' 2>/dev/null) || echo 0
}

# Get branch from external_ref
# Usage: get_branch_ref <task>
get_branch_ref() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  local ext_ref
  ext_ref="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.external_ref // ""' || true)"
  echo "$ext_ref" | grep -oE 'branch:[^ ]+' | sed 's/^branch://' || true
}

# Get PR number from external_ref
# Usage: get_pr_ref <task>
get_pr_ref() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  local ext_ref
  ext_ref="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.external_ref // ""' || true)"
  echo "$ext_ref" | grep -oE 'pr:[0-9]+' | sed 's/^pr://' || true
}

# Get last run result
# Usage: get_last_run <task>
get_last_run() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd comments "$task" --json 2>/dev/null | jq -r '[.[] | select(.text | startswith("Run:"))] | if length > 0 then last.text else "none" end' 2>/dev/null) || echo "none"
}

# ──────────────────────────────────────────────────────────────────────────────
# STATUS TRANSITIONS
# ──────────────────────────────────────────────────────────────────────────────

# Mark task as blocked with reason
# Usage: mark_blocked <task> <reason>
mark_blocked() {
  local task="$1" reason="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd update "$task" --status blocked --notes "$reason" 2>/dev/null) || true
  record_run "$task" "block" "blocked" "$reason"
}

# Close task with reason
# Usage: close_task <task> <reason>
close_task() {
  local task="$1" reason="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd close "$task" --reason "$reason" 2>/dev/null) || true
  record_run "$task" "close" "closed" "$reason"
}

# Mark task as in_progress
# Usage: mark_in_progress <task>
mark_in_progress() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd update "$task" --status in_progress 2>/dev/null) || true
}

# ──────────────────────────────────────────────────────────────────────────────
# EPIC STATE
# ──────────────────────────────────────────────────────────────────────────────

# Update epic with stack info
# Usage: update_epic_stack <epic> <comma-separated-task-ids> <base_branch>
update_epic_stack() {
  local epic="$1" stack="$2" base_branch="$3"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd update "$epic" --notes "stack:$stack base:$base_branch" 2>/dev/null) || true
}

# Get epic base branch from notes
# Usage: get_epic_base <epic>
get_epic_base() {
  local epic="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  local notes
  notes="$(cd "$main_repo" && bd show "$epic" --json 2>/dev/null | jq -r '.notes // ""' || true)"
  echo "$notes" | grep -oE 'base:[^ ]+' | sed 's/^base://' || echo "master"
}

# ──────────────────────────────────────────────────────────────────────────────
# CONVENIENCE: Full state record after action
# ──────────────────────────────────────────────────────────────────────────────

# Record full state after an action
# Usage: record_action_complete <task> <action> <result> <branch> [pr_num] [details]
record_action_complete() {
  local task="$1" action="$2" result="$3" branch="$4"
  local pr_num="${5:-}" details="${6:-}"
  
  # Record the run
  record_run "$task" "$action" "$result" "$details"
  
  # Update branch ref
  [ -n "$branch" ] && set_branch_ref "$task" "$branch"
  
  # Update PR ref if provided
  [ -n "$pr_num" ] && set_pr_ref "$task" "$pr_num"
}



