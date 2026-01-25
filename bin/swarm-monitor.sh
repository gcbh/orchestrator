#!/usr/bin/env bash
# swarm-monitor.sh - Monitor swarm operations
#
# Provides real-time monitoring of swarm workers, task queue, and logs.
#
# Usage:
#   ./swarm-monitor.sh              # Dashboard view (refreshes)
#   ./swarm-monitor.sh --status     # One-shot status
#   ./swarm-monitor.sh --logs       # Tail all worker logs
#   ./swarm-monitor.sh --worker 0   # Tail specific worker log
#   ./swarm-monitor.sh --queue      # Show queue status
#   ./swarm-monitor.sh --locks      # Show lock status

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

SWARM_LOCK_DIR="${SWARM_LOCK_DIR:-/tmp/swarm-locks}"
SWARM_SIZE="${SWARM_SIZE:-3}"
MAIN_REPO="${MAIN_REPO:-}"

REFRESH_INTERVAL="${REFRESH_INTERVAL:-5}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'  # No Color
BOLD='\033[1m'

# Find lib directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/../lib/orchestrator}"

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────

# Source lock/queue modules for helper functions
[ -f "$LIB_DIR/swarm_lock.sh" ] && source "$LIB_DIR/swarm_lock.sh" 2>/dev/null || true
[ -f "$LIB_DIR/swarm_queue.sh" ] && source "$LIB_DIR/swarm_queue.sh" 2>/dev/null || true

_clear_screen() {
  printf '\033[2J\033[H'
}

_move_cursor() {
  printf '\033[%d;%dH' "$1" "$2"
}

_print_header() {
  echo -e "${BOLD}${BLUE}╔═══════════════════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}${BLUE}║                       SWARM MONITOR - $(date '+%Y-%m-%d %H:%M:%S')                       ║${NC}"
  echo -e "${BOLD}${BLUE}╚═══════════════════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# COORDINATOR STATUS
# ──────────────────────────────────────────────────────────────────────────────

_get_coordinator_status() {
  local state_file="/tmp/swarm-coordinator.state"

  if [ ! -f "$state_file" ]; then
    echo "not_running"
    return
  fi

  local coord_pid
  coord_pid="$(grep '^coordinator_pid=' "$state_file" 2>/dev/null | cut -d= -f2 || echo "")"

  if [ -n "$coord_pid" ] && kill -0 "$coord_pid" 2>/dev/null; then
    echo "running"
  else
    echo "stale"
  fi
}

_print_coordinator_status() {
  local status
  status="$(_get_coordinator_status)"

  echo -e "${BOLD}COORDINATOR${NC}"
  echo "────────────────────────────────────────────────────────────────────────────────"

  case "$status" in
    running)
      local state_file="/tmp/swarm-coordinator.state"
      local pid size started workers_started workers_died

      pid="$(grep '^coordinator_pid=' "$state_file" 2>/dev/null | cut -d= -f2 || echo "?")"
      size="$(grep '^swarm_size=' "$state_file" 2>/dev/null | cut -d= -f2 || echo "?")"
      started="$(grep '^started_at=' "$state_file" 2>/dev/null | cut -d= -f2 || echo "0")"
      workers_started="$(grep '^workers_started=' "$state_file" 2>/dev/null | cut -d= -f2 || echo "0")"
      workers_died="$(grep '^workers_died=' "$state_file" 2>/dev/null | cut -d= -f2 || echo "0")"

      local uptime_secs=$(($(date +%s) - started))
      local uptime_str
      if [ "$uptime_secs" -gt 3600 ]; then
        uptime_str="$((uptime_secs / 3600))h $((uptime_secs % 3600 / 60))m"
      else
        uptime_str="$((uptime_secs / 60))m $((uptime_secs % 60))s"
      fi

      echo -e "  Status:          ${GREEN}RUNNING${NC}"
      echo "  PID:             $pid"
      echo "  Swarm Size:      $size"
      echo "  Uptime:          $uptime_str"
      echo "  Workers Started: $workers_started"
      echo "  Workers Died:    $workers_died"
      ;;
    stale)
      echo -e "  Status:          ${YELLOW}STALE${NC} (coordinator state exists but process not running)"
      ;;
    *)
      echo -e "  Status:          ${RED}NOT RUNNING${NC}"
      ;;
  esac

  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# WORKER STATUS
