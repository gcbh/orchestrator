#!/usr/bin/env bash
# swarm_coordinator.sh - Coordinator process for swarm workers
#
# Manages worker lifecycle:
# - Spawns N workers with staggered starts (rate limit friendly)
# - Monitors worker health via SIGCHLD
# - Handles graceful shutdown on Ctrl+C
# - Aggregates results and failure tracking
# - Cleans up stale locks on startup
#
# Usage:
#   SWARM_SIZE=3 MAIN_REPO=/path source swarm_coordinator.sh
#   coordinator_run
#
# Or run directly:
#   ./swarm_coordinator.sh --size 3 --main-repo /path

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

SWARM_SIZE="${SWARM_SIZE:-3}"
SWARM_STAGGER_DELAY="${SWARM_STAGGER_DELAY:-30}"
SWARM_LOCK_DIR="${SWARM_LOCK_DIR:-/tmp/swarm-locks}"
SWARM_WORKTREE_MODE="${SWARM_WORKTREE_MODE:-epic}"  # epic | per-worker

MAIN_REPO="${MAIN_REPO:-}"
ORCH_FLAVOR="${ORCH_FLAVOR:-be}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# Worker settings (passed to workers)
export IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-opus-4.5-thinking}"
export CHECKER_MODEL="${CHECKER_MODEL:-gemini-3-flash}"
export REVIEWER_MODEL="${REVIEWER_MODEL:-sonnet-4}"
export AGENT_CLI="${AGENT_CLI:-auto}"
export VALIDATE_CMD="${VALIDATE_CMD:-}"

# Coordinator state
COORDINATOR_LOG_FILE="${COORDINATOR_LOG_FILE:-/tmp/swarm-coordinator.log}"
COORDINATOR_STATE_FILE="${COORDINATOR_STATE_FILE:-/tmp/swarm-coordinator.state}"

# ──────────────────────────────────────────────────────────────────────────────
# DEPENDENCIES
# ──────────────────────────────────────────────────────────────────────────────

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Source required modules
[ -f "$LIB_DIR/swarm_lock.sh" ] && source "$LIB_DIR/swarm_lock.sh"
[ -f "$LIB_DIR/swarm_queue.sh" ] && source "$LIB_DIR/swarm_queue.sh"
[ -f "$LIB_DIR/worktree_manager.sh" ] && source "$LIB_DIR/worktree_manager.sh"

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────────────────────────────────────

_clog() {
  local msg="$(date '+%Y-%m-%d %H:%M:%S') [coordinator] $*"
  echo "$msg" | tee -a "$COORDINATOR_LOG_FILE"
}

# ──────────────────────────────────────────────────────────────────────────────
# WORKER TRACKING
# ──────────────────────────────────────────────────────────────────────────────

# Arrays for worker PIDs and worktrees
declare -a WORKER_PIDS=()
declare -a WORKER_WORKTREES=()

COORDINATOR_RUNNING=true
WORKERS_STARTED=0
WORKERS_DIED=0

# ──────────────────────────────────────────────────────────────────────────────
# SIGNAL HANDLERS
# ──────────────────────────────────────────────────────────────────────────────

# Handle SIGCHLD - a worker died
_handle_sigchld() {
  # Check which workers died
  for i in "${!WORKER_PIDS[@]}"; do
    local pid="${WORKER_PIDS[$i]}"
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      _clog "Worker $i (PID $pid) died"
      WORKERS_DIED=$((WORKERS_DIED + 1))

      # Release any locks held by this worker
      swarm_release_worker_locks "worker-$i"

      # Clear the PID
      WORKER_PIDS[$i]=""
    fi
  done
}

# Handle SIGTERM/SIGINT - graceful shutdown
_handle_shutdown() {
  _clog "Shutdown signal received, stopping workers..."
  COORDINATOR_RUNNING=false

  # Send SIGTERM to all workers
  for i in "${!WORKER_PIDS[@]}"; do
    local pid="${WORKER_PIDS[$i]}"
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      _clog "Sending SIGTERM to worker $i (PID $pid)"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done

  # Wait for workers to exit (with timeout)
  local timeout=30
  local waited=0
  while [ "$waited" -lt "$timeout" ]; do
    local all_dead=true
    for pid in "${WORKER_PIDS[@]}"; do
      if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        all_dead=false
        break
      fi
    done

    if [ "$all_dead" = "true" ]; then
      break
    fi

    sleep 1
    waited=$((waited + 1))
  done

  # Force kill any remaining
  for pid in "${WORKER_PIDS[@]}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      _clog "Force killing worker PID $pid"
      kill -9 "$pid" 2>/dev/null || true
    fi
  done

  # Cleanup
  _clog "Cleaning up locks..."
  swarm_lock_cleanup
  coordinator_lock_release

  _save_state

  _clog "Shutdown complete"
  exit 0
}

