#!/usr/bin/env bash
# swarm-dev.sh - Run swarm in development mode (tmux or foreground)
#
# Usage:
#   ./swarm-dev.sh --repo /path/to/repo --flavor ios           # Run in tmux
#   ./swarm-dev.sh --repo /path/to/repo --flavor ios --fg      # Run in foreground
#   ./swarm-dev.sh --attach ios                                # Attach to running session
#   ./swarm-dev.sh --stop ios                                  # Stop a running session
#   ./swarm-dev.sh --list                                      # List running sessions
#
# Development mode features:
#   - Runs in tmux for easy attach/detach
#   - Verbose logging
#   - Easy to restart after code changes
#   - Split panes for logs and monitoring

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR_PATH="$(dirname "$SCRIPT_DIR")"

# Defaults
MAIN_REPO=""
FLAVOR="be"
SWARM_SIZE="1"
PROJECT_NAME=""
FOREGROUND=false
ATTACH=""
STOP=""
LIST=false

_log() {
  echo "[swarm-dev] $*"
}

_error() {
  echo "[swarm-dev] ERROR: $*" >&2
}

_print_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Run swarm orchestrator in development mode.

Options:
  -r, --repo PATH        Path to the main repository
  -f, --flavor TYPE      Orchestrator flavor: fe, be, ios (default: be)
  -s, --size N           Number of workers (default: 1 for dev)
  -p, --project NAME     Project name (auto-derived from repo if not set)
  --fg                   Run in foreground instead of tmux
  --attach NAME          Attach to an existing tmux session
  --stop NAME            Stop a running tmux session
  --list                 List running swarm dev sessions
  -h, --help             Show this help message

Examples:
  # Start iOS swarm in tmux
  $(basename "$0") -r /path/to/ios-repo -f ios

  # Start with 2 workers in foreground
  $(basename "$0") -r /path/to/repo -f be -s 2 --fg

  # Attach to running session
  $(basename "$0") --attach ios

  # Stop a session
  $(basename "$0") --stop ios

Tmux Commands (when attached):
  Ctrl+B D     Detach from session (swarm keeps running)
  Ctrl+B [     Scroll mode (q to exit)
  Ctrl+C       Stop the swarm (in main pane)
EOF
}

_get_session_name() {
  local project="$1"
  echo "swarm-dev-${project}"
}

_list_sessions() {
  _log "Running swarm dev sessions:"
  if ! command -v tmux >/dev/null 2>&1; then
    _error "tmux not installed"
    exit 1
  fi

  local found=0
  while IFS= read -r line; do
    if [[ "$line" == swarm-dev-* ]]; then
      local name="${line%%:*}"
      local project="${name#swarm-dev-}"
      echo "  - $project ($name)"
      found=1
    fi
  done < <(tmux list-sessions 2>/dev/null || true)

  if [ "$found" -eq 0 ]; then
    echo "  (none)"
  fi
}

_attach_session() {
  local project="$1"
  local session
  session="$(_get_session_name "$project")"

  if ! tmux has-session -t "$session" 2>/dev/null; then
    _error "Session not found: $session"
    _log "Run --list to see available sessions"
    exit 1
  fi

  _log "Attaching to $session..."
  exec tmux attach-session -t "$session"
}

_stop_session() {
  local project="$1"
  local session
  session="$(_get_session_name "$project")"

  if ! tmux has-session -t "$session" 2>/dev/null; then
    _error "Session not found: $session"
    exit 1
  fi

  _log "Stopping session: $session"

  # Send Ctrl+C to stop the swarm gracefully
  tmux send-keys -t "$session" C-c
  sleep 2

  # Kill the session
  tmux kill-session -t "$session" 2>/dev/null || true

  _log "Session stopped"

  # Cleanup locks
  rm -rf "/tmp/swarm-locks-${project}" 2>/dev/null || true
}

_run_foreground() {
  _log "Starting swarm in foreground mode..."
  _log "  Repository: $MAIN_REPO"
  _log "  Flavor: $FLAVOR"
  _log "  Workers: $SWARM_SIZE"
  _log ""
  _log "Press Ctrl+C to stop"
  _log ""

  cd "$ORCHESTRATOR_PATH"
  exec ./bin/swarm-loop.sh \
    --main-repo "$MAIN_REPO" \
    --flavor "$FLAVOR" \
    --size "$SWARM_SIZE"
}