# ──────────────────────────────────────────────────────────────────────────────

_print_worker_status() {
  echo -e "${BOLD}WORKERS${NC}"
  echo "────────────────────────────────────────────────────────────────────────────────"

  # Detect swarm size from worker files
  local detected_size=0
  for f in "$SWARM_LOCK_DIR/workers"/worker-*.info; do
    [ -f "$f" ] || continue
    detected_size=$((detected_size + 1))
  done

  if [ "$detected_size" -eq 0 ]; then
    echo "  No workers registered"
    echo ""
    return
  fi

  printf "  ${BOLD}%-8s  %-8s  %-12s  %-15s  %s${NC}\n" "ID" "PID" "STATUS" "TASK" "WORKTREE"
  echo "  ──────────────────────────────────────────────────────────────────────────────"

  for f in "$SWARM_LOCK_DIR/workers"/worker-*.info; do
    [ -f "$f" ] || continue

    local worker_id pid status current_task worktree started
    worker_id="$(grep '^worker_id:' "$f" 2>/dev/null | cut -d: -f2 || echo "?")"
    pid="$(grep '^pid:' "$f" 2>/dev/null | cut -d: -f2 || echo "?")"
    status="$(grep '^status:' "$f" 2>/dev/null | cut -d: -f2 || echo "?")"
    current_task="$(grep '^current_task:' "$f" 2>/dev/null | cut -d: -f2 || echo "")"
    worktree="$(grep '^worktree:' "$f" 2>/dev/null | cut -d: -f2 || echo "")"

    # Check if process is alive
    local alive_status=""
    if [ -n "$pid" ] && [ "$pid" != "?" ]; then
      if kill -0 "$pid" 2>/dev/null; then
        alive_status="${GREEN}alive${NC}"
      else
        alive_status="${RED}dead${NC}"
        status="dead"
      fi
    fi

    # Color code status
    local status_color
    case "$status" in
      idle)       status_color="${CYAN}idle${NC}" ;;
      claiming)   status_color="${YELLOW}claiming${NC}" ;;
      processing) status_color="${GREEN}processing${NC}" ;;
      stopped)    status_color="${YELLOW}stopped${NC}" ;;
      dead)       status_color="${RED}dead${NC}" ;;
      *)          status_color="$status" ;;
    esac

    # Truncate worktree for display
    local wt_display
    if [ ${#worktree} -gt 30 ]; then
      wt_display="...${worktree: -27}"
    else
      wt_display="$worktree"
    fi

    printf "  %-8s  %-8s  %-23b  %-15s  %s\n" \
      "$worker_id" "$pid" "$status_color" "${current_task:-─}" "$wt_display"
  done

  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# QUEUE STATUS
# ──────────────────────────────────────────────────────────────────────────────

_print_queue_status() {
  echo -e "${BOLD}TASK QUEUE${NC}"
  echo "────────────────────────────────────────────────────────────────────────────────"

  if [ -z "$MAIN_REPO" ]; then
    echo "  MAIN_REPO not set - cannot query beads"
    echo ""
    return
  fi

  if ! command -v bd >/dev/null 2>&1; then
    echo "  beads (bd) not found"
    echo ""
    return
  fi

  # Get ready tasks
  local ready_json
  ready_json="$(cd "$MAIN_REPO" && bd ready --json 2>/dev/null || echo "[]")"

  local total_ready task_count epic_count
  total_ready="$(echo "$ready_json" | jq 'length' 2>/dev/null || echo 0)"
  task_count="$(echo "$ready_json" | jq '[.[] | select(.issue_type != "epic")] | length' 2>/dev/null || echo 0)"
  epic_count="$(echo "$ready_json" | jq '[.[] | select(.issue_type == "epic")] | length' 2>/dev/null || echo 0)"

  # Count locked tasks
  local locked_count=0
  if [ -d "$SWARM_LOCK_DIR/tasks" ]; then
    locked_count="$(ls -1 "$SWARM_LOCK_DIR/tasks"/*.lock 2>/dev/null | wc -l | tr -d ' ')"
  fi

  local claimable=$((task_count - locked_count))
  [ "$claimable" -lt 0 ] && claimable=0

  echo "  Total Ready:   $total_ready"
  echo "  Tasks:         $task_count (${GREEN}$claimable claimable${NC}, ${YELLOW}$locked_count locked${NC})"
  echo "  Epics:         $epic_count"
  echo ""

  # Show first few tasks
  if [ "$task_count" -gt 0 ]; then
    echo "  ${BOLD}Recent Tasks:${NC}"
    echo "$ready_json" | jq -r '
      [.[] | select(.issue_type != "epic")] | .[0:5] | .[] |
      "    \(.id): \(.title | if length > 50 then .[0:47] + "..." else . end)"
    ' 2>/dev/null || true
    echo ""
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# LOCK STATUS
# ──────────────────────────────────────────────────────────────────────────────

_print_lock_status() {
  echo -e "${BOLD}LOCKED TASKS${NC}"
  echo "────────────────────────────────────────────────────────────────────────────────"

  if [ ! -d "$SWARM_LOCK_DIR/tasks" ]; then
    echo "  No task locks"
    echo ""
    return
  fi

  local lock_count=0
  for f in "$SWARM_LOCK_DIR/tasks"/*.lock; do
    [ -f "$f" ] || continue
    lock_count=$((lock_count + 1))

    local task_name owner_pid owner_worker lock_time lock_age
    task_name="$(basename "$f" .lock)"
    owner_pid="$(head -1 "$f" 2>/dev/null | cut -d: -f1 || echo "?")"
    owner_worker="$(head -1 "$f" 2>/dev/null | cut -d: -f2 || echo "?")"
    lock_time="$(head -1 "$f" 2>/dev/null | cut -d: -f3 || echo "0")"
    lock_age=$(($(date +%s) - lock_time))

    local age_str
    if [ "$lock_age" -gt 3600 ]; then
      age_str="$((lock_age / 3600))h ago"
    elif [ "$lock_age" -gt 60 ]; then
      age_str="$((lock_age / 60))m ago"
    else
      age_str="${lock_age}s ago"
    fi

    # Check if owner is alive
    local alive=""
    if [ -n "$owner_pid" ] && [ "$owner_pid" != "?" ]; then
      if kill -0 "$owner_pid" 2>/dev/null; then
        alive="${GREEN}(alive)${NC}"
      else
        alive="${RED}(STALE)${NC}"
      fi
    fi

    printf "  %-20s  %-15s  %-12s  %b\n" "$task_name" "$owner_worker" "$age_str" "$alive"
  done

  if [ "$lock_count" -eq 0 ]; then
    echo "  No task locks"
  fi

  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# LOG VIEWING
# ──────────────────────────────────────────────────────────────────────────────

_tail_all_logs() {
  local log_files=()

  # Coordinator log
  if [ -f /tmp/swarm-coordinator.log ]; then
    log_files+=(/tmp/swarm-coordinator.log)
  fi

  # Worker logs
  for i in $(seq 0 $((SWARM_SIZE - 1))); do
    local log="/tmp/swarm-worker-${i}.log"
    if [ -f "$log" ]; then
      log_files+=("$log")
    fi
  done

  if [ ${#log_files[@]} -eq 0 ]; then
    echo "No log files found"
    return 1
  fi

  echo "Tailing ${#log_files[@]} log files (Ctrl+C to stop)..."
  echo ""

  # Use tail -f with multiple files
  tail -f "${log_files[@]}" 2>/dev/null
}

_tail_worker_log() {
  local worker_id="$1"
  local log="/tmp/swarm-worker-${worker_id}.log"

  if [ ! -f "$log" ]; then
    echo "Log file not found: $log"
    return 1
  fi

  echo "Tailing worker $worker_id log (Ctrl+C to stop)..."
  echo ""
  tail -f "$log"
}

_show_recent_logs() {
  local lines="${1:-20}"

  echo -e "${BOLD}RECENT LOGS${NC} (last $lines lines per worker)"
  echo "────────────────────────────────────────────────────────────────────────────────"

  for i in $(seq 0 $((SWARM_SIZE - 1))); do
    local log="/tmp/swarm-worker-${i}.log"
    if [ -f "$log" ]; then
      echo -e "${CYAN}Worker $i:${NC}"
      tail -n "$lines" "$log" 2>/dev/null | sed 's/^/  /'
      echo ""
    fi
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# DASHBOARD MODE
# ──────────────────────────────────────────────────────────────────────────────

_run_dashboard() {
  echo "Starting dashboard (refresh every ${REFRESH_INTERVAL}s, Ctrl+C to exit)..."
  sleep 1

  while true; do
    _clear_screen
    _print_header
    _print_coordinator_status
    _print_worker_status
    _print_queue_status
    _print_lock_status

    echo -e "${CYAN}Refreshing in ${REFRESH_INTERVAL}s... (Ctrl+C to exit)${NC}"
    sleep "$REFRESH_INTERVAL"
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# ONE-SHOT STATUS
# ──────────────────────────────────────────────────────────────────────────────

_show_status() {
  _print_header
  _print_coordinator_status
  _print_worker_status
  _print_queue_status
  _print_lock_status
}

# ──────────────────────────────────────────────────────────────────────────────
# USAGE
# ──────────────────────────────────────────────────────────────────────────────

_print_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Monitor swarm workers and task queue.

Options:
  (no options)         Start live dashboard (default)
  -s, --status         Show status once and exit
  -l, --logs           Tail all worker logs
  -w, --worker N       Tail specific worker log
  -q, --queue          Show detailed queue status
  -k, --locks          Show all lock status
  -r, --recent [N]     Show recent log lines (default: 20)
  -i, --interval N     Dashboard refresh interval (default: 5)
  --main-repo PATH     Set main repo for queue queries
  -h, --help           Show this help

Examples:
  # Start live dashboard
  $(basename "$0")

  # One-shot status
  $(basename "$0") --status

  # Follow all logs
  $(basename "$0") --logs

  # Follow worker 2 log
  $(basename "$0") --worker 2

Environment Variables:
  SWARM_LOCK_DIR       Lock directory (default: /tmp/swarm-locks)
  SWARM_SIZE           Number of workers to monitor
  MAIN_REPO            Main repository for beads queries
  REFRESH_INTERVAL     Dashboard refresh interval
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────

main() {
  local mode="dashboard"
  local worker_id=""

  while [ $# -gt 0 ]; do
    case "$1" in
      -s|--status)
        mode="status"
        shift
        ;;
      -l|--logs)
        mode="logs"
        shift
        ;;
      -w|--worker)
        mode="worker-log"
        worker_id="$2"
        shift 2
        ;;
      -q|--queue)
        mode="queue"
        shift
        ;;
      -k|--locks)
        mode="locks"
        shift
        ;;
      -r|--recent)
        mode="recent"
        if [ $# -gt 1 ] && [[ "$2" =~ ^[0-9]+$ ]]; then
          RECENT_LINES="$2"
          shift
        else
          RECENT_LINES=20
        fi
        shift
        ;;
      -i|--interval)
        REFRESH_INTERVAL="$2"
        shift 2
        ;;
      --main-repo)
        MAIN_REPO="$2"
        shift 2
        ;;
      --size)
        SWARM_SIZE="$2"
        shift 2
        ;;
      -h|--help)
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

  case "$mode" in
    dashboard)
      _run_dashboard
      ;;
    status)
      _show_status
      ;;
    logs)
      _tail_all_logs
      ;;
    worker-log)
      _tail_worker_log "$worker_id"
      ;;
    queue)
      _print_header
      _print_queue_status
      ;;
    locks)
      _print_header
      _print_lock_status
      ;;
    recent)
      _print_header
      _show_recent_logs "${RECENT_LINES:-20}"
      ;;
  esac
}

main "$@"
