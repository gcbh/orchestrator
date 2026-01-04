#!/usr/bin/env bash
# allowlist.sh - Bounded remediation action executor
#
# The LLM classifier recommends actions from a fixed allowlist.
# This module executes those actions safely.
#
# Key principle: LLMs never execute arbitrary commands.
# All tool execution is code-owned.
#
# Usage:
#   source allowlist.sh
#   execute_remediation "$CLASSIFICATION_JSON"

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=beads.sh
source "$SCRIPT_DIR/beads.sh" 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# ALLOWED ACTIONS (exhaustive list)
# ──────────────────────────────────────────────────────────────────────────────
# The classifier can only recommend these actions.
# Any action not in this list is rejected.

ALLOWED_ACTIONS=(
  "GT_SYNC"
  "GT_RESTACK"
  "GT_TRACK_FORCE"
  "GT_SUBMIT"
  "GT_MODIFY"
  "GIT_FETCH"
  "GIT_PULL_REBASE"
  "GIT_STASH_PUSH"
  "GIT_REBASE_ABORT"
  "GIT_CHECKOUT_BRANCH"
  "BD_BLOCK"
  "BD_CLOSE"
  "RETRY_STEP"
  "RETRY_WITH_DELAY"
  "RETRY_IMPLEMENTER"
  "RETRY_CHECKER"
  "SKIP_TO_CLOSE"
  "SKIP_TO_SUBMIT"
  "BLOCK_TASK"
  "NOTIFY_HUMAN"
  "NOOP"
)

# ──────────────────────────────────────────────────────────────────────────────
# ACTION IMPLEMENTATIONS
# ──────────────────────────────────────────────────────────────────────────────

execute_gt_sync() {
  gt sync --no-interactive >/dev/null 2>&1
}

execute_gt_restack() {
  gt restack --no-interactive >/dev/null 2>&1
}

execute_gt_track_force() {
  local branch="${1:-}"
  [ -z "$branch" ] && branch="$(git branch --show-current 2>/dev/null || echo "")"
  [ -n "$branch" ] && gt track "$branch" --force >/dev/null 2>&1
}

execute_gt_submit() {
  gt submit --no-interactive --draft --no-edit --ai 2>&1
}

execute_gt_modify() {
  local msg="${1:-WIP}"
  git add -A -- ":(exclude).beads" ":(exclude).claude" ":(exclude).cursor/rules/personal" 2>/dev/null || git add -A
  gt modify --no-interactive -a -m "$msg" >/dev/null 2>&1
}

execute_git_fetch() {
  git fetch origin --prune >/dev/null 2>&1
}

execute_git_pull_rebase() {
  git pull --rebase >/dev/null 2>&1
}

execute_git_stash_push() {
  local msg="remediation-stash-$(date +%Y%m%d-%H%M%S)"
  git stash push -m "$msg" >/dev/null 2>&1
}

execute_git_rebase_abort() {
  git rebase --abort >/dev/null 2>&1 || true
}

execute_git_checkout_branch() {
  local branch="$1"
  git checkout "$branch" >/dev/null 2>&1
}

execute_bd_block() {
  local task="$1" reason="$2"
  mark_blocked "$task" "$reason"
}

execute_bd_close() {
  local task="$1" reason="$2"
  close_task "$task" "$reason"
}

execute_retry_with_delay() {
  local delay="${1:-60}"
  sleep "$delay"
}

execute_notify_human() {
  local message="$1"
  # Log the message - in production this could send notifications
  echo "$(date): HUMAN_INTERVENTION_REQUIRED: $message" >&2
}

# ──────────────────────────────────────────────────────────────────────────────
# ACTION VALIDATOR
# ──────────────────────────────────────────────────────────────────────────────

