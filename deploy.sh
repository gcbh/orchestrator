#!/usr/bin/env bash
# deploy.sh - Deploy orchestrator updates to local environment
#
# Usage:
#   ./deploy.sh           # Deploy to ~/.local
#   ./deploy.sh --dry-run # Show what would be deployed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log() { echo -e "${GREEN}[deploy]${NC} $*"; }
info() { echo -e "${BLUE}[info]${NC} $*"; }
warn() { echo -e "${YELLOW}[warning]${NC} $*"; }

DRY_RUN=false
if [[ "${1:-}" == "--dry-run" ]]; then
  DRY_RUN=true
  warn "DRY RUN MODE - no files will be modified"
fi

deploy_file() {
  local src="$1"
  local dest="$2"

  if [ "$DRY_RUN" = true ]; then
    info "Would copy: $src -> $dest"
    return
  fi

  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
  chmod +x "$dest" 2>/dev/null || true
  log "Deployed: $(basename "$src")"
}

log "Deploying orchestrator from $SCRIPT_DIR"
log ""

# Deploy bin scripts
log "Deploying bin scripts..."
deploy_file "$SCRIPT_DIR/bin/orchestrator-loop.sh" "$HOME/.local/bin/orchestrator-loop.sh"
deploy_file "$SCRIPT_DIR/bin/fe-agent-loop.sh" "$HOME/.local/bin/fe-agent-loop.sh"

# Deploy lib modules
log ""
log "Deploying lib modules..."
for lib_file in "$SCRIPT_DIR/lib/orchestrator/"*.sh; do
  filename="$(basename "$lib_file")"
  deploy_file "$lib_file" "$HOME/.local/lib/orchestrator/$filename"
done

if [ "$DRY_RUN" = true ]; then
  log ""
  warn "DRY RUN COMPLETE - no files were modified"
  exit 0
fi

log ""
log "✓ Deployment complete!"
log ""
info "Deployed files:"
echo "  • ~/.local/bin/orchestrator-loop.sh"
echo "  • ~/.local/bin/fe-agent-loop.sh"
echo "  • ~/.local/lib/orchestrator/*.sh ($(ls -1 "$SCRIPT_DIR/lib/orchestrator/"*.sh | wc -l | tr -d ' ') files)"
log ""
info "To restart running orchestrators:"
echo "  1. Find running processes: ps aux | grep orchestrator-loop"
echo "  2. Kill them: kill <PID>"
echo "  3. Or use: pkill -f orchestrator-loop"
echo "  4. Restart: ~/.local/bin/financial-advisor-ios-loop.sh &"
