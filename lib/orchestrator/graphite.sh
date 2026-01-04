#!/usr/bin/env bash
# graphite.sh - Graphite (gt) helpers for the orchestrator
#
# Provides safe wrappers around gt commands with error handling
# and recovery capabilities.
#
# Usage:
#   source graphite.sh
#   gt_create_branch "epic/abc/task-feature" "parent-branch" "[TASK] Feature"

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
GT_CREATE_ARGS=(--no-interactive -a)
GT_MODIFY_ARGS=(--no-interactive -a)
# Note: Removed --ai to preserve task ID in PR title from commit message
GT_SUBMIT_ARGS=(--no-interactive --draft --no-edit)

# ──────────────────────────────────────────────────────────────────────────────
# QUERY FUNCTIONS
# ──────────────────────────────────────────────────────────────────────────────

# Check if current branch is tracked by Graphite
gt_is_tracked() {
  local branch
  branch="$(git branch --show-current 2>/dev/null || echo "")"
  [ -n "$branch" ] || return 1
  gt ls 2>/dev/null | grep -qF "$branch"
}

# Check if branch needs restack
gt_needs_restack() {
  gt log 2>&1 | grep -qiE "needs restack|diverged"
}

# Get PR number for current branch
gt_get_pr_number() {
  local task="${1:-}"
  local output
  output="$(gt log 2>&1 || true)"
  
  if [ -n "$task" ]; then
    echo "$output" | grep -i "$task" -A10 | grep -oE 'PR #[0-9]+' | head -1 | tr -d 'PR #' || true
  else
    echo "$output" | grep -oE 'PR #[0-9]+' | head -1 | tr -d 'PR #' || true
  fi
}

# Check if task has PR (by searching gt log)
gt_task_has_pr() {
  local task="$1"
  local output
  output="$(gt log 2>&1 || true)"
  echo "$output" | grep -i "$task" -A10 | grep -qi "PR #"
}

# ──────────────────────────────────────────────────────────────────────────────
# BRANCH OPERATIONS
# ──────────────────────────────────────────────────────────────────────────────

