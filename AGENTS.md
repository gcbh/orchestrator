---
description: Orchestrator Meta Agent Guidelines - The Orchestrator Improving Itself
alwaysApply: true
---

# Orchestrator Meta Agent Guidelines

⚠️ **RECURSIVE AUTONOMY: The orchestrator is improving itself!**

This is the orchestrator's own codebase. You are an AI agent being orchestrated to improve the very system that's orchestrating you. Meta!

---

## CRITICAL: You Are Running in Automation Mode

**The orchestrator has ALREADY:**
- ✅ Picked up the task from beads
- ✅ Created your branch using Graphite (`gt create`)
- ✅ Checked you out to the correct branch
- ✅ Will handle PR submission and bead closure

**You are on the correct branch. Do NOT create branches or manage beads manually.**

---

## Your Job: Improve the Orchestrator

### Step 1: Read the Task
The task describes what to improve/add to the orchestrator.

### Step 2: Understand the Architecture

**Key Files:**
- `bin/orchestrator-loop.sh` - Main orchestrator state machine
- `bin/fe-agent-loop.sh` - Frontend wrapper (example)
- `lib/orchestrator/actions.sh` - Step implementations (pick, prepare, implement, etc.)
- `lib/orchestrator/validation_pipeline.sh` - Multi-stage validation
- `lib/orchestrator/cli_adapter.sh` - Cursor/Claude Code CLI abstraction
- `lib/orchestrator/reviewer_agent.sh` - Clean reviewer agent
- `lib/orchestrator/beads.sh` - Beads integration
- `lib/orchestrator/graphite.sh` - Graphite helpers
- `lib/orchestrator/worktree_manager.sh` - Git worktree management
- `deploy.sh` - Deployment script for local environments

**Flavors:**
- `fe` - Frontend (pnpm, TypeScript)
- `be` - Backend (Python, make)
- `ios` - iOS (Swift, xcodebuild, SwiftLint)

### Step 3: Make Your Changes

Edit shell scripts, add new features, fix bugs - whatever the task requires.

**Common Tasks:**
- Add new flavor support (Android, React Native, etc.)
- Add new validation stages
- Improve error handling
- Add new MCPs or integrations
- Fix bugs in state transitions
- Improve logging

### Step 4: Test Locally
```bash
# Validate shell syntax
shellcheck bin/*.sh lib/orchestrator/*.sh

# Test deployment
./deploy.sh --dry-run

# Deploy to local environment
./deploy.sh
```

### Step 5: Commit with Graphite
```bash
gt modify --no-interactive -a -m "[task-id] Brief description"
```

### Step 6: That's It!
The orchestrator (running this very code!) will:
- ✅ Validate with shellcheck
- ✅ Submit draft PR
- ✅ Close the bead
- ✅ Deploy to `~/.local` (automatically via `deploy.sh`)

---

## Orchestrator-Specific Guidelines

### Code Style
- Follow shellcheck recommendations
- Use `set -euo pipefail` in all scripts
- Prefix functions with `_` for private helpers
- Use descriptive variable names
- Add comments for complex logic

### State Machine
The orchestrator runs these steps:
```
1. PICK_TASK      - Get next ready task from beads
2. PREPARE        - Create/checkout branch via graphite
3. VALIDATE_PRE   - Baseline validation
4. IMPLEMENT      - Run implementer model
5. VALIDATE_POST  - Post-change validation
6. REVIEW         - Clean reviewer agent
7. CHECK          - Checker model verifies completeness
8. REPAIR         - Optional repair loop
9. SUBMIT         - gt submit to create/update PR
10. CLOSE         - Close beads task
```

### Adding New Flavors
To add a new flavor (e.g., `android`):

1. Add flavor logic to `bin/orchestrator-loop.sh`:
```bash
elif [ "$ORCH_FLAVOR" = "android" ]; then
  VALIDATE_CMD="${VALIDATE_CMD:-./gradlew build}"
  # Setup Android SDK paths
  export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
```

2. Add validation preset to `lib/orchestrator/validation_pipeline.sh`:
```bash
android|kotlin)
  VALIDATION_STAGES="lint typecheck test"
  LINT_CMD="./gradlew ktlintCheck"
  LINT_FIX_CMD="./gradlew ktlintFormat"
  TYPECHECK_CMD="./gradlew compileDebugKotlin"
  TEST_CMD="./gradlew testDebugUnitTest"
```

3. Test with `deploy.sh`

### Model Configuration
Models are configurable via environment variables:
- `IMPLEMENTER_MODEL` - Main implementation (default: opus-4.5-thinking)
- `CHECKER_MODEL` - Completeness check (default: gemini-3-flash, override with haiku-4.5)
- `REVIEWER_MODEL` - Code review (default: sonnet-4)
- `CLASSIFIER_MODEL` - Failure classification (default: gemini-3-flash, override with haiku-4.5)

### CLI Adapter
Supports multiple AI CLIs:
- Cursor CLI (`cursor-agent`)
- Claude Code CLI (`claude`)

The adapter automatically detects and maps model names.

---

## Validation

The orchestrator validates itself with:
- **Shellcheck**: Syntax and best practices
- **Manual testing**: Deploy script, log inspection

No automated tests yet - consider adding:
- Unit tests for individual functions
- Integration tests for full loops
- Mock beads/graphite for testing

---

## Deployment

After merging, update installations:
```bash
cd ~/projects/orchestrator-v3.0
git pull
./deploy.sh
```

This copies files to:
- `~/.local/bin/orchestrator-loop.sh`
- `~/.local/lib/orchestrator/*.sh`

Then restart running orchestrators:
```bash
pkill -f orchestrator-loop
# Restart manually or via launchd
```

---

## Debugging

If the orchestrator (running itself) breaks:
1. Check logs: `~/.local/log/orchestrator-meta.log`
2. Check task status: `bd list`
3. Check Graphite: `gt log --short`
4. Review state machine in actions.sh

**Be careful!** A bug here could break the orchestrator entirely.

---

## FORBIDDEN Commands

| Command | Why Forbidden | Use Instead |
|---------|---------------|-------------|
| `git commit` | Not tracked by Graphite | `gt modify --no-interactive -a -m "msg"` |
| `git push` | Bypasses orchestrator | Let orchestrator handle |
| `bd close` | Orchestrator closes | Let orchestrator handle |
| `gt create` | Branch already created | Already on correct branch |

---

## Success Criteria

Your task is complete when:
- ✅ Shell scripts pass shellcheck
- ✅ Deploy script runs successfully
- ✅ Changes committed via `gt modify`
- ✅ Documentation updated if needed

The orchestrator (this very code!) handles the rest.

**Remember:** You're improving the system that's running you. Test carefully!
