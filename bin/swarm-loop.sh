#!/usr/bin/env bash
# swarm-loop.sh - Entry point for swarm orchestrator
#
# Runs N parallel Claude Code workers, each in isolated worktrees,
# processing tasks from the Beads queue.
#
# Usage:
#   SWARM_SIZE=3 MAIN_REPO=/path/to/repo ./swarm-loop.sh
#
#   # Or with all options
#   ./swarm-loop.sh --size 3 --main-repo /path --flavor fe --stagger 30
#
# See swarm-monitor.sh for monitoring the running swarm.

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Swarm settings
SWARM_SIZE="${SWARM_SIZE:-3}"
SWARM_STAGGER_DELAY="${SWARM_STAGGER_DELAY:-30}"
SWARM_WORKTREE_MODE="${SWARM_WORKTREE_MODE:-epic}"

# Repository settings
MAIN_REPO="${MAIN_REPO:-}"
EXEC_REPO="${EXEC_REPO:-$MAIN_REPO}"
ORCH_FLAVOR="${ORCH_FLAVOR:-be}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# Agent settings
IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-opus-4.5-thinking}"
CHECKER_MODEL="${CHECKER_MODEL:-gemini-3-flash}"
REVIEWER_MODEL="${REVIEWER_MODEL:-sonnet-4}"
AGENT_CLI="${AGENT_CLI:-auto}"

# Validation (auto-configured per flavor)
VALIDATE_CMD="${VALIDATE_CMD:-}"

# Lock settings - project-specific lock directory (set after arg parsing)
_get_project_lock_dir() {
  local repo="${MAIN_REPO:-/tmp}"
  local project_name
  project_name="$(basename "$repo")"
  echo "/tmp/swarm-locks-${project_name}"
}
# Note: SWARM_LOCK_DIR is set in main() after MAIN_REPO is known
SWARM_LOCK_DIR="${SWARM_LOCK_DIR:-}"
SWARM_LOCK_TTL_SECS="${SWARM_LOCK_TTL_SECS:-3600}"
SWARM_EPIC_SERIALIZE="${SWARM_EPIC_SERIALIZE:-0}"
SWARM_EPIC_AFFINITY="${SWARM_EPIC_AFFINITY:-1}"

# Find lib directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/../lib/orchestrator}"

# Export for workers
export SWARM_SIZE SWARM_STAGGER_DELAY SWARM_WORKTREE_MODE
export MAIN_REPO EXEC_REPO ORCH_FLAVOR BASE_BRANCH
export IMPLEMENTER_MODEL CHECKER_MODEL REVIEWER_MODEL AGENT_CLI
export SWARM_LOCK_DIR SWARM_LOCK_TTL_SECS SWARM_EPIC_SERIALIZE SWARM_EPIC_AFFINITY
export LIB_DIR

# ──────────────────────────────────────────────────────────────────────────────
# FLAVOR-SPECIFIC CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

_configure_flavor() {
  case "$ORCH_FLAVOR" in
    fe|frontend)
      VALIDATE_CMD="${VALIDATE_CMD:-pnpm run typecheck}"
      # Ensure pnpm/node are in PATH
      [ -d "$HOME/.volta/bin" ] && export PATH="$HOME/.volta/bin:$PATH"
      [ -f "$HOME/.nvm/nvm.sh" ] && source "$HOME/.nvm/nvm.sh" 2>/dev/null || true
      [ -d "$HOME/Library/pnpm" ] && export PATH="$HOME/Library/pnpm:$PATH"
      ;;

    be|backend)
      VALIDATE_CMD="${VALIDATE_CMD:-make fmt}"
      ;;

    ios|mobile)
      # Swift Package Manager projects use make build; Xcode projects use xcodebuild
      VALIDATE_CMD="${VALIDATE_CMD:-make build}"
      if command -v xcrun >/dev/null 2>&1; then
        export DEVELOPER_DIR="$(xcode-select -p)"
      fi
      ;;

    *)
      # Default to backend
      VALIDATE_CMD="${VALIDATE_CMD:-make fmt}"
      ;;
  esac

  export VALIDATE_CMD
}

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────

_log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [swarm-loop] $*"
}

_error() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [swarm-loop] ERROR: $*" >&2
}

_print_banner() {
  cat <<'EOF'
╔═══════════════════════════════════════════════════════════════════════════════╗
║                         SWARM ORCHESTRATOR v3.0                               ║
║                    Parallel Claude Code Task Processing                       ║
╚═══════════════════════════════════════════════════════════════════════════════╝
EOF
}

_print_config() {
  cat <<EOF
Configuration:
  Swarm Size:        $SWARM_SIZE workers
  Stagger Delay:     ${SWARM_STAGGER_DELAY}s between starts
  Worktree Mode:     $SWARM_WORKTREE_MODE
  Main Repo:         $MAIN_REPO
  Flavor:            $ORCH_FLAVOR
  Base Branch:       $BASE_BRANCH
  Implementer Model: $IMPLEMENTER_MODEL
  Agent CLI:         $AGENT_CLI
  Validation:        $VALIDATE_CMD
  Lock Directory:    $SWARM_LOCK_DIR
  Epic Serialize:    $SWARM_EPIC_SERIALIZE
  Epic Affinity:     $SWARM_EPIC_AFFINITY

EOF
}

