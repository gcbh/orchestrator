#!/usr/bin/env bash
# reconcile.sh - Idempotency and reconciliation rules
#
# Before each step, check existing state and reconcile.
# This ensures the orchestrator is resumable and never creates duplicates.
#
# Key rules:
# - If branch exists → use it (don't create new)
# - If PR exists → close bead (don't submit again)
# - If already closed → skip
# - Never create duplicate work
#
# Usage:
#   source reconcile.sh
#   RECONCILED=$(reconcile_task "$TASK" "$EPIC_ID")

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=graphite.sh
source "$SCRIPT_DIR/graphite.sh" 2>/dev/null || true
# shellcheck source=beads.sh
source "$SCRIPT_DIR/beads.sh" 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# RECONCILIATION RESULTS
# ──────────────────────────────────────────────────────────────────────────────
# Each reconcile function returns a JSON object with:
# {
#   "action": "continue|skip|close|use_existing",
#   "reason": "explanation",
#   "data": { action-specific data }
# }

# ──────────────────────────────────────────────────────────────────────────────
# TASK STATUS RECONCILIATION
# ──────────────────────────────────────────────────────────────────────────────

# Check if task is already closed or blocked
reconcile_task_status() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  local status
  status="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.status // "open"' || echo "open")"
  
  case "$status" in
    closed)
      echo '{"action":"skip","reason":"Task already closed","data":{}}'
      ;;
    blocked)
      local notes
      notes="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.notes // ""' || true)"
      echo "{\"action\":\"skip\",\"reason\":\"Task is blocked: $notes\",\"data\":{}}"
      ;;
    *)
      echo '{"action":"continue","reason":"Task is open/in_progress","data":{}}'
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# BRANCH RECONCILIATION
# ──────────────────────────────────────────────────────────────────────────────

# Check if branch already exists for this task
# If it does, we should use it instead of creating a new one
reconcile_branch() {
  local task="$1"
  local epic_id="${2:-}"
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  
  cd "$exec_repo"
  git fetch origin --quiet 2>/dev/null || true
  
  local existing_branch=""
  
  if [ -n "$epic_id" ]; then
    existing_branch="$(find_task_branch "$epic_id" "$task")"
  else
    # Try flat branch patterns
    local task_clean
    task_clean="$(echo "$task" | sed 's/[^a-zA-Z0-9._\/-]/-/g')"
    
    # Check local branches first
    existing_branch="$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
      | grep -E ".*${task_clean}" \
      | head -1)" || true
    
    # Then remote
    if [ -z "$existing_branch" ]; then
      existing_branch="$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ 2>/dev/null \
        | grep -E ".*${task_clean}" \
        | head -1 \
        | sed 's|^origin/||')" || true
    fi
  fi
  
  if [ -n "$existing_branch" ]; then
    echo "{\"action\":\"use_existing\",\"reason\":\"Branch exists: $existing_branch\",\"data\":{\"branch\":\"$existing_branch\"}}"
  else
    echo '{"action":"continue","reason":"No existing branch found","data":{}}'
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# PR RECONCILIATION
# ──────────────────────────────────────────────────────────────────────────────

