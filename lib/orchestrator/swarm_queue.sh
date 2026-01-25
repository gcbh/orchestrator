#!/usr/bin/env bash
# swarm_queue.sh - Task distribution with epic affinity for swarm workers
#
# Provides task claiming mechanism with:
# - Atomic task claiming via beads + locks
# - Epic affinity (workers prefer tasks from epics they've worked on)
# - Priority-based task selection
# - Support for filtering blocked/locked tasks
#
# Usage:
#   source swarm_queue.sh
#   TASK=$(queue_claim_next "$WORKER_ID" "$LAST_EPIC_ID")

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=swarm_lock.sh
source "$SCRIPT_DIR/swarm_lock.sh" 2>/dev/null || true

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Epic affinity: prefer tasks from same epic
SWARM_EPIC_AFFINITY="${SWARM_EPIC_AFFINITY:-1}"

# Affinity bonus (higher = stronger preference for same epic)
SWARM_AFFINITY_BONUS="${SWARM_AFFINITY_BONUS:-100}"

# Main repo for beads queries
MAIN_REPO="${MAIN_REPO:-}"

# ──────────────────────────────────────────────────────────────────────────────
# BEADS QUERIES
# ──────────────────────────────────────────────────────────────────────────────

# Get all ready tasks as JSON
_queue_ready_json() {
  local main_repo="${MAIN_REPO:-$(pwd)}"
  (cd "$main_repo" && bd ready --json 2>/dev/null || echo "[]")
}

# Get epic ID for a task (walks dependency tree)
# This is expensive, so we cache results
_queue_get_epic() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"

  # Check if task itself is an epic
  local task_type
  task_type="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.[0].issue_type // ""' || true)"
  if [ "$task_type" = "epic" ]; then
    echo "$task"
    return 0
  fi

  # Walk dependencies to find epic (max depth 6)
  local depth=0
  local queue="$task"
  local seen=""
  local max_depth=6

  while [ "$depth" -lt "$max_depth" ]; do
    local next_queue=""
    while IFS= read -r cur; do
      [ -n "$cur" ] || continue
      if echo "$seen" | grep -qx "$cur" 2>/dev/null; then
        continue
      fi
      seen="$(printf "%s\n%s" "$seen" "$cur" | awk 'NF>0')"

      # Get dependencies
      local deps
      deps="$(cd "$main_repo" && bd show "$cur" 2>/dev/null | grep -E '→ ' | sed 's/.*→ //' | cut -d: -f1 | tr -d ' ' || true)"

      while IFS= read -r dep; do
        [ -n "$dep" ] || continue

        # Check if this dep is an epic
        local dep_type
        dep_type="$(cd "$main_repo" && bd show "$dep" --json 2>/dev/null | jq -r '.[0].issue_type // ""' || true)"
        if [ "$dep_type" = "epic" ]; then
          echo "$dep"
          return 0
        fi

        next_queue="$(printf "%s\n%s" "$next_queue" "$dep" | awk 'NF>0')"
      done <<< "$deps"
    done <<< "$queue"

    queue="$next_queue"
    depth=$((depth + 1))
    [ -n "$queue" ] || break
  done

  echo ""  # No epic found
}

# Get task priority (from beads, default to 3)
_queue_get_priority() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  (cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.[0].priority // 3' || echo 3)
}

# ──────────────────────────────────────────────────────────────────────────────
# TASK FILTERING
# ──────────────────────────────────────────────────────────────────────────────

