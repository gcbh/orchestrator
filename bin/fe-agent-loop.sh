#!/usr/bin/env bash
# fe-agent-loop.sh - Frontend agent wrapper for orchestrator-loop.sh
#
# Runs the orchestrator with FE-specific settings:
# - ORCH_FLAVOR=fe
# - MAIN_REPO: canonical pacific repo (where beads lives)
# - EXEC_REPO: pacific-agent worktree (where code changes happen)
# - BASE_BRANCH: master (pacific uses master, not main)

set -euo pipefail

export ORCH_FLAVOR="fe"
export MAIN_REPO="/Users/geoffreyheath/workspaces/pacific"
export EXEC_REPO="/Users/geoffreyheath/workspaces/pacific-agent"
export BASE_BRANCH="master"

# Logging
export LOG_FILE="${LOG_FILE:-$HOME/.local/log/fe-agent.log}"
mkdir -p "$(dirname "$LOG_FILE")"

echo "$(date): Starting FE agent loop..." | tee -a "$LOG_FILE"
exec "$HOME/.local/bin/orchestrator-loop.sh" 2>&1 | tee -a "$LOG_FILE"
