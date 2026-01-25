#!/usr/bin/env bash
# swarm_worker.sh - Individual swarm worker implementation
#
# A worker runs in its own worktree and processes tasks from the queue.
# Workers are persistent - they run until shutdown, avoiding worktree setup overhead.
#
# Usage:
#   WORKER_ID=0 MAIN_REPO=/path EXEC_REPO=/path/worktree source swarm_worker.sh
#   worker_run_loop
#
# Or run directly:
#   ./swarm_worker.sh --worker-id 0 --main-repo /path --exec-repo /path/worktree

set -uo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

WORKER_ID="${WORKER_ID:-0}"
MAIN_REPO="${MAIN_REPO:-}"
EXEC_REPO="${EXEC_REPO:-}"
ORCH_FLAVOR="${ORCH_FLAVOR:-be}"
BASE_BRANCH="${BASE_BRANCH:-main}"

# Agent settings
IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-opus-4.5-thinking}"
CHECKER_MODEL="${CHECKER_MODEL:-gemini-3-flash}"
REVIEWER_MODEL="${REVIEWER_MODEL:-sonnet-4}"
AGENT_CLI="${AGENT_CLI:-auto}"

# Timeouts and retries
MAX_AGENT_RETRIES="${MAX_AGENT_RETRIES:-10}"
AGENT_TIMEOUT_SECS="${AGENT_TIMEOUT_SECS:-1800}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-60}"
BACKOFF_MULTIPLIER="${BACKOFF_MULTIPLIER:-2}"
MAX_DELAY_SECS="${MAX_DELAY_SECS:-600}"

# Worker loop settings
WORKER_SLEEP_SECS="${WORKER_SLEEP_SECS:-30}"
WORKER_IDLE_SLEEP_SECS="${WORKER_IDLE_SLEEP_SECS:-60}"

# Validation
VALIDATE_CMD="${VALIDATE_CMD:-}"
ENABLE_CHECKER="${ENABLE_CHECKER:-1}"
ENABLE_REVIEWER="${ENABLE_REVIEWER:-1}"

# Graphite args
GT_CREATE_ARGS=(--no-interactive -a)
GT_MODIFY_ARGS=(--no-interactive -a)
GT_SUBMIT_ARGS=(--no-interactive --draft --no-edit --ai)

# ──────────────────────────────────────────────────────────────────────────────
# DEPENDENCIES
# ──────────────────────────────────────────────────────────────────────────────

LIB_DIR="${LIB_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# Source required modules
[ -f "$LIB_DIR/swarm_lock.sh" ] && source "$LIB_DIR/swarm_lock.sh"
[ -f "$LIB_DIR/swarm_queue.sh" ] && source "$LIB_DIR/swarm_queue.sh"
[ -f "$LIB_DIR/cli_adapter.sh" ] && source "$LIB_DIR/cli_adapter.sh"
[ -f "$LIB_DIR/beads.sh" ] && source "$LIB_DIR/beads.sh"
[ -f "$LIB_DIR/reconcile.sh" ] && source "$LIB_DIR/reconcile.sh"
[ -f "$LIB_DIR/self_healing.sh" ] && source "$LIB_DIR/self_healing.sh"
[ -f "$LIB_DIR/reviewer_agent.sh" ] && source "$LIB_DIR/reviewer_agent.sh"
[ -f "$LIB_DIR/validation_pipeline.sh" ] && source "$LIB_DIR/validation_pipeline.sh"

# Disable husky
export HUSKY="${HUSKY:-0}"

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────────────────────────────────────

WORKER_LOG_FILE="${WORKER_LOG_FILE:-/tmp/swarm-worker-${WORKER_ID}.log}"

_wlog() {
  local msg="$(date '+%Y-%m-%d %H:%M:%S') [worker-$WORKER_ID] $*"
  echo "$msg" | tee -a "$WORKER_LOG_FILE" >&2
}

_wlog_task() {
  local task="$1"; shift
  local msg="$(date '+%Y-%m-%d %H:%M:%S') [worker-$WORKER_ID] [$task] $*"
  echo "$msg" | tee -a "$WORKER_LOG_FILE" >&2
}