# Get list of claimable tasks (unlocked, non-epic, ready)
# Usage: queue_get_claimable
# Outputs: JSON array of claimable tasks with epic info
queue_get_claimable() {
  local ready_json
  ready_json="$(_queue_ready_json)"

  # Filter to non-epic tasks only
  local tasks
  tasks="$(echo "$ready_json" | jq -r '[.[] | select(.issue_type != "epic")] | .[].id' 2>/dev/null || true)"

  local result="["
  local first=true

  while IFS= read -r task; do
    [ -n "$task" ] || continue

    # Skip if locked
    if task_is_locked "$task"; then
      continue
    fi

    # Skip if epic is locked (in serialize mode)
    local epic_id=""
    if [ "$SWARM_EPIC_SERIALIZE" = "1" ] || [ "$SWARM_EPIC_AFFINITY" = "1" ]; then
      epic_id="$(_queue_get_epic "$task")"
      if [ "$SWARM_EPIC_SERIALIZE" = "1" ] && [ -n "$epic_id" ] && epic_is_locked "$epic_id"; then
        continue
      fi
    fi

    # Get task info
    local title priority
    title="$(echo "$ready_json" | jq -r ".[] | select(.id == \"$task\") | .title // \"\"" 2>/dev/null | head -1 || true)"
    priority="$(echo "$ready_json" | jq -r ".[] | select(.id == \"$task\") | .priority // 3" 2>/dev/null | head -1 || echo 3)"

    [ "$first" = "true" ] || result="$result,"
    result="$result{\"id\":\"$task\",\"title\":\"$title\",\"priority\":$priority,\"epic_id\":\"$epic_id\"}"
    first=false

  done <<< "$tasks"

  result="$result]"
  echo "$result"
}

# ──────────────────────────────────────────────────────────────────────────────
# TASK SCORING
# ──────────────────────────────────────────────────────────────────────────────

# Score a task for a worker (higher = better match)
# Usage: queue_score_task <task_json> <worker_last_epic>
# Outputs: numeric score
queue_score_task() {
  local task_json="$1"
  local worker_last_epic="${2:-}"

  local priority epic_id score
  priority="$(echo "$task_json" | jq -r '.priority // 3')"
  epic_id="$(echo "$task_json" | jq -r '.epic_id // ""')"

  # Base score: inverse of priority (lower priority number = higher score)
  # Priority 1 -> score 50, Priority 5 -> score 10
  score=$((60 - priority * 10))

  # Epic affinity bonus
  if [ "$SWARM_EPIC_AFFINITY" = "1" ] && [ -n "$worker_last_epic" ] && [ -n "$epic_id" ]; then
    if [ "$epic_id" = "$worker_last_epic" ]; then
      score=$((score + SWARM_AFFINITY_BONUS))
    fi
  fi

  echo "$score"
}

# ──────────────────────────────────────────────────────────────────────────────
# TASK CLAIMING
# ──────────────────────────────────────────────────────────────────────────────

# Claim the best available task for a worker
# Usage: queue_claim_next <worker_id> [last_epic_id]
# Outputs: task_id if claimed, empty if none available
# Returns: 0 if task claimed, 1 if no tasks
queue_claim_next() {
  local worker_id="$1"
  local last_epic="${2:-}"

  # Get claimable tasks
  local claimable
  claimable="$(queue_get_claimable)"

  local count
  count="$(echo "$claimable" | jq 'length' 2>/dev/null || echo 0)"

  if [ "$count" -eq 0 ]; then
    return 1
  fi

  # Score and sort tasks
  local best_task=""
  local best_score=-1

  local i=0
  while [ "$i" -lt "$count" ]; do
    local task_json task_id score
    task_json="$(echo "$claimable" | jq ".[$i]")"
    task_id="$(echo "$task_json" | jq -r '.id')"
    score="$(queue_score_task "$task_json" "$last_epic")"

    if [ "$score" -gt "$best_score" ]; then
      best_score="$score"
      best_task="$task_id"
    fi

    i=$((i + 1))
  done

  if [ -z "$best_task" ]; then
    return 1
  fi

  # Try to acquire lock
  if task_lock_acquire "$best_task" "$worker_id"; then
    # If epic serialization is on, also acquire epic lock
    if [ "$SWARM_EPIC_SERIALIZE" = "1" ]; then
      local epic_id
      epic_id="$(_queue_get_epic "$best_task")"
      if [ -n "$epic_id" ]; then
        if ! epic_lock_acquire "$epic_id" "$worker_id"; then
          # Failed to get epic lock, release task lock and retry
          task_lock_release "$best_task" "$worker_id"
          return 1
        fi
      fi
    fi

    echo "$best_task"
    return 0
  fi

  # Lost race, try next best
  # For simplicity, just fail and retry on next iteration
  return 1
}