_print_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Start a swarm of parallel Claude Code workers to process Beads tasks.

Options:
  -n, --size N           Number of workers (default: $SWARM_SIZE)
  -r, --main-repo PATH   Path to main repository (required)
  -f, --flavor TYPE      Orchestrator flavor: fe, be, ios (default: be)
  -s, --stagger SECS     Seconds between worker starts (default: $SWARM_STAGGER_DELAY)
  -w, --worktree MODE    Worktree mode: epic, per-worker (default: epic)
  -m, --model MODEL      Implementer model (default: opus-4.5-thinking)
  --epic-serialize       Serialize tasks within same epic (default: off)
  --no-epic-affinity     Disable epic affinity (default: on)
  -h, --help             Show this help message

Examples:
  # Start 3 workers on a backend repo
  $(basename "$0") --size 3 --main-repo /path/to/repo --flavor be

  # Start 5 workers on a frontend repo with staggered starts
  $(basename "$0") -n 5 -r /path/to/pacific -f fe -s 45

  # Monitor the running swarm
  $(dirname "$0")/swarm-monitor.sh

Environment Variables:
  SWARM_SIZE           Number of workers
  SWARM_STAGGER_DELAY  Seconds between starts
  MAIN_REPO            Main repository path
  ORCH_FLAVOR          Orchestrator flavor
  IMPLEMENTER_MODEL    Model for implementation
  VALIDATE_CMD         Override validation command
  SWARM_LOCK_DIR       Lock file directory

For monitoring, use: swarm-monitor.sh
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# VALIDATION
# ──────────────────────────────────────────────────────────────────────────────

_validate_config() {
  local errors=0

  if [ -z "$MAIN_REPO" ]; then
    _error "MAIN_REPO is required. Use --main-repo or set MAIN_REPO env var."
    errors=$((errors + 1))
  elif [ ! -d "$MAIN_REPO" ]; then
    _error "MAIN_REPO does not exist: $MAIN_REPO"
    errors=$((errors + 1))
  fi

  if [ "$SWARM_SIZE" -lt 1 ] || [ "$SWARM_SIZE" -gt 10 ]; then
    _error "SWARM_SIZE must be between 1 and 10 (got: $SWARM_SIZE)"
    errors=$((errors + 1))
  fi

  # Check for coordinator module
  if [ ! -f "$LIB_DIR/swarm_coordinator.sh" ]; then
    _error "swarm_coordinator.sh not found at: $LIB_DIR"
    errors=$((errors + 1))
  fi

  # Check for beads
  if ! command -v bd >/dev/null 2>&1; then
    _error "beads (bd) command not found in PATH"
    errors=$((errors + 1))
  fi

  # Check for git
  if ! command -v git >/dev/null 2>&1; then
    _error "git not found in PATH"
    errors=$((errors + 1))
  fi

  # Check for graphite
  if ! command -v gt >/dev/null 2>&1; then
    _log "WARNING: graphite (gt) not found - some features may not work"
  fi

  return $errors
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────

main() {
  # Parse arguments
  while [ $# -gt 0 ]; do
    case "$1" in
      -n|--size)
        SWARM_SIZE="$2"
        shift 2
        ;;
      -r|--main-repo)
        MAIN_REPO="$2"
        shift 2
        ;;
      -f|--flavor)
        ORCH_FLAVOR="$2"
        shift 2
        ;;
      -s|--stagger)
        SWARM_STAGGER_DELAY="$2"
        shift 2
        ;;
      -w|--worktree)
        SWARM_WORKTREE_MODE="$2"
        shift 2
        ;;
      -m|--model)
        IMPLEMENTER_MODEL="$2"
        shift 2
        ;;
      --epic-serialize)
        SWARM_EPIC_SERIALIZE=1
        shift
        ;;
      --no-epic-affinity)
        SWARM_EPIC_AFFINITY=0
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

  # Set project-specific lock directory now that MAIN_REPO is known
  if [ -z "$SWARM_LOCK_DIR" ]; then
    SWARM_LOCK_DIR="$(_get_project_lock_dir)"
  fi
  export SWARM_LOCK_DIR

  # Configure flavor-specific settings
  _configure_flavor

  # Print banner
  _print_banner

  # Print configuration
  _print_config

  # Validate configuration
  if ! _validate_config; then
    _error "Configuration validation failed"
    exit 1
  fi

  _log "Starting swarm coordinator..."

  # Source and run coordinator
  source "$LIB_DIR/swarm_coordinator.sh"

  if ! coordinator_init; then
    _error "Coordinator initialization failed"
    exit 1
  fi

  # Run coordinator (blocks until shutdown)
  coordinator_run
}

# Entry point
main "$@"
