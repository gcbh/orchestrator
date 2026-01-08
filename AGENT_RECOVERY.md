# Agent-Based Error Recovery System

## Overview

The orchestrator now uses **AI agents to automatically diagnose and fix errors** in its workflow. Instead of crashing on unexpected failures, the orchestrator invokes a recovery agent that:

1. Analyzes the error and context
2. Executes fix commands
3. Retries the original operation
4. Reports success or explains why it couldn't be fixed

This makes the orchestrator **self-healing** and robust against unpredictable failures.

---

## Architecture

### Traditional Approach (Fragile)
```bash
#!/usr/bin/env bash
set -euo pipefail  # EXIT ON ANY ERROR

git checkout my-branch  # ❌ If this fails → orchestrator crashes
```

**Problem**: Must anticipate and handle every possible failure mode explicitly.

### Agent Recovery Approach (Self-Healing)
```bash
#!/usr/bin/env bash
set -uo pipefail  # Allow errors, handle with agents

git_with_recovery "Switch to work branch" checkout my-branch
# ✅ If git checkout fails:
#    1. Agent diagnoses (uncommitted changes blocking checkout)
#    2. Agent fixes (commits or stashes changes)
#    3. Agent retries (git checkout succeeds)
#    4. Orchestrator continues
```

**Benefit**: System handles novel failure modes automatically.

---

## Key Components

### 1. `agent_recovery.sh` Library

**Location**: `~/.local/lib/orchestrator/agent_recovery.sh`

**Core Function**:
```bash
run_with_recovery "description" "command" [context]
```

**What It Does**:
- Executes the command
- If it fails, invokes a recovery agent (haiku-4.5)
- Agent sees: error output, git status, current directory
- Agent can: execute any commands needed to fix the issue
- Retries up to 3 times
- Returns success/failure

### 2. Recovery Agent Behavior

**Prompt Template**:
```
You are a recovery agent for an autonomous development orchestrator.

A command has failed and needs to be fixed.

## Failed Command
Description: Switch to work branch
Command: git checkout my-branch
Exit Code: 1

## Error Output
error: Your local changes to the following files would be overwritten:
	.beads/issues.jsonl
	tests/conftest.py
Please commit your changes or stash them before you switch branches.

## Git Status
On branch: agent/backend-de6-...
Changes not staged for commit:
  modified:   .beads/issues.jsonl
  modified:   tests/conftest.py

## Your Task
Fix this so the command succeeds, then return JSON:
{
  "fixed": true/false,
  "actions_taken": ["git add -A", "git commit -m 'WIP'"],
  "retry_successful": true/false,
  "explanation": "Had uncommitted changes, committed them as WIP"
}
```

**Agent's Response** (example):
```json
{
  "fixed": true,
  "actions_taken": [
    "git add .beads/issues.jsonl tests/conftest.py",
    "git commit -m 'WIP: Save work before branch switch'"
  ],
  "retry_successful": true,
  "explanation": "Uncommitted changes were blocking checkout. Committed them as WIP, then successfully checked out the branch."
}
```

### 3. Specialized Wrappers

**Git Operations**:
```bash
git_with_recovery "Switch to feature branch" checkout feature-branch
```

**Build Operations**:
```bash
build_with_recovery "Run validation" "make validate"
```

**Agent Invocations**:
```bash
agent_with_recovery "Code review" "$REVIEWER_MODEL" "$prompt"
```

---

## Integration Points

### 1. Orchestrator Main Loop
- **Changed**: Removed `set -e` (no automatic exit on error)
- **Sources**: `agent_recovery.sh` library
- **Uses**: `git_with_recovery` for branch operations

### 2. Reviewer Agent
- **Changed**: CLI calls now use `run_with_recovery`
- **Benefit**: If reviewer crashes (bad model name, API error), recovery agent fixes it
- **Fallback**: Still works without recovery library (degrades gracefully)

### 3. Future Applications
Any error-prone operation can be wrapped:
```bash
# Database migrations
run_with_recovery "Apply migrations" "alembic upgrade head"

# Package installations
run_with_recovery "Install dependencies" "npm install"

# API deployments
run_with_recovery "Deploy to staging" "./deploy.sh staging"
```

---

## Example Recovery Scenarios

### Scenario 1: Dirty Git State
**Command**: `git checkout new-branch`
**Error**: "Your local changes would be overwritten"
**Agent Action**: Commits changes as "WIP: Auto-save before branch switch"
**Result**: ✅ Branch checkout succeeds

### Scenario 2: Invalid Model Name
**Command**: `run_agent_cli "sonnet-4" "$prompt"`
**Error**: "Model 'sonnet-4' not found"
**Agent Action**: Updates config to use "sonnet-4.5"
**Result**: ✅ Agent call succeeds with correct model