# Check if action is in allowlist
is_allowed_action() {
  local action="$1"
  
  for allowed in "${ALLOWED_ACTIONS[@]}"; do
    if [ "$allowed" = "$action" ]; then
      return 0
    fi
  done
  
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# SINGLE ACTION EXECUTOR
# ──────────────────────────────────────────────────────────────────────────────

# Execute a single remediation action
# Usage: execute_action <action> [task] [arg1] [arg2]
# Returns: 0 on success, 1 on failure
execute_action() {
  local action="$1"
  local task="${2:-}"
  local arg1="${3:-}"
  local arg2="${4:-}"
  
  # Validate action is allowed
  if ! is_allowed_action "$action"; then
    echo "REJECTED: Action '$action' not in allowlist" >&2
    return 1
  fi
  
  case "$action" in
    GT_SYNC)
      execute_gt_sync
      ;;
    GT_RESTACK)
      execute_gt_restack
      ;;
    GT_TRACK_FORCE)
      execute_gt_track_force "$arg1"
      ;;
    GT_SUBMIT)
      execute_gt_submit
      ;;
    GT_MODIFY)
      execute_gt_modify "$arg1"
      ;;
    GIT_FETCH)
      execute_git_fetch
      ;;
    GIT_PULL_REBASE)
      execute_git_pull_rebase
      ;;
    GIT_STASH_PUSH)
      execute_git_stash_push
      ;;
    GIT_REBASE_ABORT)
      execute_git_rebase_abort
      ;;
    GIT_CHECKOUT_BRANCH)
      execute_git_checkout_branch "$arg1"
      ;;
    BD_BLOCK|BLOCK_TASK)
      execute_bd_block "$task" "${arg1:-Blocked by orchestrator}"
      ;;
    BD_CLOSE)
      execute_bd_close "$task" "${arg1:-Closed by orchestrator}"
      ;;
    RETRY_STEP|RETRY_IMPLEMENTER|RETRY_CHECKER)
      # These are signals, not actual actions
      return 0
      ;;
    RETRY_WITH_DELAY)
      execute_retry_with_delay "${arg1:-60}"
      ;;
    SKIP_TO_CLOSE|SKIP_TO_SUBMIT)
      # These are signals, not actual actions
      return 0
      ;;
    NOTIFY_HUMAN)
      execute_notify_human "${arg1:-Requires human intervention}"
      ;;
    NOOP)
      return 0
      ;;
    *)
      echo "UNKNOWN: Action '$action' not implemented" >&2
      return 1
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# REMEDIATION EXECUTOR
# ──────────────────────────────────────────────────────────────────────────────

# Execute remediation based on classifier output
# Usage: execute_remediation <classification_json> <task>
# Returns JSON: {"success": bool, "actions_executed": [...], "should_retry": bool, "should_block": bool}
execute_remediation() {
  local classification_json="$1"
  local task="${2:-}"
  
  local actions retryable needs_human human_message
  actions="$(echo "$classification_json" | jq -r '.recommended_actions // [] | .[]' 2>/dev/null || true)"
  retryable="$(echo "$classification_json" | jq -r '.retryable // false' 2>/dev/null || echo "false")"
  needs_human="$(echo "$classification_json" | jq -r '.needs_human // false' 2>/dev/null || echo "false")"
  human_message="$(echo "$classification_json" | jq -r '.human_message // ""' 2>/dev/null || true)"
  
  local executed=()
  local success=true
  local should_retry=false
  local should_block=false
  local skip_to=""
  
  # Execute each action in sequence
  while IFS= read -r action; do
    [ -z "$action" ] && continue
    
    # Check for special control flow actions
    case "$action" in
      RETRY_STEP|RETRY_IMPLEMENTER|RETRY_CHECKER)
        should_retry=true
        executed+=("$action")
        continue
        ;;
      SKIP_TO_CLOSE)
        skip_to="close"
        executed+=("$action")
        continue
        ;;
      SKIP_TO_SUBMIT)
        skip_to="submit"
        executed+=("$action")
        continue
        ;;
      BLOCK_TASK|BD_BLOCK)
        should_block=true
        ;;
    esac
    
    # Execute the action
    if execute_action "$action" "$task" "" "" 2>/dev/null; then
      executed+=("$action")
    else
      success=false
      break
    fi
  done <<< "$actions"
  
  # Handle human notification
  if [ "$needs_human" = "true" ] && [ -n "$human_message" ]; then
    execute_notify_human "$human_message"
    should_block=true
  fi
  
  # Build result JSON
  local executed_json
  executed_json="$(printf '%s\n' "${executed[@]}" | jq -R . | jq -s .)"
  
  cat <<EOF
{
  "success": $success,
  "actions_executed": $executed_json,
  "should_retry": $should_retry,
  "should_block": $should_block,
  "skip_to": "${skip_to:-}",
  "retryable": $retryable
}
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# CONVENIENCE: Handle failure with classification and remediation
# ──────────────────────────────────────────────────────────────────────────────

# Full failure handling pipeline
# Usage: handle_failure_with_remediation <step> <exit_code> <context_json> <error_output> <task>
# Returns: JSON result
handle_failure_with_remediation() {
  local step="$1"
  local exit_code="$2"
  local context_json="$3"
  local error_output="$4"
  local task="$5"
  
  # Source classifier if not already loaded
  source "$SCRIPT_DIR/failure_classifier.sh" 2>/dev/null || true
  
  # Classify the failure
  local classification
  classification="$(classify_failure "$step" "$exit_code" "$context_json" "$error_output")"
  
  # Execute remediation
  local remediation_result
  remediation_result="$(execute_remediation "$classification" "$task")"
  
  # Combine results
  cat <<EOF
{
  "classification": $classification,
  "remediation": $remediation_result
}
EOF
}



