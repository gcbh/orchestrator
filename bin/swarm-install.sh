#!/usr/bin/env bash
# swarm-install.sh - Install swarm orchestrator as a launchd service
#
# Usage:
#   ./swarm-install.sh --project ios --repo /path/to/repo --flavor ios
#   ./swarm-install.sh --project backend --repo /path/to/backend --flavor be --size 3
#   ./swarm-install.sh --uninstall --project ios
#
# Commands:
#   swarm-install.sh [options]     Install a new swarm service
#   swarm-install.sh --uninstall   Remove a swarm service
#   swarm-install.sh --list        List installed swarm services
#   swarm-install.sh --status      Show status of all swarm services

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCHESTRATOR_PATH="$(dirname "$SCRIPT_DIR")"
LAUNCHD_DIR="$HOME/Library/LaunchAgents"
TEMPLATE_PATH="$ORCHESTRATOR_PATH/launchd/com.orchestrator.swarm.plist.template"

# Defaults
PROJECT_NAME=""
MAIN_REPO=""
FLAVOR="be"
SWARM_SIZE="3"
UNINSTALL=false
LIST=false
STATUS=false

_log() {
  echo "[swarm-install] $*"
}

_error() {
  echo "[swarm-install] ERROR: $*" >&2
}

_print_usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Install or manage swarm orchestrator as a launchd service.

Options:
  -p, --project NAME     Project name (used in service label, e.g., "ios", "backend")
  -r, --repo PATH        Path to the main repository
  -f, --flavor TYPE      Orchestrator flavor: fe, be, ios (default: be)
  -s, --size N           Number of workers (default: 3)
  --uninstall            Remove the service for the specified project
  --list                 List all installed swarm services
  --status               Show status of all swarm services
  -h, --help             Show this help message

Examples:
  # Install iOS swarm with 2 workers
  $(basename "$0") -p ios -r /path/to/ios-repo -f ios -s 2

  # Install backend swarm
  $(basename "$0") -p backend -r /path/to/backend -f be

  # Check status
  $(basename "$0") --status

  # Uninstall
  $(basename "$0") --uninstall -p ios

Service Management:
  After installation, use these commands:
    launchctl load ~/Library/LaunchAgents/com.orchestrator.swarm.<project>.plist
    launchctl unload ~/Library/LaunchAgents/com.orchestrator.swarm.<project>.plist
    launchctl start com.orchestrator.swarm.<project>
    launchctl stop com.orchestrator.swarm.<project>

Monitoring:
  tail -f /tmp/swarm-<project>.log
  ./bin/swarm-monitor.sh --lock-dir /tmp/swarm-locks-<project>
EOF
}

_list_services() {
  _log "Installed swarm services:"
  local found=0
  for plist in "$LAUNCHD_DIR"/com.orchestrator.swarm.*.plist; do
    if [ -f "$plist" ]; then
      local name
      name="$(basename "$plist" .plist | sed 's/com.orchestrator.swarm.//')"
      echo "  - $name ($plist)"
      found=1
    fi
  done
  if [ "$found" -eq 0 ]; then
    echo "  (none)"
  fi
}

_show_status() {
  _log "Swarm service status:"
  for plist in "$LAUNCHD_DIR"/com.orchestrator.swarm.*.plist; do
    if [ -f "$plist" ]; then
      local label
      label="$(basename "$plist" .plist)"
      local name
      name="$(echo "$label" | sed 's/com.orchestrator.swarm.//')"

      echo ""
      echo "=== $name ==="

      # Check if loaded
      if launchctl list | grep -q "$label"; then
        local pid
        pid="$(launchctl list | grep "$label" | awk '{print $1}')"
        if [ "$pid" = "-" ]; then
          echo "  Status: Loaded but not running"
        else
          echo "  Status: Running (PID: $pid)"
        fi
      else
        echo "  Status: Not loaded"
      fi

      # Show log tail
      local log="/tmp/swarm-${name}.log"
      if [ -f "$log" ]; then
        echo "  Last activity:"
        tail -3 "$log" 2>/dev/null | sed 's/^/    /'
      fi
    fi
  done
}

