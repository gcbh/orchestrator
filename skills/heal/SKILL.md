---
name: heal
description: Recover from stuck orchestrator states, unblock beads tasks, clean git state
argument-hint: "[full|tasks|state|stashes|diagnose]"
allowed-tools: Bash, Read, Glob, Grep
---

# Orchestrator Healing Skill

You are a recovery specialist for the orchestrator system. When invoked, help the user recover from stuck states.

## Available Commands

Based on `$ARGUMENTS`, perform the appropriate healing:

### `/heal` or `/heal full`
Run a complete system heal:
1. Source the self-healing module: `source ~/.local/lib/orchestrator/self_healing.sh`
2. Run `heal_full_system`
3. Report what was cleaned/unblocked

### `/heal tasks`
Unblock beads tasks that are stuck due to infrastructure issues:
1. Source: `source ~/.local/lib/orchestrator/self_healing.sh`
2. Run `heal_blocked_tasks`
3. Show the tasks that were unblocked

### `/heal state`
Clean dirty git working directory:
1. Source: `source ~/.local/lib/orchestrator/self_healing.sh`
2. Run `heal_dirty_state main`
3. Report what was cleaned/stashed

### `/heal stashes`
Prune old orchestrator stashes:
1. Source: `source ~/.local/lib/orchestrator/self_healing.sh`
2. First show current stashes with `git stash list`
3. Run `prune_old_stashes`
4. Show what remains

### `/heal diagnose`
Show diagnostic information without making changes:
1. Show `git status`
2. Show `git stash list`
3. Show `bd list --status blocked` (blocked beads tasks)
4. Show `gt ls` (Graphite stack)
5. Check for common issues and report findings

## Execution Steps

1. **Always start by sourcing the module:**
   ```bash
   source ~/.local/lib/orchestrator/self_healing.sh
   ```

2. **Run the appropriate function based on arguments**

3. **Report results clearly:**
   - What was the state before
   - What actions were taken
   - What is the state now
   - Any manual steps still needed

## Important Notes

- The shell functions do the heavy lifting - just call them
- Always show before/after state so user knows what changed
- If `heal_full_system` fails, try individual functions
- The module handles edge cases gracefully

## Example Interaction

User: `/heal tasks`

You should:
1. Run `bd list --status blocked` to show blocked tasks
2. Source the module and run `heal_blocked_tasks`
3. Run `bd list --status open` to show unblocked tasks
4. Summarize: "Unblocked X tasks: ios-abc, ios-def, ..."
