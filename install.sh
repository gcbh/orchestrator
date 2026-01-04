#!/usr/bin/env bash
# install.sh - Install orchestrator v3.0
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "${GREEN}[install]${NC} $*"; }
warn() { echo -e "${YELLOW}[warning]${NC} $*"; }
error() { echo -e "${RED}[error]${NC} $*" >&2; }

# Check bash version (warn but don't fail for older versions)
BASH_VERSION_MAJOR="${BASH_VERSION%%.*}"
if [ "$BASH_VERSION_MAJOR" -lt 4 ]; then
  warn "Bash 4.0+ recommended (found $BASH_VERSION). Some features may not work."
  warn "On macOS: brew install bash"
fi

# Create directories
log "Creating directories..."
mkdir -p ~/.local/bin
mkdir -p ~/.local/lib/orchestrator
mkdir -p ~/.local/log

# Install main scripts
log "Installing bin scripts..."
cp "$SCRIPT_DIR/bin/orchestrator-loop.sh" ~/.local/bin/
cp "$SCRIPT_DIR/bin/fe-agent-loop.sh" ~/.local/bin/
chmod +x ~/.local/bin/orchestrator-loop.sh
chmod +x ~/.local/bin/fe-agent-loop.sh

# Install lib modules
log "Installing lib modules..."
cp "$SCRIPT_DIR/lib/orchestrator/"*.sh ~/.local/lib/orchestrator/
chmod +x ~/.local/lib/orchestrator/*.sh

# Install rules (optional)
if [ -d "$SCRIPT_DIR/rules" ]; then
  log "Installing rules..."
  
  # Agent guidelines to personal rules (stealth)
  if [ -f "$SCRIPT_DIR/rules/agent-guidelines.mdc" ]; then
    if [ -n "${MAIN_REPO:-}" ] && [ -d "$MAIN_REPO/.cursor/rules" ]; then
      mkdir -p "$MAIN_REPO/.cursor/rules/personal"
      cp "$SCRIPT_DIR/rules/agent-guidelines.mdc" "$MAIN_REPO/.cursor/rules/personal/"
      log "Installed agent-guidelines.mdc to $MAIN_REPO/.cursor/rules/personal/"
    else
      warn "Set MAIN_REPO to install agent-guidelines.mdc"
    fi
  fi
  
  # Agent debugging to shared rules
  if [ -f "$SCRIPT_DIR/rules/agent-debugging.mdc" ]; then
    if [ -n "${MAIN_REPO:-}" ] && [ -d "$MAIN_REPO/.cursor/rules" ]; then
      mkdir -p "$MAIN_REPO/.cursor/rules/shared"
      cp "$SCRIPT_DIR/rules/agent-debugging.mdc" "$MAIN_REPO/.cursor/rules/shared/"
      log "Installed agent-debugging.mdc to $MAIN_REPO/.cursor/rules/shared/"
    fi
  fi
  
  # MCP config example
  if [ -f "$SCRIPT_DIR/rules/mcp.json.example" ]; then
    if [ ! -f ~/.cursor/mcp.json ]; then
      mkdir -p ~/.cursor
      cp "$SCRIPT_DIR/rules/mcp.json.example" ~/.cursor/mcp.json
      log "Installed mcp.json to ~/.cursor/"
    else
      warn "~/.cursor/mcp.json already exists, not overwriting"
    fi
  fi
fi

# Check dependencies
log "Checking dependencies..."
MISSING=""
command -v jq >/dev/null 2>&1 || MISSING="$MISSING jq"
command -v gt >/dev/null 2>&1 || MISSING="$MISSING gt(graphite)"
command -v bd >/dev/null 2>&1 || MISSING="$MISSING bd(beads)"

if [ -n "$MISSING" ]; then
  warn "Missing dependencies:$MISSING"
  echo "  Install with:"
  echo "    brew install jq"
  echo "    npm install -g @withgraphite/graphite-cli"
  echo "    See https://github.com/steveyegge/beads for bd"
fi

# Detect OS and suggest service setup
if [[ "$OSTYPE" == "darwin"* ]]; then
  log ""
  log "=== macOS Setup ==="
  log "To run as a launchd service:"
  echo ""
  echo "1. Create plist at ~/Library/LaunchAgents/com.cursor.agent.plist"
  echo "2. Configure MAIN_REPO and EXEC_REPO in fe-agent-loop.sh"
  echo "3. Load: launchctl load ~/Library/LaunchAgents/com.cursor.agent.plist"
  echo ""
  log "Example plist:"
  cat <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.cursor.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>/Users/YOU/.local/bin/fe-agent-loop.sh</string>
    </array>
    <key>WorkingDirectory</key>
    <string>/Users/YOU/workspaces/YOUR_REPO</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/Users/YOU/.local/log/cursor-agent.log</string>
    <key>StandardErrorPath</key>
    <string>/Users/YOU/.local/log/cursor-agent.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/Users/YOU/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin</string>
        <key>HOME</key>
        <string>/Users/YOU</string>
    </dict>
</dict>
</plist>
EOF
else
  log ""
  log "=== Linux Setup ==="
  log "To run as a systemd service:"
  echo ""
  echo "1. Create service at ~/.config/systemd/user/cursor-agent.service"
  echo "2. Enable: systemctl --user enable cursor-agent"
  echo "3. Start: systemctl --user start cursor-agent"
fi

log ""
log "✓ Installation complete!"
log ""
log "Quick test:"
echo "  source ~/.local/lib/orchestrator/cli_adapter.sh"
echo "  source ~/.local/lib/orchestrator/reviewer_agent.sh"
echo "  type run_reviewer_agent"