trap _handle_sigchld SIGCHLD
trap _handle_shutdown SIGTERM SIGINT

# ──────────────────────────────────────────────────────────────────────────────
# STATE PERSISTENCE
# ──────────────────────────────────────────────────────────────────────────────

_save_state() {
  cat > "$COORDINATOR_STATE_FILE" <<EOF
coordinator_pid=$$
swarm_size=$SWARM_SIZE
workers_started=$WORKERS_STARTED
workers_died=$WORKERS_DIED
started_at=$(date +%s)
last_update=$(date +%s)
EOF
}

_load_state() {
  if [ -f "$COORDINATOR_STATE_FILE" ]; then
    source "$COORDINATOR_STATE_FILE"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# WORKTREE SETUP
# ──────────────────────────────────────────────────────────────────────────────

# Setup worktree for a worker
# Usage: _setup_worker_worktree <worker_id>
# Outputs: path to worktree
_setup_worker_worktree() {
  local worker_id="$1"

  case "$SWARM_WORKTREE_MODE" in
    per-worker)
      # Each worker gets its own worktree
      if type wt_get_epic_worktree >/dev/null 2>&1; then
        wt_get_epic_worktree "worker-$worker_id"
      else
        # Fallback: create worktree manually
        local wt_path="$HOME/.local/worktrees/swarm/worker-$worker_id"
        if [ ! -d "$wt_path" ]; then
          cd "$MAIN_REPO"
          git worktree add "$wt_path" origin/master --detach 2>/dev/null || \
            git worktree add "$wt_path" origin/main --detach
        fi
        echo "$wt_path"
      fi
      ;;

    epic|shared)
      # Workers share worktrees by epic
      # Return main repo for now; worker will switch as needed
      echo "$MAIN_REPO"
      ;;

    *)
      echo "$MAIN_REPO"
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# WORKER SPAWNING
# ──────────────────────────────────────────────────────────────────────────────

# Spawn a single worker
# Usage: _spawn_worker <worker_id>
_spawn_worker() {
  local worker_id="$1"

  _clog "Spawning worker $worker_id..."

  # Setup worktree
  local worktree
  worktree="$(_setup_worker_worktree "$worker_id")"
  WORKER_WORKTREES[$worker_id]="$worktree"

  # Export worker-specific env
  export WORKER_ID="$worker_id"
  export MAIN_REPO
  export EXEC_REPO="$worktree"
  export ORCH_FLAVOR
  export BASE_BRANCH
  export LIB_DIR
  export SWARM_LOCK_DIR
  export WORKER_LOG_FILE="/tmp/swarm-worker-${worker_id}.log"

  # Spawn worker in background
  bash "$LIB_DIR/swarm_worker.sh" \
    --worker-id "$worker_id" \
    --main-repo "$MAIN_REPO" \
    --exec-repo "$worktree" \
    --flavor "$ORCH_FLAVOR" \
    >> "$WORKER_LOG_FILE" 2>&1 &

  local pid=$!
  WORKER_PIDS[$worker_id]=$pid
  WORKERS_STARTED=$((WORKERS_STARTED + 1))

  _clog "Worker $worker_id spawned (PID: $pid, worktree: $worktree)"
}

# Spawn all workers with staggered starts
_spawn_all_workers() {
  _clog "Spawning $SWARM_SIZE workers with ${SWARM_STAGGER_DELAY}s stagger..."

  for i in $(seq 0 $((SWARM_SIZE - 1))); do
    _spawn_worker "$i"

    # Stagger next start (except for last worker)
    if [ "$i" -lt $((SWARM_SIZE - 1)) ]; then
      _clog "Waiting ${SWARM_STAGGER_DELAY}s before next worker..."
      sleep "$SWARM_STAGGER_DELAY"
    fi
  done

  _clog "All workers spawned"
}