_run_tmux() {
  if ! command -v tmux >/dev/null 2>&1; then
    _error "tmux not installed. Install with: brew install tmux"
    _error "Or use --fg to run in foreground"
    exit 1
  fi

  local session
  session="$(_get_session_name "$PROJECT_NAME")"

  # Check if already running
  if tmux has-session -t "$session" 2>/dev/null; then
    _log "Session already exists: $session"
    _log "Use --attach $PROJECT_NAME to attach, or --stop $PROJECT_NAME to stop first"
    exit 1
  fi

  _log "Starting swarm in tmux session: $session"
  _log "  Repository: $MAIN_REPO"
  _log "  Flavor: $FLAVOR"
  _log "  Workers: $SWARM_SIZE"

  # Create session with swarm in main pane
  tmux new-session -d -s "$session" -c "$ORCHESTRATOR_PATH" \
    "echo '=== Swarm Dev: $PROJECT_NAME ===' && echo '' && \
     ./bin/swarm-loop.sh --main-repo '$MAIN_REPO' --flavor '$FLAVOR' --size '$SWARM_SIZE'; \
     echo '' && echo 'Swarm exited. Press Enter to close.' && read"

  # Split horizontally for worker log
  tmux split-window -t "$session" -h -c "$ORCHESTRATOR_PATH" \
    "echo '=== Worker 0 Log ===' && tail -f /tmp/swarm-worker-0.log 2>/dev/null || \
     (echo 'Waiting for worker log...' && sleep 5 && tail -f /tmp/swarm-worker-0.log)"

  # Split the right pane for monitoring
  tmux split-window -t "$session" -v -c "$ORCHESTRATOR_PATH" \
    "sleep 3 && ./bin/swarm-monitor.sh --lock-dir /tmp/swarm-locks-${PROJECT_NAME} 2>/dev/null || \
     (echo 'Monitor not available' && sleep infinity)"

  # Select main pane
  tmux select-pane -t "$session:0.0"

  # Set pane titles
  tmux select-pane -t "$session:0.0" -T "Swarm"
  tmux select-pane -t "$session:0.1" -T "Worker Log"
  tmux select-pane -t "$session:0.2" -T "Monitor"

  _log ""
  _log "Swarm started in tmux session: $session"
  _log ""
  _log "Commands:"
  _log "  Attach:  $(basename "$0") --attach $PROJECT_NAME"
  _log "  Stop:    $(basename "$0") --stop $PROJECT_NAME"
  _log "  Direct:  tmux attach -t $session"
  _log ""

  # Ask if user wants to attach
  read -p "Attach to session now? [Y/n] " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Nn]$ ]]; then
    exec tmux attach-session -t "$session"
  fi
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -r|--repo)
      MAIN_REPO="$2"
      shift 2
      ;;
    -f|--flavor)
      FLAVOR="$2"
      shift 2
      ;;
    -s|--size)
      SWARM_SIZE="$2"
      shift 2
      ;;
    -p|--project)
      PROJECT_NAME="$2"
      shift 2
      ;;
    --fg)
      FOREGROUND=true
      shift
      ;;
    --attach)
      ATTACH="$2"
      shift 2
      ;;
    --stop)
      STOP="$2"
      shift 2
      ;;
    --list)
      LIST=true
      shift
      ;;
    -h|--help)
      _print_usage
      exit 0
      ;;
    *)
      _error "Unknown option: $1"
      _print_usage
      exit 1
      ;;
  esac
done

# Execute command
if [ "$LIST" = true ]; then
  _list_sessions
  exit 0
fi

if [ -n "$ATTACH" ]; then
  _attach_session "$ATTACH"
  exit 0
fi

if [ -n "$STOP" ]; then
  _stop_session "$STOP"
  exit 0
fi

# Validate required options for run
if [ -z "$MAIN_REPO" ]; then
  _error "Repository path is required. Use -r or --repo"
  _print_usage
  exit 1
fi

if [ ! -d "$MAIN_REPO" ]; then
  _error "Repository does not exist: $MAIN_REPO"
  exit 1
fi

# Auto-derive project name if not set
if [ -z "$PROJECT_NAME" ]; then
  PROJECT_NAME="$(basename "$MAIN_REPO")"
fi

# Run
if [ "$FOREGROUND" = true ]; then
  _run_foreground
else
  _run_tmux
fi