_install_service() {
  if [ -z "$PROJECT_NAME" ]; then
    _error "Project name is required. Use -p or --project"
    exit 1
  fi

  if [ -z "$MAIN_REPO" ]; then
    _error "Repository path is required. Use -r or --repo"
    exit 1
  fi

  if [ ! -d "$MAIN_REPO" ]; then
    _error "Repository does not exist: $MAIN_REPO"
    exit 1
  fi

  if [ ! -f "$TEMPLATE_PATH" ]; then
    _error "Template not found: $TEMPLATE_PATH"
    exit 1
  fi

  # Create LaunchAgents directory if needed
  mkdir -p "$LAUNCHD_DIR"

  local plist_path="$LAUNCHD_DIR/com.orchestrator.swarm.${PROJECT_NAME}.plist"

  # Check if already exists
  if [ -f "$plist_path" ]; then
    _log "Service already exists. Unloading first..."
    launchctl unload "$plist_path" 2>/dev/null || true
  fi

  # Generate plist from template
  _log "Creating service for project: $PROJECT_NAME"
  _log "  Repository: $MAIN_REPO"
  _log "  Flavor: $FLAVOR"
  _log "  Workers: $SWARM_SIZE"

  sed -e "s|{{PROJECT_NAME}}|${PROJECT_NAME}|g" \
      -e "s|{{ORCHESTRATOR_PATH}}|${ORCHESTRATOR_PATH}|g" \
      -e "s|{{MAIN_REPO}}|${MAIN_REPO}|g" \
      -e "s|{{FLAVOR}}|${FLAVOR}|g" \
      -e "s|{{SWARM_SIZE}}|${SWARM_SIZE}|g" \
      -e "s|{{HOME}}|${HOME}|g" \
      "$TEMPLATE_PATH" > "$plist_path"

  _log "Created: $plist_path"

  # Load the service
  _log "Loading service..."
  launchctl load "$plist_path"

  _log ""
  _log "Service installed successfully!"
  _log ""
  _log "Commands:"
  _log "  Start:   launchctl start com.orchestrator.swarm.${PROJECT_NAME}"
  _log "  Stop:    launchctl stop com.orchestrator.swarm.${PROJECT_NAME}"
  _log "  Logs:    tail -f /tmp/swarm-${PROJECT_NAME}.log"
  _log "  Monitor: $ORCHESTRATOR_PATH/bin/swarm-monitor.sh"
}

_uninstall_service() {
  if [ -z "$PROJECT_NAME" ]; then
    _error "Project name is required for uninstall. Use -p or --project"
    exit 1
  fi

  local plist_path="$LAUNCHD_DIR/com.orchestrator.swarm.${PROJECT_NAME}.plist"
  local label="com.orchestrator.swarm.${PROJECT_NAME}"

  if [ ! -f "$plist_path" ]; then
    _error "Service not found: $plist_path"
    exit 1
  fi

  _log "Uninstalling service: $PROJECT_NAME"

  # Stop if running
  launchctl stop "$label" 2>/dev/null || true

  # Unload
  launchctl unload "$plist_path" 2>/dev/null || true

  # Remove plist
  rm -f "$plist_path"

  _log "Service uninstalled successfully"

  # Cleanup locks
  _log "Cleaning up locks..."
  rm -rf "/tmp/swarm-locks-${PROJECT_NAME}" 2>/dev/null || true
}

# Parse arguments
while [ $# -gt 0 ]; do
  case "$1" in
    -p|--project)
      PROJECT_NAME="$2"
      shift 2
      ;;
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
    --uninstall)
      UNINSTALL=true
      shift
      ;;
    --list)
      LIST=true
      shift
      ;;
    --status)
      STATUS=true
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
  _list_services
elif [ "$STATUS" = true ]; then
  _show_status
elif [ "$UNINSTALL" = true ]; then
  _uninstall_service
else
  _install_service
fi