# ──────────────────────────────────────────────────────────────────────────────
# HEALTH MONITORING
# ──────────────────────────────────────────────────────────────────────────────

# Check worker health and restart if needed
_monitor_workers() {
  for i in "${!WORKER_PIDS[@]}"; do
    local pid="${WORKER_PIDS[$i]}"

    # Skip empty slots
    [ -z "$pid" ] && continue

    if ! kill -0 "$pid" 2>/dev/null; then
      _clog "Worker $i (PID $pid) is dead"

      # Check if we should restart
      # For now, don't auto-restart to avoid cascade failures
      WORKER_PIDS[$i]=""
    fi
  done
}

# Count alive workers
_count_alive_workers() {
  local count=0
  for pid in "${WORKER_PIDS[@]}"; do
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# ──────────────────────────────────────────────────────────────────────────────
# RATE LIMIT HANDLING
# ──────────────────────────────────────────────────────────────────────────────

# Global rate limit state
RATE_LIMITED=false
RATE_LIMIT_UNTIL=0

# Check if any worker hit rate limits
_check_rate_limits() {
  # Look for rate limit indicators in recent worker logs
  local rate_limit_found=false

  for i in $(seq 0 $((SWARM_SIZE - 1))); do
    local log="/tmp/swarm-worker-${i}.log"
    if [ -f "$log" ]; then
      # Check last 50 lines for rate limit errors
      if tail -50 "$log" 2>/dev/null | grep -qi "rate limit\|429\|overloaded"; then
        rate_limit_found=true
        break
      fi
    fi
  done

  if [ "$rate_limit_found" = "true" ] && [ "$RATE_LIMITED" = "false" ]; then
    _clog "Rate limit detected, coordinating backoff..."
    RATE_LIMITED=true
    RATE_LIMIT_UNTIL=$(($(date +%s) + 300))  # 5 minute backoff
  fi

  # Check if backoff period is over
  if [ "$RATE_LIMITED" = "true" ] && [ "$(date +%s)" -gt "$RATE_LIMIT_UNTIL" ]; then
    _clog "Rate limit backoff complete"
    RATE_LIMITED=false
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STATUS REPORTING
# ──────────────────────────────────────────────────────────────────────────────

# Generate status report
coordinator_status() {
  local alive
  alive="$(_count_alive_workers)"

  cat <<EOF
═══════════════════════════════════════════════════════════════════════════════
SWARM COORDINATOR STATUS
═══════════════════════════════════════════════════════════════════════════════
Coordinator PID: $$
Swarm Size:      $SWARM_SIZE
Workers Alive:   $alive
Workers Started: $WORKERS_STARTED
Workers Died:    $WORKERS_DIED
Rate Limited:    $RATE_LIMITED

WORKER STATUS:
EOF

  for i in $(seq 0 $((SWARM_SIZE - 1))); do
    local pid="${WORKER_PIDS[$i]:-}"
    local wt="${WORKER_WORKTREES[$i]:-}"
    local status="dead"

    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      status="alive"
    fi

    # Get current task from worker info file
    local current_task=""
    local worker_status="unknown"
    local info_file="$SWARM_LOCK_DIR/workers/worker-${i}.info"
    if [ -f "$info_file" ]; then
      current_task="$(grep '^current_task:' "$info_file" 2>/dev/null | cut -d: -f2 || true)"
      worker_status="$(grep '^status:' "$info_file" 2>/dev/null | cut -d: -f2 || true)"
    fi

    printf "  Worker %d: PID=%-8s Status=%-12s Task=%s\n" \
      "$i" "${pid:-N/A}" "$status/$worker_status" "${current_task:-none}"
  done

  echo ""
  echo "QUEUE STATUS:"
  if type queue_status >/dev/null 2>&1; then
    queue_status | jq -r '
      "  Ready Tasks:    \(.total_ready)",
      "  Claimable:      \(.claimable)",
      "  Locked:         \(.locked)",
      "  Epics:          \(.epics)"
    ' 2>/dev/null || echo "  (queue status unavailable)"
  fi

  echo ""
  echo "LOCKED TASKS:"
  if type swarm_list_locked_tasks >/dev/null 2>&1; then
    swarm_list_locked_tasks | while read -r line; do
      if [ -n "$line" ]; then
        local task owner
        task="$(echo "$line" | jq -r '.task')"
        owner="$(echo "$line" | jq -r '.owner')"
        echo "  $task -> $owner"
      fi
    done
  fi

  echo "═══════════════════════════════════════════════════════════════════════════════"
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN COORDINATOR LOOP
# ──────────────────────────────────────────────────────────────────────────────

coordinator_init() {
  _clog "Initializing swarm coordinator..."

  # Validate configuration
  if [ -z "$MAIN_REPO" ]; then
    _clog "ERROR: MAIN_REPO not set"
    return 1
  fi

  if [ ! -d "$MAIN_REPO" ]; then
    _clog "ERROR: MAIN_REPO does not exist: $MAIN_REPO"
    return 1
  fi

  # Initialize lock system
  swarm_lock_init

  # Acquire coordinator lock
  if ! coordinator_lock_acquire; then
    _clog "ERROR: Another coordinator is already running"
    return 1
  fi

  # Cleanup any stale locks from previous runs
  _clog "Cleaning up stale locks..."
  swarm_lock_cleanup

  # Initialize worktree manager
  if type wt_init >/dev/null 2>&1; then
    wt_init || true
  fi

  _clog "Initialization complete"
  _clog "  MAIN_REPO: $MAIN_REPO"
  _clog "  SWARM_SIZE: $SWARM_SIZE"
  _clog "  ORCH_FLAVOR: $ORCH_FLAVOR"
  _clog "  WORKTREE_MODE: $SWARM_WORKTREE_MODE"

  return 0
}

coordinator_run() {
  _clog "Starting coordinator..."

  # Spawn workers
  _spawn_all_workers

  # Save initial state
  _save_state

  # Main monitoring loop
  while [ "$COORDINATOR_RUNNING" = "true" ]; do
    # Check worker health
    _monitor_workers

    # Check for rate limits
    _check_rate_limits

    # Update state
    _save_state

    # Check if all workers are dead
    local alive
    alive="$(_count_alive_workers)"
    if [ "$alive" -eq 0 ]; then
      _clog "All workers have died, exiting"
      break
    fi

    # Sleep before next check
    sleep 10
  done

  _clog "Coordinator loop exited"
  _handle_shutdown
}

# ──────────────────────────────────────────────────────────────────────────────
# CLI ENTRY POINT
# ──────────────────────────────────────────────────────────────────────────────

_print_usage() {
  cat <<EOF
Usage: $0 [OPTIONS]

Swarm coordinator - manages parallel Claude Code workers

Options:
  --size N           Number of workers (default: 3)
  --main-repo PATH   Path to main repository
  --stagger N        Seconds between worker starts (default: 30)
  --flavor TYPE      Orchestrator flavor (fe, be, ios)
  --worktree-mode M  Worktree mode: epic, per-worker (default: epic)
  --status           Show current swarm status and exit
  --help             Show this help

Examples:
  # Start 3-worker swarm
  $0 --size 3 --main-repo /path/to/repo

  # Check status
  $0 --status

Environment Variables:
  SWARM_SIZE           Number of workers
  SWARM_STAGGER_DELAY  Seconds between starts
  MAIN_REPO            Main repository path
  ORCH_FLAVOR          fe, be, or ios
  IMPLEMENTER_MODEL    Model for implementation
  VALIDATE_CMD         Validation command
EOF
}

# Parse arguments if run directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  SHOW_STATUS=false

  while [ $# -gt 0 ]; do
    case "$1" in
      --size)
        SWARM_SIZE="$2"
        shift 2
        ;;
      --main-repo)
        MAIN_REPO="$2"
        shift 2
        ;;
      --stagger)
        SWARM_STAGGER_DELAY="$2"
        shift 2
        ;;
      --flavor)
        ORCH_FLAVOR="$2"
        shift 2
        ;;
      --worktree-mode)
        SWARM_WORKTREE_MODE="$2"
        shift 2
        ;;
      --status)
        SHOW_STATUS=true
        shift
        ;;
      --help)
        _print_usage
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        _print_usage
        exit 1
        ;;
    esac
  done

  if [ "$SHOW_STATUS" = "true" ]; then
    coordinator_status
    exit 0
  fi

  # Run coordinator
  coordinator_init || exit 1
  coordinator_run
fi
