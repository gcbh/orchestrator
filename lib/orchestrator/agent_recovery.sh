#!/usr/bin/env bash
# agent_recovery.sh - Agent-based error recovery for orchestrator commands
#
# Wraps error-prone operations and uses an AI agent to diagnose and fix failures

# Recovery model (cheap, fast model for error fixes)
RECOVERY_MODEL="${RECOVERY_MODEL:-haiku-4.5}"

# Max recovery attempts
MAX_RECOVERY_ATTEMPTS="${MAX_RECOVERY_ATTEMPTS:-3}"

# Recovery timeout
RECOVERY_TIMEOUT="${RECOVERY_TIMEOUT:-120}"

_rlog() { echo "$(date): [recovery] $*" >&2; }

# Run a command with agent-based recovery on failure
# Usage: run_with_recovery "description" "command" [context]
run_with_recovery() {
  local description="$1"
  local command="$2"
  local context="${3:-}"
  local attempt=0
  
  while [ "$attempt" -lt "$MAX_RECOVERY_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    
    # Try running the command
    local output
    local exit_code
    
    if output=$(eval "$command" 2>&1); then
      exit_code=0
    else
      exit_code=$?
    fi
    
    # Success!
    if [ "$exit_code" -eq 0 ]; then
      [ "$attempt" -gt 1 ] && _rlog "Command succeeded after recovery (attempt $attempt)"
      echo "$output"
      return 0
    fi
    
    # Failed - invoke recovery agent
    _rlog "Command failed (attempt $attempt/$MAX_RECOVERY_ATTEMPTS): $description"
    _rlog "Exit code: $exit_code"
    
    # Gather context for recovery agent
    local git_status=""
    if git rev-parse --git-dir >/dev/null 2>&1; then
      git_status=$(git status 2>&1 || echo "git status failed")
    fi
    
    local current_branch=""
    current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    
    local current_dir=$(pwd)
    
    # Build recovery prompt
    local recovery_prompt
    recovery_prompt=$(cat <<RECOVERY_EOF
You are a recovery agent for an autonomous development orchestrator.

A command has failed and needs to be fixed so it can succeed.

## Failed Command
Description: $description
Command: $command
Exit Code: $exit_code

## Error Output
$output

## Current Context
Working Directory: $current_dir
Git Branch: $current_branch
${context:+Additional Context: $context}

## Git Status
$git_status

## Your Task
Diagnose the error and execute the necessary commands to fix it, then retry the original command.

Common fixes:
- Commit or stash uncommitted changes before git checkout
- Resolve merge conflicts
- Create missing directories
- Fix file permissions
- Clear locks
- Reset to clean state if needed

IMPORTANT: 
- Execute ALL fix commands needed
- Then re-run the original command to verify it works
- Report success/failure in this JSON format:

{
  "fixed": true/false,
  "actions_taken": ["action1", "action2"],
  "retry_successful": true/false,
  "explanation": "what was wrong and how you fixed it"
}

If you cannot fix it after trying, set "fixed": false and explain why.
RECOVERY_EOF
)
    
    # Call recovery agent
    _rlog "Invoking recovery agent..."
    local recovery_output
    
    if type run_agent_cli >/dev/null 2>&1; then
      recovery_output=$(run_agent_cli "$RECOVERY_MODEL" "$recovery_prompt" 2>&1 || echo '{"fixed":false,"error":"recovery agent failed"}')
    else
      _rlog "ERROR: CLI adapter not available for recovery"
      return "$exit_code"
    fi
    
    # Parse recovery result
    local fixed
    fixed=$(echo "$recovery_output" | grep -o '"fixed":\s*true' || echo "")
    
    if [ -n "$fixed" ]; then
      _rlog "Recovery agent reports: FIXED - retrying..."
      # Loop will retry the command
      continue
    else
      _rlog "Recovery agent could not fix the error"
      local explanation
      explanation=$(echo "$recovery_output" | grep -o '"explanation":"[^"]*"' | cut -d'"' -f4)
      [ -n "$explanation" ] && _rlog "Explanation: $explanation"
      
      # Give up after max attempts
      if [ "$attempt" -ge "$MAX_RECOVERY_ATTEMPTS" ]; then
        _rlog "Max recovery attempts reached, giving up"
        return "$exit_code"
      fi
    fi
  done
  
  return 1
}

# Wrapper for git operations with recovery
git_with_recovery() {
  local description="$1"
  shift
  local git_command="git $*"
  
  run_with_recovery "$description" "$git_command" "Git operation"
}

# Wrapper for make/build operations with recovery
build_with_recovery() {
  local description="$1"
  local build_command="$2"
  
  run_with_recovery "$description" "$build_command" "Build operation"
}

# Wrapper for agent CLI calls with recovery
agent_with_recovery() {
  local description="$1"
  local model="$2"
  local prompt="$3"
  
  local agent_command="run_agent_cli '$model' '$prompt'"
  run_with_recovery "$description" "$agent_command" "Agent invocation"
}

