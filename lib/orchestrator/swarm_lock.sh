#!/usr/bin/env bash
# swarm_lock.sh - Per-task locking for swarm workers
#
# Provides atomic lock acquisition for tasks to prevent multiple workers
# from claiming the same task.
#
# Lock Strategy:
#   /tmp/swarm-locks/
#   ├── coordinator.lock      # Single coordinator
#   ├── tasks/
#   │   ├── TASK-123.lock     # Per-task (contains worker PID + timestamp)
#   │   └── TASK-456.lock
#   └── epics/
#       └── EPIC-001.lock     # Epic serialization (optional)
#
# Usage:
#   source swarm_lock.sh
#   if task_lock_acquire "TASK-123" "$WORKER_ID"; then
#     # Do work
#     task_lock_release "TASK-123" "$WORKER_ID"
#   fi

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

SWARM_LOCK_DIR="${SWARM_LOCK_DIR:-/tmp/swarm-locks}"
SWARM_LOCK_TTL_SECS="${SWARM_LOCK_TTL_SECS:-3600}"  # 1 hour default
SWARM_EPIC_SERIALIZE="${SWARM_EPIC_SERIALIZE:-0}"   # 0 = full parallel

# ──────────────────────────────────────────────────────────────────────────────
# INITIALIZATION
# ──────────────────────────────────────────────────────────────────────────────

# Initialize lock directory structure
swarm_lock_init() {
  mkdir -p "$SWARM_LOCK_DIR/tasks"
  mkdir -p "$SWARM_LOCK_DIR/epics"
  mkdir -p "$SWARM_LOCK_DIR/workers"
}

# ──────────────────────────────────────────────────────────────────────────────
# TASK LOCKING
# ──────────────────────────────────────────────────────────────────────────────

# Sanitize task ID for use in filenames
_sanitize_lock_name() {
  echo "$1" | tr -c 'a-zA-Z0-9._-' '_'
}

# Get lock file path for a task
_task_lock_file() {
  local task="$1"
  local safe_name
  safe_name="$(_sanitize_lock_name "$task")"
  echo "$SWARM_LOCK_DIR/tasks/${safe_name}.lock"
}

# Get lock file path for an epic
_epic_lock_file() {
  local epic="$1"
  local safe_name
  safe_name="$(_sanitize_lock_name "$epic")"
  echo "$SWARM_LOCK_DIR/epics/${safe_name}.lock"
}

# Check if a lock is stale (TTL expired or owner process dead)
_lock_is_stale() {
  local lock_file="$1"

  [ ! -f "$lock_file" ] && return 0  # No lock = stale (available)

  local lock_mtime owner_pid lock_age
  lock_mtime="$(stat -c %Y "$lock_file" 2>/dev/null || stat -f %m "$lock_file" 2>/dev/null || echo 0)"
  lock_age=$(( $(date +%s) - lock_mtime ))

  # Check TTL
  if [ "$lock_age" -gt "$SWARM_LOCK_TTL_SECS" ]; then
    return 0  # Stale by TTL
  fi

  # Check if owner process is alive
  owner_pid="$(head -1 "$lock_file" 2>/dev/null | cut -d: -f1 || echo "")"
  if [ -n "$owner_pid" ] && ! kill -0 "$owner_pid" 2>/dev/null; then
    return 0  # Stale by dead process
  fi

  return 1  # Lock is valid
}

# Acquire task lock atomically
# Usage: task_lock_acquire <task_id> <worker_id>
# Returns: 0 if acquired, 1 if already locked
task_lock_acquire() {
  local task="$1"
  local worker_id="$2"
  local lock_file
  lock_file="$(_task_lock_file "$task")"

  # Clean stale lock if needed
  if _lock_is_stale "$lock_file"; then
    rm -f "$lock_file" 2>/dev/null || true
  fi

  # Check if already locked
  if [ -f "$lock_file" ]; then
    return 1
  fi

  # Atomic creation using mkdir (atomic on POSIX)
  local temp_dir="${lock_file}.d.$$"
  if mkdir "$temp_dir" 2>/dev/null; then
    # We got the atomic lock, write our claim
    echo "$$:$worker_id:$(date +%s)" > "$lock_file"
    rmdir "$temp_dir"

    # Double-check we actually own it (race condition protection)
    local owner
    owner="$(head -1 "$lock_file" 2>/dev/null | cut -d: -f1 || echo "")"
    if [ "$owner" = "$$" ]; then
      return 0  # Successfully acquired
    else
      return 1  # Lost race
    fi
  fi

  return 1  # Failed to acquire
}

# Release task lock
# Usage: task_lock_release <task_id> <worker_id>
task_lock_release() {
  local task="$1"
  local worker_id="$2"
  local lock_file
  lock_file="$(_task_lock_file "$task")"

  # Only release if we own it
  if [ -f "$lock_file" ]; then
    local owner
    owner="$(head -1 "$lock_file" 2>/dev/null | cut -d: -f1 || echo "")"
    if [ "$owner" = "$$" ]; then
      rm -f "$lock_file"
    fi
  fi
}