# Release task claim (and epic lock if held)
# Usage: queue_release_task <task_id> <worker_id> [epic_id]
queue_release_task() {
  local task="$1"
  local worker_id="$2"
  local epic_id="${3:-}"

  task_lock_release "$task" "$worker_id"

  if [ "$SWARM_EPIC_SERIALIZE" = "1" ] && [ -n "$epic_id" ]; then
    epic_lock_release "$epic_id" "$worker_id"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# QUEUE STATUS
# ──────────────────────────────────────────────────────────────────────────────

# Get queue summary
# Usage: queue_status
# Outputs: JSON with queue statistics
queue_status() {
  local ready_json claimable_json
  ready_json="$(_queue_ready_json)"
  claimable_json="$(queue_get_claimable)"

  local total_ready total_claimable locked_count epic_count
  total_ready="$(echo "$ready_json" | jq '[.[] | select(.issue_type != "epic")] | length' 2>/dev/null || echo 0)"
  total_claimable="$(echo "$claimable_json" | jq 'length' 2>/dev/null || echo 0)"
  epic_count="$(echo "$ready_json" | jq '[.[] | select(.issue_type == "epic")] | length' 2>/dev/null || echo 0)"
  locked_count=$((total_ready - total_claimable))

  cat <<EOF
{
  "total_ready": $total_ready,
  "claimable": $total_claimable,
  "locked": $locked_count,
  "epics": $epic_count,
  "timestamp": $(date +%s)
}
EOF
}

# Get detailed task list with status
# Usage: queue_list_detailed
queue_list_detailed() {
  local ready_json
  ready_json="$(_queue_ready_json)"

  local tasks
  tasks="$(echo "$ready_json" | jq -r '[.[] | select(.issue_type != "epic")] | .[].id' 2>/dev/null || true)"

  echo "["
  local first=true

  while IFS= read -r task; do
    [ -n "$task" ] || continue

    local title priority status owner epic_id
    title="$(echo "$ready_json" | jq -r ".[] | select(.id == \"$task\") | .title // \"\"" 2>/dev/null | head -1 || true)"
    priority="$(echo "$ready_json" | jq -r ".[] | select(.id == \"$task\") | .priority // 3" 2>/dev/null | head -1 || echo 3)"

    if task_is_locked "$task"; then
      status="locked"
      owner="$(task_lock_owner "$task")"
    else
      status="available"
      owner=""
    fi

    epic_id="$(_queue_get_epic "$task" 2>/dev/null || echo "")"

    [ "$first" = "true" ] || echo ","
    cat <<EOF
  {
    "id": "$task",
    "title": "$title",
    "priority": $priority,
    "status": "$status",
    "owner": "$owner",
    "epic_id": "$epic_id"
  }
EOF
    first=false

  done <<< "$tasks"

  echo "]"
}

# Mark task as in_progress in beads
# Usage: queue_mark_in_progress <task_id>
queue_mark_in_progress() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  (cd "$main_repo" && bd update "$task" --status in_progress 2>/dev/null) || true
}

# Mark task as blocked in beads
# Usage: queue_mark_blocked <task_id> <reason>
queue_mark_blocked() {
  local task="$1"
  local reason="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  (cd "$main_repo" && bd update "$task" --status blocked --notes "$reason" 2>/dev/null) || true
}

# Close task in beads
# Usage: queue_close_task <task_id> <reason>
queue_close_task() {
  local task="$1"
  local reason="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  (cd "$main_repo" && bd close "$task" --reason "$reason" 2>/dev/null) || true
}