# Check if PR already exists for this task
# If it does, we should close the bead instead of submitting again
reconcile_pr() {
  local task="$1"
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  
  cd "$exec_repo"
  
  # Check gt log for existing PR
  local gt_log pr_number=""
  gt_log="$(gt log 2>&1 || true)"
  
  if echo "$gt_log" | grep -i "$task" -A10 | grep -qi "PR #"; then
    pr_number="$(echo "$gt_log" | grep -i "$task" -A10 | grep -oE 'PR #[0-9]+' | head -1 | tr -d 'PR #' || true)"
  fi
  
  # Also check external_ref in beads
  if [ -z "$pr_number" ]; then
    local ext_ref
    ext_ref="$(get_pr_ref "$task" 2>/dev/null || true)"
    [ -n "$ext_ref" ] && pr_number="$ext_ref"
  fi
  
  if [ -n "$pr_number" ]; then
    echo "{\"action\":\"close\",\"reason\":\"PR #$pr_number already exists\",\"data\":{\"pr_number\":\"$pr_number\"}}"
  else
    echo '{"action":"continue","reason":"No existing PR found","data":{}}'
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# WORK RECONCILIATION
# ──────────────────────────────────────────────────────────────────────────────

# Check if work has already been done (commits exist, but no PR yet)
reconcile_work() {
  local task="$1"
  local parent_branch="${2:-master}"
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  
  cd "$exec_repo"
  
  local current_branch commits_ahead
  current_branch="$(git branch --show-current 2>/dev/null || echo "")"
  
  if [ -z "$current_branch" ]; then
    echo '{"action":"continue","reason":"Not on a branch","data":{}}'
    return 0
  fi
  
  # Check if remote parent exists
  git fetch origin "$parent_branch" --quiet 2>/dev/null || true
  
  if git rev-parse "origin/$parent_branch" >/dev/null 2>&1; then
    commits_ahead="$(git rev-list --count "origin/${parent_branch}..HEAD" 2>/dev/null || echo 0)"
  else
    commits_ahead=0
  fi
  
  if [ "$commits_ahead" -gt 0 ]; then
    echo "{\"action\":\"submit\",\"reason\":\"Branch is $commits_ahead commits ahead of $parent_branch\",\"data\":{\"commits_ahead\":$commits_ahead}}"
  else
    echo '{"action":"continue","reason":"No commits ahead of parent","data":{}}'
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# UNCOMMITTED CHANGES RECONCILIATION
# ──────────────────────────────────────────────────────────────────────────────

# Check for uncommitted changes that might block operations
reconcile_uncommitted() {
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  
  cd "$exec_repo"
  
  local uncommitted
  uncommitted="$(git status --porcelain 2>/dev/null | grep -v '\.beads/' | grep -v '\.claude/' | grep -v '\.cursor/rules/personal/' | wc -l | tr -d ' ')"
  
  if [ "$uncommitted" -gt 0 ]; then
    echo "{\"action\":\"stash\",\"reason\":\"$uncommitted uncommitted changes found\",\"data\":{\"uncommitted\":$uncommitted}}"
  else
    echo '{"action":"continue","reason":"Working directory clean","data":{}}'
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# GRAPHITE STATE RECONCILIATION
# ──────────────────────────────────────────────────────────────────────────────

# Check Graphite state and determine if fixes are needed
reconcile_graphite() {
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  
  cd "$exec_repo"
  
  local current_branch
  current_branch="$(git branch --show-current 2>/dev/null || echo "")"
  
  if [ -z "$current_branch" ]; then
    echo '{"action":"continue","reason":"Not on a branch","data":{}}'
    return 0
  fi
  
  # Check if tracked
  local is_tracked=false
  if gt ls 2>/dev/null | grep -qF "$current_branch"; then
    is_tracked=true
  fi
  
  if [ "$is_tracked" = "false" ]; then
    echo "{\"action\":\"track\",\"reason\":\"Branch not tracked by Graphite\",\"data\":{\"branch\":\"$current_branch\"}}"
    return 0
  fi
  
  # Check if needs restack
  local gt_log
  gt_log="$(gt log 2>&1 || true)"
  if echo "$gt_log" | grep -qiE "needs restack|diverged"; then
    echo '{"action":"restack","reason":"Graphite stack needs restack","data":{}}'
    return 0
  fi
  
  echo '{"action":"continue","reason":"Graphite state is clean","data":{}}'
}

# ──────────────────────────────────────────────────────────────────────────────
# FULL RECONCILIATION
# ──────────────────────────────────────────────────────────────────────────────

# Run all reconciliation checks and return first non-continue action
# Usage: reconcile_all <task> <epic_id> <parent_branch>
reconcile_all() {
  local task="$1"
  local epic_id="${2:-}"
  local parent_branch="${3:-master}"
  
  local result action
  
  # 1. Task status (closed? blocked?)
  result="$(reconcile_task_status "$task")"
  action="$(echo "$result" | jq -r '.action')"
  [ "$action" != "continue" ] && { echo "$result"; return 0; }
  
  # 2. PR exists? (skip to close)
  result="$(reconcile_pr "$task")"
  action="$(echo "$result" | jq -r '.action')"
  [ "$action" != "continue" ] && { echo "$result"; return 0; }
  
  # 3. Branch exists? (use existing)
  result="$(reconcile_branch "$task" "$epic_id")"
  action="$(echo "$result" | jq -r '.action')"
  [ "$action" != "continue" ] && { echo "$result"; return 0; }
  
  # All checks passed - continue with normal flow
  echo '{"action":"continue","reason":"All reconciliation checks passed","data":{}}'
}

# ──────────────────────────────────────────────────────────────────────────────
# APPLY RECONCILIATION
# ──────────────────────────────────────────────────────────────────────────────

# Apply the reconciliation action
# Returns: 0 if handled, 1 if should continue normal flow
apply_reconciliation() {
  local reconcile_json="$1"
  local task="$2"
  
  local action reason
  action="$(echo "$reconcile_json" | jq -r '.action')"
  reason="$(echo "$reconcile_json" | jq -r '.reason')"
  
  case "$action" in
    skip)
      echo "SKIP: $reason"
      return 0
      ;;
    close)
      local pr_number
      pr_number="$(echo "$reconcile_json" | jq -r '.data.pr_number // ""')"
      close_task "$task" "Completed in PR #$pr_number"
      echo "CLOSED: $reason"
      return 0
      ;;
    use_existing)
      local branch
      branch="$(echo "$reconcile_json" | jq -r '.data.branch')"
      gt_checkout "$branch" 2>/dev/null || git checkout "$branch" 2>/dev/null || true
      echo "CHECKOUT: $branch"
      return 1  # Continue with implementation
      ;;
    submit)
      echo "SUBMIT: $reason"
      return 1  # Signal to skip to submit step
      ;;
    stash)
      local msg
      msg="reconcile-stash-$(date +%Y%m%d-%H%M%S)"
      git stash push -m "$msg" >/dev/null 2>&1 || true
      echo "STASHED: $reason"
      return 1  # Continue after stashing
      ;;
    track)
      local branch
      branch="$(echo "$reconcile_json" | jq -r '.data.branch')"
      gt track "$branch" --force >/dev/null 2>&1 || true
      echo "TRACKED: $branch"
      return 1  # Continue after tracking
      ;;
    restack)
      gt restack --no-interactive >/dev/null 2>&1 || true
      echo "RESTACKED"
      return 1  # Continue after restack
      ;;
    continue)
      return 1  # Normal flow
      ;;
    *)
      echo "UNKNOWN_ACTION: $action"
      return 1
      ;;
  esac
}