# Check if task is locked (by anyone)
# Usage: task_is_locked <task_id>
# Returns: 0 if locked, 1 if available
task_is_locked() {
  local task="$1"
  local lock_file
  lock_file="$(_task_lock_file "$task")"

  # Clean stale locks first
  if _lock_is_stale "$lock_file"; then
    rm -f "$lock_file" 2>/dev/null || true
    return 1  # Not locked (was stale)
  fi

  [ -f "$lock_file" ]
}

# Get lock owner for a task
# Usage: task_lock_owner <task_id>
# Outputs: worker_id or empty string
task_lock_owner() {
  local task="$1"
  local lock_file
  lock_file="$(_task_lock_file "$task")"

  if [ -f "$lock_file" ]; then
    head -1 "$lock_file" 2>/dev/null | cut -d: -f2 || true
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# EPIC LOCKING (for serialization mode)
# ──────────────────────────────────────────────────────────────────────────────

# Acquire epic lock (only used when SWARM_EPIC_SERIALIZE=1)
# Usage: epic_lock_acquire <epic_id> <worker_id>
# Returns: 0 if acquired, 1 if already locked
epic_lock_acquire() {
  local epic="$1"
  local worker_id="$2"

  [ "$SWARM_EPIC_SERIALIZE" != "1" ] && return 0  # No serialization
  [ -z "$epic" ] && return 0  # No epic = no lock needed

  local lock_file
  lock_file="$(_epic_lock_file "$epic")"

  # Clean stale lock
  if _lock_is_stale "$lock_file"; then
    rm -f "$lock_file" 2>/dev/null || true
  fi

  # Check if already locked
  if [ -f "$lock_file" ]; then
    return 1
  fi

  # Atomic creation
  local temp_dir="${lock_file}.d.$$"
  if mkdir "$temp_dir" 2>/dev/null; then
    echo "$$:$worker_id:$(date +%s)" > "$lock_file"
    rmdir "$temp_dir"

    local owner
    owner="$(head -1 "$lock_file" 2>/dev/null | cut -d: -f1 || echo "")"
    [ "$owner" = "$$" ]
  else
    return 1
  fi
}

# Release epic lock
# Usage: epic_lock_release <epic_id> <worker_id>
epic_lock_release() {
  local epic="$1"
  local worker_id="$2"

  [ "$SWARM_EPIC_SERIALIZE" != "1" ] && return 0
  [ -z "$epic" ] && return 0

  local lock_file
  lock_file="$(_epic_lock_file "$epic")"

  if [ -f "$lock_file" ]; then
    local owner
    owner="$(head -1 "$lock_file" 2>/dev/null | cut -d: -f1 || echo "")"
    if [ "$owner" = "$$" ]; then
      rm -f "$lock_file"
    fi
  fi
}

# Check if epic is locked
epic_is_locked() {
  local epic="$1"

  [ "$SWARM_EPIC_SERIALIZE" != "1" ] && return 1  # Not using serialization
  [ -z "$epic" ] && return 1

  local lock_file
  lock_file="$(_epic_lock_file "$epic")"

  if _lock_is_stale "$lock_file"; then
    rm -f "$lock_file" 2>/dev/null || true
    return 1
  fi

  [ -f "$lock_file" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# COORDINATOR LOCK
# ──────────────────────────────────────────────────────────────────────────────

# Acquire coordinator lock (only one coordinator should run)
# Usage: coordinator_lock_acquire
# Returns: 0 if acquired, 1 if already running
coordinator_lock_acquire() {
  local lock_file="$SWARM_LOCK_DIR/coordinator.lock"

  # Clean stale lock
  if _lock_is_stale "$lock_file"; then
    rm -f "$lock_file" 2>/dev/null || true
  fi

  if [ -f "$lock_file" ]; then
    return 1
  fi

  local temp_dir="${lock_file}.d.$$"
  if mkdir "$temp_dir" 2>/dev/null; then
    echo "$$:coordinator:$(date +%s)" > "$lock_file"
    rmdir "$temp_dir"

    local owner
    owner="$(head -1 "$lock_file" 2>/dev/null | cut -d: -f1 || echo "")"
    [ "$owner" = "$$" ]
  else
    return 1
  fi
}

# Release coordinator lock
coordinator_lock_release() {
  local lock_file="$SWARM_LOCK_DIR/coordinator.lock"

  if [ -f "$lock_file" ]; then
    local owner
    owner="$(head -1 "$lock_file" 2>/dev/null | cut -d: -f1 || echo "")"
    if [ "$owner" = "$$" ]; then
      rm -f "$lock_file"
    fi
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# WORKER REGISTRATION
# ──────────────────────────────────────────────────────────────────────────────

# Register a worker (for monitoring)
# Usage: worker_register <worker_id> <pid> [worktree_path]
worker_register() {
  local worker_id="$1"
  local pid="$2"
  local worktree="${3:-}"

  local worker_file="$SWARM_LOCK_DIR/workers/${worker_id}.info"
  cat > "$worker_file" <<EOF
pid:$pid
worker_id:$worker_id
worktree:$worktree
started:$(date +%s)
status:idle
current_task:
EOF
}

# Update worker status
# Usage: worker_update_status <worker_id> <status> [current_task]
worker_update_status() {
  local worker_id="$1"
  local status="$2"
  local current_task="${3:-}"

  local worker_file="$SWARM_LOCK_DIR/workers/${worker_id}.info"

  if [ -f "$worker_file" ]; then
    # Update status and current_task lines
    sed -i.bak "s/^status:.*/status:$status/" "$worker_file" 2>/dev/null || \
      sed -i '' "s/^status:.*/status:$status/" "$worker_file" 2>/dev/null || true
    sed -i.bak "s/^current_task:.*/current_task:$current_task/" "$worker_file" 2>/dev/null || \
      sed -i '' "s/^current_task:.*/current_task:$current_task/" "$worker_file" 2>/dev/null || true
    rm -f "${worker_file}.bak" 2>/dev/null || true
  fi
}

# Unregister a worker
# Usage: worker_unregister <worker_id>
worker_unregister() {
  local worker_id="$1"
  rm -f "$SWARM_LOCK_DIR/workers/${worker_id}.info"
}

# List all registered workers
# Usage: worker_list
# Outputs: worker info in JSON-ish format
worker_list() {
  local files
  files="$(ls "$SWARM_LOCK_DIR/workers"/*.info 2>/dev/null || true)"
  for f in $files; do
    [ -f "$f" ] || continue
    local worker_id pid status current_task worktree started
    worker_id="$(grep '^worker_id:' "$f" | cut -d: -f2 || true)"
    pid="$(grep '^pid:' "$f" | cut -d: -f2 || true)"
    status="$(grep '^status:' "$f" | cut -d: -f2 || true)"
    current_task="$(grep '^current_task:' "$f" | cut -d: -f2 || true)"
    worktree="$(grep '^worktree:' "$f" | cut -d: -f2 || true)"
    started="$(grep '^started:' "$f" | cut -d: -f2 || true)"

    # Check if worker is still alive
    local alive="true"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      alive="false"
    fi

    echo "{\"worker_id\":\"$worker_id\",\"pid\":$pid,\"status\":\"$status\",\"current_task\":\"$current_task\",\"worktree\":\"$worktree\",\"started\":$started,\"alive\":$alive}"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# CLEANUP
# ──────────────────────────────────────────────────────────────────────────────

# Clean all stale locks
# Usage: swarm_lock_cleanup
swarm_lock_cleanup() {
  # Clean task locks
  for f in "$SWARM_LOCK_DIR/tasks"/*.lock; do
    [ -f "$f" ] || continue
    if _lock_is_stale "$f"; then
      rm -f "$f"
    fi
  done

  # Clean epic locks
  for f in "$SWARM_LOCK_DIR/epics"/*.lock; do
    [ -f "$f" ] || continue
    if _lock_is_stale "$f"; then
      rm -f "$f"
    fi
  done

  # Clean dead worker registrations
  for f in "$SWARM_LOCK_DIR/workers"/*.info; do
    [ -f "$f" ] || continue
    local pid
    pid="$(grep '^pid:' "$f" | cut -d: -f2 || true)"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f"
    fi
  done
}

# Release all locks held by a specific worker
# Usage: swarm_release_worker_locks <worker_id>
swarm_release_worker_locks() {
  local worker_id="$1"

  # Release task locks
  for f in "$SWARM_LOCK_DIR/tasks"/*.lock; do
    [ -f "$f" ] || continue
    local owner
    owner="$(head -1 "$f" 2>/dev/null | cut -d: -f2 || echo "")"
    if [ "$owner" = "$worker_id" ]; then
      rm -f "$f"
    fi
  done

  # Release epic locks
  for f in "$SWARM_LOCK_DIR/epics"/*.lock; do
    [ -f "$f" ] || continue
    local owner
    owner="$(head -1 "$f" 2>/dev/null | cut -d: -f2 || echo "")"
    if [ "$owner" = "$worker_id" ]; then
      rm -f "$f"
    fi
  done
}

# List all locked tasks
# Usage: swarm_list_locked_tasks
swarm_list_locked_tasks() {
  for f in "$SWARM_LOCK_DIR/tasks"/*.lock; do
    [ -f "$f" ] || continue

    if _lock_is_stale "$f"; then
      continue  # Skip stale
    fi

    local task_name owner_worker lock_time
    task_name="$(basename "$f" .lock)"
    owner_worker="$(head -1 "$f" 2>/dev/null | cut -d: -f2 || echo "unknown")"
    lock_time="$(head -1 "$f" 2>/dev/null | cut -d: -f3 || echo "0")"

    echo "{\"task\":\"$task_name\",\"owner\":\"$owner_worker\",\"locked_at\":$lock_time}"
  done
}