# Checkout a branch using Graphite (keeps tracking in sync)
# Falls back to git checkout if gt checkout fails
gt_checkout() {
  local branch="$1"
  
  if gt checkout "$branch" --no-interactive >/dev/null 2>&1; then
    return 0
  elif git checkout "$branch" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

# Create a new branch with Graphite tracking
# Usage: gt_create_branch <branch_name> <parent_branch> <commit_message>
# Returns: 0 on success, 1 on failure
gt_create_branch() {
  local branch_name="$1" parent_branch="$2" commit_msg="$3"
  
  # If we have a parent, explicitly pass --parent
  if [ -n "$parent_branch" ]; then
    gt create "${GT_CREATE_ARGS[@]}" "$branch_name" -m "$commit_msg" --parent "$parent_branch" >/dev/null 2>&1
  else
    gt create "${GT_CREATE_ARGS[@]}" "$branch_name" -m "$commit_msg" >/dev/null 2>&1
  fi
}

# Create branch with automatic retry on common failures
# Usage: gt_create_branch_with_retry <branch_name> <parent_branch> <commit_msg>
gt_create_branch_with_retry() {
  local branch_name="$1" parent_branch="$2" commit_msg="$3"
  local err_output=""
  
  # First attempt
  if err_output="$(gt_create_branch "$branch_name" "$parent_branch" "$commit_msg" 2>&1)"; then
    return 0
  fi
  
  # Common fix: diverged tracking
  if echo "$err_output" | grep -qiE "diverged|tracking"; then
    local current
    current="$(git branch --show-current 2>/dev/null || echo "")"
    if [ -n "$current" ]; then
      gt track "$current" --force >/dev/null 2>&1 || true
    fi
    
    # Retry
    if gt_create_branch "$branch_name" "$parent_branch" "$commit_msg" 2>&1; then
      return 0
    fi
  fi
  
  # Branch already exists - try to checkout instead
  if echo "$err_output" | grep -qiE "already exists"; then
    if gt checkout "$branch_name" --no-interactive >/dev/null 2>&1; then
      return 0
    fi
  fi
  
  echo "$err_output"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# COMMIT OPERATIONS
# ──────────────────────────────────────────────────────────────────────────────

# Amend/modify current commit with staged changes
# Usage: gt_modify <commit_message>
gt_modify() {
  local commit_msg="$1"
  gt modify "${GT_MODIFY_ARGS[@]}" -m "$commit_msg" >/dev/null 2>&1
}

# Submit PR for current branch
# Usage: gt_submit
# Returns: PR output (includes PR number)
gt_submit() {
  gt submit "${GT_SUBMIT_ARGS[@]}" 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# REPAIR OPERATIONS
# ──────────────────────────────────────────────────────────────────────────────

# Fix diverged tracking
gt_fix_tracking() {
  local branch="${1:-}"
  [ -z "$branch" ] && branch="$(git branch --show-current 2>/dev/null || echo "")"
  [ -n "$branch" ] || return 1
  
  gt track "$branch" --force >/dev/null 2>&1
}

# Restack current branch
gt_restack() {
  gt restack --no-interactive >/dev/null 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# BRANCH DISCOVERY
# ──────────────────────────────────────────────────────────────────────────────

# Find branch for a task under epic prefix
# Usage: find_task_branch <epic_id> <task_id>
find_task_branch() {
  local epic="$1" task="$2"
  local e t branch=""
  
  e="$(echo "$epic" | sed 's/[^a-zA-Z0-9._\/-]/-/g')"
  t="$(echo "$task" | sed 's/[^a-zA-Z0-9._\/-]/-/g')"
  
  git fetch origin --quiet 2>/dev/null || true
  
  # Check LOCAL branches first (may exist but not yet pushed)
  branch="$(git for-each-ref --format='%(refname:short)' "refs/heads/epic/$e/" 2>/dev/null \
    | grep -i "$t" \
    | head -1)" || true
  
  # Try remote: epic/<epic-id>/<task-id>-...
  if [ -z "$branch" ]; then
    branch="$(git for-each-ref --format='%(refname:short)' "refs/remotes/origin/epic/$e/" 2>/dev/null \
      | grep -i "$t" \
      | head -1 \
      | sed 's|^origin/||')" || true
  fi
  
  # Fall back to flat local branches
  if [ -z "$branch" ]; then
    branch="$(git for-each-ref --format='%(refname:short)' refs/heads/ 2>/dev/null \
      | grep -E ".*${t}" \
      | head -1)" || true
  fi
  
  # Fall back to flat remote branches
  if [ -z "$branch" ]; then
    branch="$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ 2>/dev/null \
      | grep -E "^origin/.*${t}" \
      | head -1 \
      | sed 's|^origin/||')" || true
  fi
  
  echo "$branch"
}

# Find newest branch for an epic (tip of stack)
# Usage: find_epic_tip_branch <epic_id>
find_epic_tip_branch() {
  local epic="$1"
  local e
  e="$(echo "$epic" | sed 's/[^a-zA-Z0-9._\/-]/-/g')"
  
  git fetch origin --quiet 2>/dev/null || true
  
  # Only use branches that follow the epic/<epic-id>/... convention
  local branch
  branch="$(git for-each-ref --sort=-committerdate --format='%(refname:short)' "refs/remotes/origin/epic/$e/" 2>/dev/null \
    | head -1 \
    | sed 's|^origin/||')" || true
  
  echo "$branch"
}

# Find parent branch for a task (from its dependencies)
# Usage: find_parent_branch_for_task <epic_id> <task_id> <main_repo>
find_parent_branch_for_task() {
  local epic="$1" task="$2" main_repo="${3:-$MAIN_REPO}"
  
  # Get task dependencies from beads
  local details deps d b
  details="$(cd "$main_repo" && bd show "$task" 2>/dev/null || true)"
  
  # Extract dep IDs: lines like "→ <ID>: <title>"
  deps="$(echo "$details" | grep -E '→ ' | sed 's/.*→ //' | cut -d: -f1 | tr -d ' ' | head -10)"
  
  while IFS=$'\n' read -r d; do
    [ -n "$d" ] || continue
    b="$(find_task_branch "$epic" "$d")"
    if [ -n "$b" ]; then
      echo "$b"
      return 0
    fi
  done <<< "$deps"
  
  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# BRANCH NAMING
# ──────────────────────────────────────────────────────────────────────────────

# Slugify title for branch name
slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/^-//; s/-$//' \
    | cut -c1-60
}

# Generate branch name for a task
# Usage: generate_branch_name <task_id> <title> [epic_id]
generate_branch_name() {
  local task="$1" title="$2" epic="${3:-}"
  
  local slug task_clean epic_clean
  slug="$(slugify "$title")"
  task_clean="$(echo "$task" | sed 's/[^a-zA-Z0-9._\/-]/-/g')"
  
  if [ -n "$epic" ]; then
    epic_clean="$(echo "$epic" | sed 's/[^a-zA-Z0-9._\/-]/-/g')"
    echo "epic/${epic_clean}/${task_clean}-${slug}"
  else
    echo "agent/${task_clean}-${slug}"
  fi
}