# ──────────────────────────────────────────────────────────────────────────────
# WORKER STATE
# ──────────────────────────────────────────────────────────────────────────────

WORKER_LAST_EPIC=""
WORKER_CURRENT_TASK=""
WORKER_TASKS_COMPLETED=0
WORKER_TASKS_FAILED=0
WORKER_RUNNING=true

# Signal handler
_worker_shutdown() {
  _wlog "Shutdown signal received"
  WORKER_RUNNING=false

  # Release any held locks
  if [ -n "$WORKER_CURRENT_TASK" ]; then
    _wlog "Releasing lock for $WORKER_CURRENT_TASK"
    queue_release_task "$WORKER_CURRENT_TASK" "worker-$WORKER_ID" "$WORKER_LAST_EPIC"
  fi

  worker_update_status "worker-$WORKER_ID" "stopped" ""
}

trap _worker_shutdown SIGTERM SIGINT

# ──────────────────────────────────────────────────────────────────────────────
# GIT HELPERS
# ──────────────────────────────────────────────────────────────────────────────

_slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/^-//; s/-$//' \
    | cut -c1-60
}

_sanitize_id() {
  echo "$1" | sed 's/[^a-zA-Z0-9._\/-]/-/g'
}

_stage_safely() {
  if git add -A -- \
      ":(exclude).beads" \
      ":(exclude).claude" \
      ":(exclude).cursor/rules/personal" \
      >/dev/null 2>&1; then
    return 0
  fi
  git add -A
  git reset HEAD .beads/ .claude/ .cursor/rules/personal/ 2>/dev/null || true
}

_count_changes() {
  local uncommitted new_commits
  uncommitted=$(git status --porcelain \
    | grep -v '\.beads/' \
    | grep -v '\.claude/' \
    | grep -v '\.cursor/rules/personal/' \
    | wc -l | tr -d ' ')

  new_commits=0
  if [ -n "${BASELINE_HEAD:-}" ]; then
    new_commits=$(git rev-list --count "${BASELINE_HEAD}..HEAD" 2>/dev/null || echo 0)
  fi

  echo $((uncommitted + new_commits))
}

_run_validate() {
  if [ -z "$VALIDATE_CMD" ]; then
    return 0
  fi
  bash -c "$VALIDATE_CMD"
}

# ──────────────────────────────────────────────────────────────────────────────
# BRANCH HELPERS
# ──────────────────────────────────────────────────────────────────────────────

_find_task_branch() {
  local epic="$1" task="$2"
  local e t
  e="$(_sanitize_id "$epic")"
  t="$(_sanitize_id "$task")"

  git fetch origin --quiet 2>/dev/null || true

  # Try epic namespace
  local branch
  branch="$(git for-each-ref --format='%(refname:short)' "refs/remotes/origin/epic/$e/" 2>/dev/null \
    | grep -i "$t" \
    | head -1 \
    | sed 's|^origin/||')" || true

  # Fallback to flat branches
  if [ -z "$branch" ]; then
    branch="$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ 2>/dev/null \
      | grep -E "^origin/.*${t}" \
      | head -1 \
      | sed 's|^origin/||')" || true
  fi

  echo "$branch"
}

_find_epic_tip() {
  local epic="$1"
  local e
  e="$(_sanitize_id "$epic")"

  git fetch origin --quiet 2>/dev/null || true
  git for-each-ref --sort=-committerdate --format='%(refname:short)' "refs/remotes/origin/epic/$e/" 2>/dev/null \
    | head -1 \
    | sed 's|^origin/||' || true
}