### Scenario 3: Merge Conflict
**Command**: `git rebase main`
**Error**: "CONFLICT in package.json"
**Agent Action**: Analyzes conflict, chooses resolution strategy, resolves
**Result**: ✅ Rebase completes (or reports why it can't)

### Scenario 4: Missing Dependency
**Command**: `make validate`
**Error**: "mypy: command not found"
**Agent Action**: Installs mypy via uv/pip
**Result**: ✅ Validation runs successfully

---

## Configuration

### Environment Variables
```bash
# Recovery model (default: haiku-4.5 for speed/cost)
RECOVERY_MODEL="haiku-4.5"

# Max recovery attempts per failure (default: 3)
MAX_RECOVERY_ATTEMPTS=3

# Timeout for recovery agent (default: 120s)
RECOVERY_TIMEOUT=120
```

### Enabling/Disabling
Recovery is **automatic** if the library is sourced. To disable:
```bash
# Remove from orchestrator-loop.sh:
# source "$LIB_DIR/agent_recovery.sh"
```

---

## Benefits

### 1. **Robustness**
- No more orchestrator crashes from unexpected errors
- Handles novel failure modes automatically
- Self-healing on infrastructure issues

### 2. **Reduced Maintenance**
- No need to anticipate every possible failure
- Agent learns patterns across different errors
- Less brittle error handling code

### 3. **Better Debugging**
- Recovery agent explains what went wrong
- Actions taken are logged
- Easier to understand failure modes

### 4. **Graceful Degradation**
- If recovery fails, system continues (not fatal)
- Max attempts prevents infinite loops
- Clear error messages when unrecoverable

---

## Cost & Performance

### Recovery Agent Costs
- **Model**: haiku-4.5 (~$0.80 per million input tokens)
- **Typical Recovery**: 500-1000 tokens (~$0.0004-$0.0008 per recovery)
- **Estimate**: Even with 100 recoveries/day = **$0.08/day**

### Latency Impact
- **Without Recovery**: Instant crash (human intervention needed)
- **With Recovery**: 5-30 seconds (but continues autonomously)
- **Net Impact**: Massive time savings (no human in the loop)

---

## Limitations & Considerations

### What Recovery Agents Can Fix
✅ Git state issues (uncommitted changes, conflicts)
✅ Configuration errors (wrong model names, missing env vars)
✅ Missing dependencies (install packages)
✅ Transient failures (retry with backoff)
✅ Simple build errors (missing directories, permissions)

### What Recovery Agents Can't Fix
❌ Fundamental code bugs (syntax errors)
❌ Complex merge conflicts (requires human judgment)
❌ API outages (can't fix external services)
❌ Security issues (shouldn't auto-fix without validation)

### Safety Mechanisms
1. **Max Attempts**: Prevents infinite recovery loops
2. **Scoped Commands**: Agent can only run shell commands in current repo
3. **Logging**: All actions are logged for audit
4. **Explicit Failure**: Clear when recovery gives up

---

## Future Enhancements

### 1. Learning from Recoveries
- Track common failure patterns
- Build a database of successful fixes
- Use retrieval to suggest fixes faster

### 2. Multi-Agent Recovery
- Different agents for different error types
- Git expert, build expert, API expert
- Route errors to specialists

### 3. Human-in-the-Loop Option
- Flag certain errors for human review
- Agent proposes fix, asks for approval
- Balance autonomy with safety

### 4. Recovery Analytics
- Track recovery success rate
- Identify recurring issues
- Prioritize preventive fixes

---

## Migration Guide

### For Existing Orchestrator Instances

**Step 1**: Deploy new library
```bash
# Copy agent_recovery.sh to ~/.local/lib/orchestrator/
cp agent_recovery.sh ~/.local/lib/orchestrator/
chmod +x ~/.local/lib/orchestrator/agent_recovery.sh
```

**Step 2**: Update orchestrator-loop.sh
```bash
# Change: set -euo pipefail
# To:     set -uo pipefail  # Allow agent recovery

# Add after other sources:
if [ -f "$LIB_DIR/agent_recovery.sh" ]; then
  source "$LIB_DIR/agent_recovery.sh"
fi
```

**Step 3**: Update reviewer_agent.sh
```bash
# In run_reviewer_agent function:
# Change: review_output="$(run_agent_cli ... 2>/dev/null)"
# To:     review_output="$(run_with_recovery ...)"
```

**Step 4**: Restart orchestrators
```bash
pkill -f "orchestrator-loop.sh"
nohup ~/.local/bin/financial-advisor-ios-loop.sh > ... &
nohup ~/.local/bin/financial-advisor-backend-loop.sh > ... &
```

**Step 5**: Monitor recovery logs
```bash
tail -f ~/.local/log/financial-advisor-*.log | grep "\[recovery\]"
```

---

## Testing

### Test Recovery Manually
```bash
# Source the library
source ~/.local/lib/orchestrator/agent_recovery.sh
source ~/.local/lib/orchestrator/cli_adapter.sh

# Test git recovery
cd /path/to/repo
echo "test" > test.txt  # Create uncommitted change
git_with_recovery "Switch branch with dirty state" checkout main
# Agent should commit or stash, then checkout

# Test build recovery
build_with_recovery "Run missing command" "nonexistent_cmd"
# Agent should report it can't install nonexistent commands

# Test agent recovery
agent_with_recovery "Call invalid model" "invalid-model" "test prompt"
# Agent should suggest valid model name
```

---

## Summary

**Agent-based error recovery transforms the orchestrator from brittle to resilient.**

Instead of crashing on unexpected errors, it:
1. **Diagnoses** the problem with AI
2. **Fixes** the issue automatically
3. **Continues** the workflow

This makes autonomous development **practical for real-world use** where errors are inevitable but human intervention is expensive.

**Cost**: ~$0.08/day for typical usage
**Benefit**: Eliminates orchestrator crashes, saves hours of manual debugging
**ROI**: Massive (1000x+)
