# Orchestrator

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
orchestrator/
├── bin/
│   ├── orchestrator-loop.sh   # Main orchestrator loop
│   ├── fe-agent-loop.sh       # Frontend wrapper
│   ├── swarm-loop.sh          # Swarm entry point
│   ├── swarm-dev.sh           # Development mode (tmux)
│   ├── swarm-install.sh       # launchd service installer
│   └── swarm-monitor.sh       # Swarm monitoring
├── launchd/
│   └── com.orchestrator.swarm.plist.template  # Service template
├── lib/orchestrator/
│   ├── actions.sh             # Step implementations
│   ├── beads.sh               # Beads helpers
│   ├── cli_adapter.sh         # CLI abstraction layer
│   ├── context.sh             # Context collection
│   ├── failure_classifier.sh  # LLM failure classification
│   ├── graphite.sh            # Graphite helpers
│   ├── reconcile.sh           # Idempotency/reconciliation
│   ├── reviewer_agent.sh      # Clean reviewer agent
│   ├── swarm_coordinator.sh   # Swarm coordinator ← NEW
│   ├── swarm_lock.sh          # Per-task locking ← NEW
│   ├── swarm_queue.sh         # Task distribution ← NEW
│   ├── swarm_worker.sh        # Worker implementation ← NEW
│   ├── validation_pipeline.sh # Multi-stage validation
│   └── worktree_manager.sh    # Git worktree management
├── rules/
│   ├── agent-guidelines.mdc   # Agent behavior rules
│   ├── agent-debugging.mdc    # Debugging guide
│   └── mcp.json.example       # MCP configuration example
├── install.sh                 # Installation script
└── README.md                  # This file
```

## Features

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

### Swarm Orchestrator
Run multiple Claude Code agents in parallel:
- N parallel workers, each in isolated worktrees
- Automatic Graphite initialization in worktrees
- Staggered starts to avoid rate limits
- Task claiming with epic affinity
- Graceful shutdown with lock cleanup

## Swarm Usage

### Prerequisites

The swarm orchestrator works with the following optional dependencies:

| Tool | Required | Purpose | Fallback |
|------|----------|---------|----------|
| [Beads](https://github.com/beads-ai/beads-cli) | **Yes** | Task queue | None |
| [Graphite](https://graphite.dev/cli) | Optional | Branch stacking, PRs | Plain git + gh |
| [GitHub CLI](https://cli.github.com/) | Optional | PR creation fallback | None (Graphite required) |

**Note**: You need either Graphite OR GitHub CLI for PR creation. The swarm will automatically use Graphite if available, otherwise falls back to `gh pr create`.

### Quick Start

```bash
# Development: Run in tmux with monitoring
./bin/swarm-dev.sh -r /path/to/repo -f ios

# Production: Install as launchd service
./bin/swarm-install.sh -p ios -r /path/to/repo -f ios -s 3
launchctl start com.orchestrator.swarm.ios

# Monitor any running swarm
./bin/swarm-monitor.sh
```

### Deployment Modes

#### Development Mode (tmux)
Best for testing and debugging. Runs in a tmux session with split panes for logs and monitoring.

```bash
# Start swarm in tmux
./bin/swarm-dev.sh -r /path/to/repo -f ios

# Attach to running session
./bin/swarm-dev.sh --attach ios

# Stop session
./bin/swarm-dev.sh --stop ios

# Run in foreground (no tmux)
./bin/swarm-dev.sh -r /path/to/repo -f ios --fg
```

#### Production Mode (launchd)
Best for long-running swarms. Installs as a macOS background service.

```bash
# Install service
./bin/swarm-install.sh -p ios -r /path/to/repo -f ios -s 3

# Service management
launchctl start com.orchestrator.swarm.ios
launchctl stop com.orchestrator.swarm.ios
launchctl unload ~/Library/LaunchAgents/com.orchestrator.swarm.ios.plist

# Check status
./bin/swarm-install.sh --status

# Uninstall
./bin/swarm-install.sh --uninstall -p ios
```

### Swarm Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `SWARM_SIZE` | `3` | Number of parallel workers (1-10) |
| `SWARM_STAGGER_DELAY` | `30` | Seconds between worker starts |
| `SWARM_EPIC_SERIALIZE` | `0` | Serialize tasks within same epic |
| `SWARM_EPIC_AFFINITY` | `1` | Prefer tasks from same epic |
| `VALIDATE_CMD` | auto | Override validation command |

### Flavor Presets

| Flavor | Validation Command |
|--------|-------------------|
| `fe` | `pnpm run typecheck` |
| `be` | `make fmt` |
| `ios` | `make build` |

### Swarm Architecture

```
┌─────────────────────────────────────────────────────┐
│                   SWARM COORDINATOR                  │
├─────────────────────────────────────────────────────┤
│  - Rate limit management (staggered starts)          │
│  - Worker lifecycle management                       │
│  - Graphite auto-initialization in worktrees         │
│  - Graceful shutdown on Ctrl+C                       │
└───────────────┬─────────────────────────────────────┘
                │
      ┌─────────┼─────────┐
      ▼         ▼         ▼
┌──────────┐ ┌──────────┐ ┌──────────┐
│ WORKER 0 │ │ WORKER 1 │ │ WORKER N │
│ wt: /0   │ │ wt: /1   │ │ wt: /N   │
└────┬─────┘ └────┬─────┘ └────┬─────┘
     └────────────┼────────────┘
                  ▼
         ┌──────────────┐
         │ BEADS (bd)   │
         │ Task Queue   │
         └──────────────┘
```

## Changelog

See [GitHub Releases](https://github.com/geoffwhittington/orchestrator/releases) for full release history.

### v7.1 (2026-01-25)
- Automatic Graphite initialization in worktrees
- Fallback to plain git + GitHub CLI when Graphite unavailable
- Per-project lock directories for running multiple swarms
- Updated documentation for plug-and-play setup

### v7.0 (2026-01-25)
- Added swarm orchestrator for parallel agent execution
- Added swarm monitoring tool (`swarm-monitor.sh`)
- N parallel workers with isolated worktrees
- Staggered starts and task claiming with epic affinity

### v6.1
- Added clean reviewer agent (`reviewer_agent.sh`)
- Added validation pipeline (`validation_pipeline.sh`)
- Added CLI adapter for Cursor/Claude Code swapping
- Added worktree manager for per-epic worktrees

### v5.0
- State machine architecture
- LLM failure classification
- Idempotent operations

### v4.0
- Initial Beads + Graphite integration
- Self-healing infrastructure