_find_parent_branch() {
  local epic="$1" task="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"

  # Get dependencies
  local deps
  deps="$(cd "$main_repo" && bd show "$task" 2>/dev/null | grep -E '→ ' | sed 's/.*→ //' | cut -d: -f1 | tr -d ' ' || true)"

  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    local branch
    branch="$(_find_task_branch "$epic" "$dep")"
    if [ -n "$branch" ]; then
      echo "$branch"
      return 0
    fi
  done <<< "$deps"

  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# PROMPT BUILDERS
# ──────────────────────────────────────────────────────────────────────────────

_build_implementer_prompt() {
  local task="$1" title="$2" details="$3" branch="$4"

  cat <<EOF
You are implementing Beads task $task.

TASK: $title

FULL TASK DETAILS:
$details

═══════════════════════════════════════════════════════════════════════════════
BRANCH SETUP (ALREADY DONE BY ORCHESTRATOR)
═══════════════════════════════════════════════════════════════════════════════
You are on branch: $branch
This branch is tracked by Graphite and stacked correctly.

═══════════════════════════════════════════════════════════════════════════════
CRITICAL RULES - NEVER VIOLATE
═══════════════════════════════════════════════════════════════════════════════

FORBIDDEN COMMANDS (will break the workflow):
- git commit, git checkout, git branch, git push
- gt create (branch already created)
- bd close (orchestrator closes beads)

REQUIRED WORKFLOW:
1. Make your code changes
2. Run: make fmt (to fix formatting)
3. Stage changes: git add -A
4. Commit with: gt modify --no-interactive -a -m "[$task] $title"
5. Push and create PR: gt submit --no-interactive --draft --no-edit --ai

Do NOT touch files in: .beads/, .claude/, .cursor/rules/personal/

═══════════════════════════════════════════════════════════════════════════════
ALLOWED
═══════════════════════════════════════════════════════════════════════════════
- Make code changes (edit files, create files)
- Run build/lint/test commands to verify your work
- Create follow-up beads for discovered work:
  bd create --title "..." --description "..." --issue_type task --priority 3
  bd dep <new-id> $task --dep_type discovered-from

═══════════════════════════════════════════════════════════════════════════════
IF BLOCKED
═══════════════════════════════════════════════════════════════════════════════
Output exactly:
STATUS: BLOCKED
REASON: <one paragraph>
QUESTIONS:
- <up to 3 concrete questions>
EOF
}

_agent_reported_blocked() {
  local out="$1"
  echo "$out" | grep -q "^STATUS: BLOCKED"
}

# ──────────────────────────────────────────────────────────────────────────────
# AGENT INVOCATION
# ──────────────────────────────────────────────────────────────────────────────

_run_agent_with_retries() {
  local model="$1"
  local prompt="$2"

  if type run_agent_cli >/dev/null 2>&1; then
    local prefix=""
    if type get_cli_prompt_prefix >/dev/null 2>&1; then
      prefix="$(get_cli_prompt_prefix)"
    fi
    local full_prompt="${prefix}${prompt}"

    local attempt=0
    local delay="$RETRY_DELAY_SECS"
    local out="" code=0

    while [ "$attempt" -lt "$MAX_AGENT_RETRIES" ]; do
      _wlog "Agent attempt $((attempt+1))/$MAX_AGENT_RETRIES (model=$model)"

      set +e
      out="$(run_agent_cli "$model" "$full_prompt")"
      code=$?
      set -e

      if [ "$code" -eq 0 ]; then
        printf "%s" "$out"
        return 0
      fi

      if [ "$code" -eq 124 ] || echo "$out" | grep -qi "provider\|rate limit\|503\|502\|500\|timeout\|overloaded\|capacity"; then
        attempt=$((attempt + 1))
        _wlog "Retryable error. Sleeping ${delay}s."
        sleep "$delay"
        delay=$((delay * BACKOFF_MULTIPLIER))
        [ "$delay" -gt "$MAX_DELAY_SECS" ] && delay="$MAX_DELAY_SECS"
        continue
      fi

      printf "%s" "$out"
      return "$code"
    done

    printf "%s" "$out"
    return 1
  fi

  # No CLI adapter
  _wlog "ERROR: run_agent_cli not available"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# TASK PROCESSING
# ──────────────────────────────────────────────────────────────────────────────

# Process a single task
# Usage: worker_process_task <task_id> <epic_id>
# Returns: 0 on success, 1 on failure
worker_process_task() {
  local task="$1"
  local epic_id="${2:-}"

  WORKER_CURRENT_TASK="$task"
  worker_update_status "worker-$WORKER_ID" "processing" "$task"

  _wlog_task "$task" "Starting task processing"

  # Get task details
  local main_repo="${MAIN_REPO:-$(pwd)}"
  local title details
  title="$(cd "$main_repo" && bd show "$task" --json 2>/dev/null | jq -r '.[0].title // ""' || true)"
  details="$(cd "$main_repo" && bd show "$task" 2>/dev/null || true)"

  _wlog_task "$task" "Title: $title"

  cd "$EXEC_REPO" || { _wlog_task "$task" "ERROR: Cannot cd to EXEC_REPO"; return 1; }

  # Mark in_progress
  queue_mark_in_progress "$task"

  # Fetch latest
  git fetch origin --quiet 2>/dev/null || true

  # Determine branch strategy
  local existing_branch=""
  if [ -n "$epic_id" ]; then
    existing_branch="$(_find_task_branch "$epic_id" "$task")"
  fi

  local desired_branch parent_branch
  local clean_title task_id_clean commit_msg

  clean_title="$(_slugify "$title")"
  task_id_clean="$(_sanitize_id "$task")"
  commit_msg="[$task] $title"

  if [ -n "$epic_id" ]; then
    local epic_clean
    epic_clean="$(_sanitize_id "$epic_id")"
    desired_branch="epic/${epic_clean}/${task_id_clean}-${clean_title}"
  else
    desired_branch="agent/${task_id_clean}-${clean_title}"
  fi

  parent_branch="$BASE_BRANCH"

  if [ -n "$existing_branch" ]; then
    _wlog_task "$task" "Using existing branch: $existing_branch"
    gt checkout "$existing_branch" --no-interactive 2>/dev/null || \
      git checkout "$existing_branch" 2>/dev/null || \
      git checkout -b "$existing_branch" "origin/$existing_branch" || \
      { _wlog_task "$task" "ERROR: Cannot checkout $existing_branch"; return 1; }
    git pull origin "$existing_branch" --rebase 2>/dev/null || true
  else
    # Find parent branch
    if [ -n "$epic_id" ]; then
      local dep_parent
      dep_parent="$(_find_parent_branch "$epic_id" "$task")"
      if [ -n "$dep_parent" ]; then
        parent_branch="$dep_parent"
      else
        local tip
        tip="$(_find_epic_tip "$epic_id")"
        [ -n "$tip" ] && parent_branch="$tip"
      fi
    fi

    _wlog_task "$task" "Creating branch $desired_branch from $parent_branch"

    # Checkout parent
    gt checkout "$parent_branch" --no-interactive 2>/dev/null || \
      git checkout "$parent_branch" 2>/dev/null || \
      { _wlog_task "$task" "ERROR: Cannot checkout $parent_branch"; return 1; }

    git pull origin "$parent_branch" --rebase 2>/dev/null || true

    # Create branch - try Graphite first, fall back to plain git
    if command -v gt >/dev/null 2>&1 && gt create "${GT_CREATE_ARGS[@]}" "$desired_branch" -m "[$task] WIP" 2>/dev/null; then
      _wlog_task "$task" "Branch created via Graphite"
    elif git checkout -b "$desired_branch" 2>/dev/null; then
      _wlog_task "$task" "Branch created via git (Graphite unavailable)"
    else
      _wlog_task "$task" "ERROR: Failed to create branch $desired_branch"
      queue_mark_blocked "$task" "Failed to create branch $desired_branch"
      return 1
    fi
  fi

  # Baseline validation
  _wlog_task "$task" "Running baseline validation..."
  if ! _run_validate 2>&1 | tee /tmp/swarm-worker-${WORKER_ID}-validate.log; then
    _wlog_task "$task" "Baseline validation failed"
    local tailmsg
    tailmsg="$(tail -100 /tmp/swarm-worker-${WORKER_ID}-validate.log | tr '\n' ' ')"
    queue_mark_blocked "$task" "Baseline validation failed: $tailmsg"
    return 1
  fi

  # Capture baseline HEAD
  BASELINE_HEAD="$(git rev-parse HEAD)"
  export BASELINE_HEAD

  # Build and run agent
  local current_branch
  current_branch="${existing_branch:-$desired_branch}"
  local prompt
  prompt="$(_build_implementer_prompt "$task" "$title" "$details" "$current_branch")"

  _wlog_task "$task" "Running implementer agent..."
  local agent_out
  agent_out="$(_run_agent_with_retries "$IMPLEMENTER_MODEL" "$prompt" 2>&1)" || true

  # Check if blocked
  if _agent_reported_blocked "$agent_out"; then
    _wlog_task "$task" "Agent reported BLOCKED"
    local block_reason
    block_reason="$(echo "$agent_out" | tail -120 | tr '\n' ' ')"
    queue_mark_blocked "$task" "$block_reason"
    return 1
  fi

  # Check for changes
  if [ "$(_count_changes)" -eq 0 ]; then
    _wlog_task "$task" "No changes produced"
    queue_mark_blocked "$task" "Agent produced no changes"
    return 1
  fi

  # Post-change validation
  _wlog_task "$task" "Running post-change validation..."
  if ! _run_validate 2>&1 | tee /tmp/swarm-worker-${WORKER_ID}-validate.log; then
    _wlog_task "$task" "Post-change validation failed"
    local tailmsg
    tailmsg="$(tail -100 /tmp/swarm-worker-${WORKER_ID}-validate.log | tr '\n' ' ')"
    git stash push -m "validate-failed-$task-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
    queue_mark_blocked "$task" "Post-change validation failed: $tailmsg"
    return 1
  fi

  # Commit if needed
  local uncommitted
  uncommitted="$(git status --porcelain | grep -v '\.beads/' | grep -v '\.claude/' | grep -v '\.cursor/rules/personal/' | wc -l | tr -d ' ')"

  if [ "$uncommitted" -gt 0 ]; then
    _wlog_task "$task" "Committing $uncommitted files..."
    _stage_safely
    # Try Graphite first, fall back to plain git commit
    if command -v gt >/dev/null 2>&1 && gt modify "${GT_MODIFY_ARGS[@]}" -m "$commit_msg" 2>/dev/null; then
      _wlog_task "$task" "Changes committed via Graphite"
    elif git commit -m "$commit_msg" 2>/dev/null; then
      _wlog_task "$task" "Changes committed via git"
    else
      _wlog_task "$task" "ERROR: Failed to commit changes"
      queue_mark_blocked "$task" "Commit failed"
      return 1
    fi
  fi

  # Submit PR - try Graphite first, fall back to GitHub CLI
  _wlog_task "$task" "Submitting PR..."
  local pr_out pr_code pr_num
  local current_branch
  current_branch="$(git branch --show-current)"

  # Push changes first (needed for gh pr create)
  git push -u origin "$current_branch" 2>/dev/null || git push origin "$current_branch" 2>/dev/null || true

  set +e
  if command -v gt >/dev/null 2>&1; then
    pr_out="$(gt submit "${GT_SUBMIT_ARGS[@]}" 2>&1)"
    pr_code=$?
    if [ "$pr_code" -eq 0 ]; then
      _wlog_task "$task" "PR submitted via Graphite"
    fi
  else
    pr_code=1  # Force fallback to gh
  fi

  # Fallback to GitHub CLI
  if [ "$pr_code" -ne 0 ]; then
    _wlog_task "$task" "Trying GitHub CLI fallback..."
    pr_out="$(gh pr create --draft --title "[$task] $title" --body "Auto-generated PR for $task" 2>&1)"
    pr_code=$?
    if [ "$pr_code" -eq 0 ]; then
      _wlog_task "$task" "PR submitted via GitHub CLI"
    fi
  fi
  set -e

  if [ "$pr_code" -ne 0 ]; then
    _wlog_task "$task" "ERROR: PR submission failed"
    queue_mark_blocked "$task" "PR submission failed: $(echo "$pr_out" | tail -50 | tr '\n' ' ')"
    return 1
  fi

  pr_num="$(echo "$pr_out" | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)"

  # Close task
  if [ -n "$pr_num" ]; then
    _wlog_task "$task" "SUCCESS: PR #$pr_num created"
    queue_close_task "$task" "Completed in PR #$pr_num"
    WORKER_TASKS_COMPLETED=$((WORKER_TASKS_COMPLETED + 1))
    WORKER_LAST_EPIC="$epic_id"
  else
    _wlog_task "$task" "WARNING: PR created but number not captured"
    queue_mark_blocked "$task" "PR submitted but number not captured"
    return 1
  fi

  WORKER_CURRENT_TASK=""
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# WORKER LOOP
# ──────────────────────────────────────────────────────────────────────────────

# Initialize worker
worker_init() {
  _wlog "Initializing worker-$WORKER_ID"

  # Validate configuration
  if [ -z "$MAIN_REPO" ]; then
    _wlog "ERROR: MAIN_REPO not set"
    return 1
  fi

  if [ -z "$EXEC_REPO" ]; then
    _wlog "ERROR: EXEC_REPO not set"
    return 1
  fi

  # Initialize locks
  swarm_lock_init

  # Register worker
  worker_register "worker-$WORKER_ID" "$$" "$EXEC_REPO"
  worker_update_status "worker-$WORKER_ID" "idle" ""

  # Validate CLI
  if type validate_agent_cli >/dev/null 2>&1; then
    validate_agent_cli || {
      _wlog "ERROR: Agent CLI validation failed"
      return 1
    }
  fi

  _wlog "Initialization complete"
  _wlog "  MAIN_REPO: $MAIN_REPO"
  _wlog "  EXEC_REPO: $EXEC_REPO"
  _wlog "  ORCH_FLAVOR: $ORCH_FLAVOR"

  return 0
}

# Main worker loop
worker_run_loop() {
  _wlog "Starting worker loop"

  while [ "$WORKER_RUNNING" = "true" ]; do
    worker_update_status "worker-$WORKER_ID" "claiming" ""

    # Try to claim a task
    local task
    task="$(queue_claim_next "worker-$WORKER_ID" "$WORKER_LAST_EPIC" 2>/dev/null)" || true

    if [ -z "$task" ]; then
      worker_update_status "worker-$WORKER_ID" "idle" ""
      _wlog "No tasks available, sleeping ${WORKER_IDLE_SLEEP_SECS}s"
      sleep "$WORKER_IDLE_SLEEP_SECS"
      continue
    fi

    # Get epic for the claimed task
    local epic_id=""
    if type _queue_get_epic >/dev/null 2>&1; then
      epic_id="$(_queue_get_epic "$task" 2>/dev/null)" || true
    fi

    _wlog "Claimed task: $task (epic: ${epic_id:-none})"

    # Process the task
    local result=0
    worker_process_task "$task" "$epic_id" || result=$?

    # Release locks
    queue_release_task "$task" "worker-$WORKER_ID" "$epic_id"

    if [ "$result" -ne 0 ]; then
      WORKER_TASKS_FAILED=$((WORKER_TASKS_FAILED + 1))
      _wlog "Task $task failed"
    fi

    # Brief sleep between tasks
    sleep "$WORKER_SLEEP_SECS"
  done

  _wlog "Worker loop exited"
  _wlog "  Tasks completed: $WORKER_TASKS_COMPLETED"
  _wlog "  Tasks failed: $WORKER_TASKS_FAILED"

  worker_unregister "worker-$WORKER_ID"
}

# ──────────────────────────────────────────────────────────────────────────────
# CLI ENTRY POINT
# ──────────────────────────────────────────────────────────────────────────────

# Parse arguments if run directly
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  while [ $# -gt 0 ]; do
    case "$1" in
      --worker-id)
        WORKER_ID="$2"
        shift 2
        ;;
      --main-repo)
        MAIN_REPO="$2"
        shift 2
        ;;
      --exec-repo)
        EXEC_REPO="$2"
        shift 2
        ;;
      --flavor)
        ORCH_FLAVOR="$2"
        shift 2
        ;;
      --help)
        echo "Usage: $0 --worker-id N --main-repo /path --exec-repo /path"
        echo ""
        echo "Options:"
        echo "  --worker-id N      Worker ID (0, 1, 2, ...)"
        echo "  --main-repo PATH   Path to main repo (where beads lives)"
        echo "  --exec-repo PATH   Path to execution worktree"
        echo "  --flavor TYPE      Orchestrator flavor (fe, be, ios)"
        exit 0
        ;;
      *)
        echo "Unknown option: $1" >&2
        exit 1
        ;;
    esac
  done

  # Run
  worker_init || exit 1
  worker_run_loop
fi
