---
name: orch-update
description: Check orchestrator status, commit fixes, push to GitHub, and reinstall
argument-hint: "[status|commit|install|all]"
allowed-tools: Bash, Read, Glob, Grep
---

# Orchestrator Update Skill

You manage the orchestrator lifecycle: monitoring, committing improvements, pushing to GitHub, and reinstalling.

## Orchestrator Location

The orchestrator source lives at: `/Users/geoff/projects/orchestrator-v3.0`

## Available Commands

Based on `$ARGUMENTS`, perform the appropriate action:

### `/orch-update status` (default)

Check orchestrator health:
1. Show running orchestrator processes: `ps aux | grep orchestrator-loop | grep -v grep`
2. Show lock files: `ls -la /tmp/cursor-agent-*.lock`
3. Tail recent logs: `tail -20 /tmp/orchestrator-*.log`
4. Check for uncommitted changes: `cd /Users/geoff/projects/orchestrator-v3.0 && git status --short`
5. Report summary

### `/orch-update commit`

Commit and push any orchestrator changes:
1. `cd /Users/geoff/projects/orchestrator-v3.0`
2. `git status --short` - check for changes
3. If changes exist:
   - `git add -A`
   - `git diff --cached --stat` - show what will be committed
   - Ask user to confirm or provide commit message
   - `git commit -m "<message>"`
   - `git push origin main`
4. Report success/failure

### `/orch-update install`

Reinstall the orchestrator:
1. `cd /Users/geoff/projects/orchestrator-v3.0 && ./install.sh`
2. Verify installation: `ls ~/.local/lib/orchestrator/*.sh | wc -l`
3. Report installed modules

### `/orch-update all`

Full update cycle:
1. Run status check
2. If uncommitted changes, run commit flow
3. Run install
4. Report summary

## Important Notes

- Always check `git status` before committing
- Never force push
- Include `Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>` in commits
- After install, remind user to restart orchestrators if they're running

## Example Interaction

User: `/orch-update`

You should:
1. Check running processes
2. Check for uncommitted changes
3. Show recent log activity
4. Summarize health status
