# Orchestrator v3.0

Unified Cursor+Beads+Graphite agent loop with:
- **Clean Reviewer Agent**: Fresh-eyes code review by a separate model
- **Validation Pipeline**: Multi-stage lint/typecheck/test with auto-fix
- **CLI Adapter**: Swappable between Cursor CLI and Claude Code CLI
- **Worktree Manager**: Per-epic git worktrees with shared node_modules
- **Self-Healing**: Automatic sync and recovery from infrastructure failures
- **Epic-based Stacking**: Branches organized as `epic/<EPIC_ID>/<TASK_ID>-<slug>`

## Quick Start

```bash
# Install
./install.sh

# Configure for frontend (macOS)
export ORCH_FLAVOR=fe
export MAIN_REPO=/path/to/your/repo
export EXEC_REPO=/path/to/your/worktree

# Start manually
~/.local/bin/fe-agent-loop.sh

# Or install as launchd service (macOS)
launchctl load ~/Library/LaunchAgents/com.cursor.agent.plist
```

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                        ORCHESTRATOR LOOP                            │
├─────────────────────────────────────────────────────────────────────┤
│  1. PICK_TASK     │ Get next ready task from Beads                  │
│  2. PREPARE       │ Create/checkout branch via Graphite             │
│  3. VALIDATE_PRE  │ Baseline typecheck/lint                         │
│  4. IMPLEMENT     │ Run implementer model (opus-4.5-thinking)       │
│  5. VALIDATE_POST │ Post-change validation                          │
│  6. REVIEW        │ Clean reviewer agent (sonnet-4) ← NEW           │
│  7. CHECK         │ Checker model verifies completeness             │
│  8. REPAIR        │ Optional repair loop if checker fails           │
│  9. SUBMIT        │ gt submit to create/update PR                   │
│ 10. CLOSE         │ Close Beads task with PR reference              │
└─────────────────────────────────────────────────────────────────────┘
```

## Configuration

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `ORCH_FLAVOR` | `be` | `fe` for frontend, `be` for backend |
| `MAIN_REPO` | - | Path to canonical repo (where Beads lives) |
| `EXEC_REPO` | `$MAIN_REPO` | Path to worktree (where code changes happen) |
| `BASE_BRANCH` | `main` | Base branch for stacking |
| `IMPLEMENTER_MODEL` | `opus-4.5-thinking` | Model for implementation |
| `CHECKER_MODEL` | `gemini-3-flash` | Model for completeness check |
| `REVIEWER_MODEL` | `sonnet-4` | Model for clean review |
| `ENABLE_REVIEWER` | `1` | Enable/disable reviewer step |
| `REVIEW_DEPTH` | `standard` | `minimal`, `standard`, or `thorough` |
| `MIN_LINES_FOR_REVIEW` | `5` | Skip review for tiny changes |
| `AGENT_CLI` | `cursor` | `cursor` or `claude-code` |

### CLI Adapter

Switch between Cursor CLI and Claude Code CLI:

```bash
# Use Cursor CLI (default)
export AGENT_CLI=cursor

# Use Claude Code CLI
export AGENT_CLI=claude-code
export CLAUDE_CODE_ARGS="--dangerously-skip-permissions"
```

## Files

```
orchestrator-v3.0/
├── bin/
│   ├── orchestrator-loop.sh   # Main orchestrator loop
│   └── fe-agent-loop.sh       # Frontend wrapper
├── lib/orchestrator/
│   ├── actions.sh             # Step implementations
│   ├── beads.sh               # Beads helpers
│   ├── cli_adapter.sh         # CLI abstraction layer
│   ├── context.sh             # Context collection
│   ├── failure_classifier.sh  # LLM failure classification
│   ├── graphite.sh            # Graphite helpers
│   ├── reconcile.sh           # Idempotency/reconciliation
│   ├── reviewer_agent.sh      # Clean reviewer agent ← NEW
│   ├── validation_pipeline.sh # Multi-stage validation ← NEW
│   └── worktree_manager.sh    # Git worktree management ← NEW
├── rules/
│   ├── agent-guidelines.mdc   # Agent behavior rules
│   ├── agent-debugging.mdc    # Debugging guide
│   └── mcp.json.example       # MCP configuration example
├── install.sh                 # Installation script
└── README.md                  # This file
```

## New in v3.0

### Clean Reviewer Agent
A separate AI model reviews changes with fresh eyes after implementation:
- No prior context from implementation
- Catches blind spots and bugs
- Configurable depth (minimal/standard/thorough)
- Optional fix loop with implementer

### Validation Pipeline
Multi-stage validation with auto-fix:
- Lint → Typecheck → Test → Self-review
- Automatic `eslint --fix` for lint errors
- Configurable presets (fe/be/minimal/full)

### CLI Adapter
Swap between AI CLIs without changing orchestrator code:
- Cursor CLI support
- Claude Code CLI support
- Automatic model name mapping
- Unified retry logic

### Worktree Manager
Efficient git worktree management:
- Per-epic worktrees
- Shared node_modules (symlinked)
- Automatic Husky disabling
- Easy cleanup

## Changelog

### v3.0 (2026-01-04)
- Added clean reviewer agent (`reviewer_agent.sh`)
- Added validation pipeline (`validation_pipeline.sh`)
- Added CLI adapter for Cursor/Claude Code swapping
- Added worktree manager for per-epic worktrees
- Fixed temp branch handling for locked base branches
- Improved self-healing and sync logic

### v2.1 (2025-12-22)
- Added self-healing infrastructure
- Fixed jq parsing for Beads JSON
- Improved Graphite tracking

### v2.0 (2025-12-20)
- State machine architecture
- LLM failure classification
- Idempotent operations
