#!/usr/bin/env bash
# orchestrator-loop.sh
#
# Unified Cursor+Beads+Graphite loop for FE/BE with:
# - Branch naming embeds Epic ID: epic/<EPIC_ID>/<TASK_ID>-<slug>
# - Stacking: prefer dependency branch, else epic tip, else base branch
# - Baseline + post-change validation (FE: pnpm run typecheck, BE: make fmt)
# - Optional checker pass (e.g. gemini-3-flash) with bounded repair attempts
# - Self-healing: pre-flight checks, periodic sync, infrastructure failure detection
# - Epic auto-close (best-effort) when:
#     (A) No remote branches exist under refs/remotes/origin/epic/<EPIC_ID>/...
#     (B) No READY (non-epic) beads resolve to that epic
#
# NOTE: This script intentionally never commits:
#   .beads/ .claude/ .cursor/rules/personal/
#
# Usage:
#   ORCH_FLAVOR=fe MAIN_REPO=/path/to/repo EXEC_REPO=/path/to/worktree ./orchestrator-loop.sh
#   ORCH_FLAVOR=be ./orchestrator-loop.sh

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIG
# ──────────────────────────────────────────────────────────────────────────────
ORCH_FLAVOR="${ORCH_FLAVOR:-be}"          # fe|be

IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-opus-4.5-thinking}"
CHECKER_MODEL="${CHECKER_MODEL:-gemini-3-flash}"

# CLI Selection: cursor | claude-code | auto
AGENT_CLI="${AGENT_CLI:-auto}"

# Legacy support - if AGENT_BIN is set, use cursor mode
AGENT_BIN="${AGENT_BIN:-}"

# Source CLI adapter for unified agent invocation
LIB_DIR="${LIB_DIR:-$HOME/.local/lib/orchestrator}"
if [ -f "$LIB_DIR/cli_adapter.sh" ]; then
  source "$LIB_DIR/cli_adapter.sh"
fi

# Source reviewer agent for clean review step
if [ -f "$LIB_DIR/reviewer_agent.sh" ]; then
  source "$LIB_DIR/reviewer_agent.sh"
fi

# MAIN_REPO: where bd runs (canonical checkout)
# EXEC_REPO: where code+gt runs (worktree is fine; can equal MAIN_REPO)
MAIN_REPO="${MAIN_REPO:-${BACKEND_REPO_PATH:-/home/ubuntu/workspaces/experiment-framework}}"
EXEC_REPO="${EXEC_REPO:-$MAIN_REPO}"

BASE_BRANCH="${BASE_BRANCH:-main}"

LOCK_FILE="${LOCK_FILE:-/tmp/cursor-agent.lock}"
CURRENT_TASK_FILE="${CURRENT_TASK_FILE:-/tmp/cursor-agent-current-task}"
FAILED_TASKS_FILE="${FAILED_TASKS_FILE:-/tmp/cursor-agent-failed-tasks}"

LOCK_TTL_SECS="${LOCK_TTL_SECS:-3600}"
SLEEP_SECS="${SLEEP_SECS:-120}"

MAX_AGENT_RETRIES="${MAX_AGENT_RETRIES:-10}"
AGENT_TIMEOUT_SECS="${AGENT_TIMEOUT_SECS:-1800}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-60}"
BACKOFF_MULTIPLIER="${BACKOFF_MULTIPLIER:-2}"
MAX_DELAY_SECS="${MAX_DELAY_SECS:-600}"

MAX_COMMIT_FAILURES="${MAX_COMMIT_FAILURES:-2}"

ENABLE_CHECKER="${ENABLE_CHECKER:-1}"            # 0|1
CHECKER_CONF_THRESHOLD="${CHECKER_CONF_THRESHOLD:-0.70}"
MAX_REPAIR_ATTEMPTS="${MAX_REPAIR_ATTEMPTS:-1}"

# Clean reviewer agent (fresh eyes review after implementation)
ENABLE_REVIEWER="${ENABLE_REVIEWER:-1}"          # 0|1
REVIEWER_MODEL="${REVIEWER_MODEL:-sonnet-4}"     # Different model for fresh perspective
REVIEW_DEPTH="${REVIEW_DEPTH:-standard}"         # minimal|standard|thorough
REVIEWER_CAN_FIX="${REVIEWER_CAN_FIX:-1}"        # Allow implementer to fix reviewer issues
MAX_REVIEW_FIX_ATTEMPTS="${MAX_REVIEW_FIX_ATTEMPTS:-2}"
MIN_LINES_FOR_REVIEW="${MIN_LINES_FOR_REVIEW:-5}" # Skip review for tiny changes

NOTIFY_BIN="${NOTIFY_BIN:-agent-notify}"         # set empty to disable

# Disable husky hooks in agent automation
export HUSKY="${HUSKY:-0}"

# Validation commands and PATH setup per flavor
if [ "$ORCH_FLAVOR" = "fe" ]; then
  VALIDATE_CMD="${VALIDATE_CMD:-pnpm run typecheck}"
  ENABLE_ESLINT_FIX="${ENABLE_ESLINT_FIX:-1}"
  # Ensure pnpm/node are in PATH (volta, nvm, or direct)
  [ -d "$HOME/.volta/bin" ] && export PATH="$HOME/.volta/bin:$PATH"
  [ -f "$HOME/.nvm/nvm.sh" ] && source "$HOME/.nvm/nvm.sh" || true
  [ -d "$HOME/Library/pnpm" ] && export PATH="$HOME/Library/pnpm:$PATH"
elif [ "$ORCH_FLAVOR" = "ios" ]; then
  VALIDATE_CMD="${VALIDATE_CMD:-xcodebuild build -scheme \${XCODE_SCHEME:-App} -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 15'}"
  ENABLE_ESLINT_FIX="${ENABLE_ESLINT_FIX:-0}"
  # Ensure Xcode command-line tools are in PATH
  if command -v xcrun >/dev/null 2>&1; then
    export DEVELOPER_DIR="$(xcode-select -p)"
    export PATH="/usr/bin:$PATH"
  else
    echo "WARNING: Xcode command-line tools not found. Install with: xcode-select --install"
  fi
  # iOS simulator environment
  export XCODE_SCHEME="${XCODE_SCHEME:-App}"
  export SIMULATOR_DEVICE="${SIMULATOR_DEVICE:-iPhone 15}"
else
  VALIDATE_CMD="${VALIDATE_CMD:-make fmt}"
  ENABLE_ESLINT_FIX="${ENABLE_ESLINT_FIX:-0}"
fi

# Always non-interactive Graphite
GT_CREATE_ARGS=(--no-interactive -a)
GT_MODIFY_ARGS=(--no-interactive -a)
GT_SUBMIT_ARGS=(--no-interactive --draft --no-edit --ai)

# ──────────────────────────────────────────────────────────────────────────────
# ROBUSTNESS SETTINGS
# ──────────────────────────────────────────────────────────────────────────────
HEALTH_FILE="${HEALTH_FILE:-/tmp/orchestrator-health}"
MAX_INFRA_FAILURES="${MAX_INFRA_FAILURES:-3}"
SYNC_INTERVAL_SECS="${SYNC_INTERVAL_SECS:-1800}"  # 30 mins
LAST_SYNC_FILE="${LAST_SYNC_FILE:-/tmp/orchestrator-last-sync}"
MAIN_REPO_FOR_LIBS="${MAIN_REPO_FOR_LIBS:-}"  # Set to source repo for lib sync (FE only)

# Optional env (user overrides, pyenv, etc.)
[ -f ~/.agent.env ] && source ~/.agent.env || true

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING / NOTIFY
# ──────────────────────────────────────────────────────────────────────────────
log() { echo "$(date): $*"; }

notify() {
  local msg="$1"; local level="${2:-info}"; local task="${3:-}"
  if [ -n "${NOTIFY_BIN:-}" ] && command -v "$NOTIFY_BIN" >/dev/null 2>&1; then
    "$NOTIFY_BIN" "$msg" "$level" "$task" 2>/dev/null || true
  fi
}

cleanup() {
  rm -f "$LOCK_FILE" "$CURRENT_TASK_FILE"
  exit 0
}
trap cleanup SIGTERM SIGINT EXIT

# ──────────────────────────────────────────────────────────────────────────────
# INFRASTRUCTURE HEALTH & SELF-HEALING
# ──────────────────────────────────────────────────────────────────────────────
record_infra_failure() {
  local reason="$1"
  echo "$(date +%s):$reason" >> "$HEALTH_FILE"
  # Keep only recent failures
  tail -20 "$HEALTH_FILE" > "${HEALTH_FILE}.tmp" && mv "${HEALTH_FILE}.tmp" "$HEALTH_FILE"
}

infra_failure_count() {
  local cutoff=$(($(date +%s) - 3600))  # Last hour
  [ ! -f "$HEALTH_FILE" ] && echo 0 && return
  awk -F: -v cutoff="$cutoff" '$1 > cutoff {count++} END {print count+0}' "$HEALTH_FILE"
}

clear_infra_failures() {
  rm -f "$HEALTH_FILE"
}

needs_sync() {
  [ ! -f "$LAST_SYNC_FILE" ] && return 0
  local last_sync
  last_sync=$(cat "$LAST_SYNC_FILE" 2>/dev/null || echo 0)
  local now
  now=$(date +%s)
  [ $((now - last_sync)) -gt "$SYNC_INTERVAL_SECS" ]
}

# Sync EXEC_REPO to latest master and rebuild dependencies
sync_worktree() {
  log "Syncing worktree to latest master..."
  cd "$EXEC_REPO" || return 1
  
  # Stash any uncommitted changes
  git stash push -m "orchestrator-sync-$(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1 || true
  
  # Fetch and checkout latest master
  git fetch origin master --quiet 2>/dev/null || git fetch origin main --quiet 2>/dev/null || return 1
  git checkout origin/master >/dev/null 2>&1 || git checkout origin/main >/dev/null 2>&1 || return 1
  
  # Reinstall dependencies
  if [ "$ORCH_FLAVOR" = "fe" ]; then
    log "Installing dependencies..."
    pnpm install --frozen-lockfile >/dev/null 2>&1 || pnpm install >/dev/null 2>&1 || true
    
    # Sync lib directories from MAIN_REPO if configured
    if [ -n "$MAIN_REPO_FOR_LIBS" ] && [ -d "$MAIN_REPO_FOR_LIBS/packages" ]; then
      log "Syncing lib directories from $MAIN_REPO_FOR_LIBS..."
      for pkg in "$MAIN_REPO_FOR_LIBS"/packages/*/lib; do
        [ -d "$pkg" ] || continue
        local target="${EXEC_REPO}/${pkg#$MAIN_REPO_FOR_LIBS/}"
        mkdir -p "$(dirname "$target")"
        rsync -a "$pkg/" "$target/" 2>/dev/null || true
      done
    fi
  fi
  
  date +%s > "$LAST_SYNC_FILE"
  log "Worktree synced successfully"
  return 0
}

# Run validation and return success/failure (quiet version)
run_validate_quiet() {
  bash -c "$VALIDATE_CMD" >/dev/null 2>&1
}

# Pre-flight health check - runs before main loop and periodically
preflight_check() {
  log "Running pre-flight health check..."
  cd "$EXEC_REPO" || return 1
  
  # Check if validation passes
  if run_validate_quiet; then
    log "Pre-flight check PASSED"
    clear_infra_failures
    return 0
  fi
  
  log "Pre-flight check FAILED - attempting self-heal..."
  
  # Try syncing
  if sync_worktree && run_validate_quiet; then
    log "Self-heal successful after sync"
    clear_infra_failures
    return 0
  fi
  
  record_infra_failure "preflight_validation_failed"
  local fail_count
  fail_count=$(infra_failure_count)
  
  if [ "$fail_count" -ge "$MAX_INFRA_FAILURES" ]; then
    notify "Orchestrator paused: $fail_count infrastructure failures in last hour. Manual intervention required." "error" ""
    log "ERROR: Too many infrastructure failures ($fail_count). Pausing for extended sleep."
    return 2  # Signal to pause
  fi
  
  log "Pre-flight check failed (attempt $fail_count/$MAX_INFRA_FAILURES)"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# LOCKING
# ──────────────────────────────────────────────────────────────────────────────
acquire_lock_or_wait() {
  if [ -f "$LOCK_FILE" ]; then
    local other_pid lock_mtime age
    other_pid="$(cat "$LOCK_FILE" 2>/dev/null || echo "")"
    lock_mtime="$(stat -c %Y "$LOCK_FILE" 2>/dev/null || stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)"
    age=$(( $(date +%s) - lock_mtime ))

    if [ -n "$other_pid" ] && kill -0 "$other_pid" 2>/dev/null && [ "$age" -lt "$LOCK_TTL_SECS" ]; then
      return 1
    fi
    rm -f "$LOCK_FILE" "$CURRENT_TASK_FILE"
  fi

  echo $$ > "$LOCK_FILE"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# BEADS HELPERS
# ──────────────────────────────────────────────────────────────────────────────
bd_ready_json() {
  (cd "$MAIN_REPO" && bd ready --json 2>/dev/null || echo "[]")
}

bd_ready_next_task() {
  bd_ready_json | jq -r '[.[] | select(.issue_type != "epic")] | first | .id // empty'
}

bd_ready_all_tasks() {
  bd_ready_json | jq -r '.[] | select(.issue_type != "epic") | .id'
}

bd_ready_all_epics() {
  bd_ready_json | jq -r '.[] | select(.issue_type == "epic") | .id'
}

bd_title_from_ready() {
  local id="$1"
  bd_ready_json | jq -r ".[] | select(.id == \"$id\") | .title // \"\""
}

bd_show_text() {
  local id="$1"
  (cd "$MAIN_REPO" && bd show "$id" 2>/dev/null || true)
}

# Robust epic type detection - handles "Type:", "Issue Type:", case variations
bd_is_epic() {
  local id="$1"
  bd_show_text "$id" | grep -qiE '^\s*(Issue\s*)?Type:\s*epic'
}

bd_update_blocked() {
  local id="$1"; shift
  local msg="$*"
  (cd "$MAIN_REPO" && bd update "$id" --status blocked --notes "$msg" 2>/dev/null) || true
  notify "Blocked $id: $msg" "blocked" "$id"
}

bd_close() {
  local id="$1"; shift
  local msg="$*"
  (cd "$MAIN_REPO" && bd close "$id" --reason "$msg" 2>/dev/null) || true
  notify "Closed $id: $msg" "info" "$id"
}

# Extract dependency IDs from bd show output.
# Supports lines like:
#   → <ID>: <title>
extract_dep_ids_from_show() {
  local show_text="$1"
  echo "$show_text" \
    | grep -E '→ ' \
    | sed 's/.*→ //' \
    | cut -d: -f1 \
    | tr -d ' ' \
    | awk 'NF>0' \
    | head -50
}

# Resolve epic for an ID by walking dependencies until you hit Type: epic (bounded).
get_epic_id() {
  local start="$1"
  local max_depth="${2:-6}"

  if bd_is_epic "$start"; then
    echo "$start"
    return 0
  fi

  local depth=0
  local queue="$start"
  local seen=""
  while [ "$depth" -lt "$max_depth" ]; do
    local next_queue=""
    while IFS=$'\n' read -r cur; do
      [ -n "$cur" ] || continue
      if echo "$seen" | grep -qx "$cur" 2>/dev/null; then
        continue
      fi
      seen="$(printf "%s\n%s" "$seen" "$cur" | awk 'NF>0')"

      local txt deps d
      txt="$(bd_show_text "$cur")"
      deps="$(extract_dep_ids_from_show "$txt")"

      while IFS=$'\n' read -r d; do
        [ -n "$d" ] || continue
        if bd_is_epic "$d"; then
          echo "$d"
          return 0
        fi
        next_queue="$(printf "%s\n%s" "$next_queue" "$d" | awk 'NF>0')"
      done <<< "$deps"
    done <<< "$queue"

    queue="$next_queue"
    depth=$((depth+1))
    [ -n "$queue" ] || break
  done

  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# GIT/GRAPHITE HELPERS
# ──────────────────────────────────────────────────────────────────────────────
slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/^-//; s/-$//' \
    | cut -c1-60
}

sanitize_id_for_branch() {
  echo "$1" | sed 's/[^a-zA-Z0-9._\/-]/-/g'
}

stage_safely() {
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

count_changes() {
  # Count uncommitted changes
  local uncommitted
  uncommitted=$(git status --porcelain \
    | grep -v '\.beads/' \
    | grep -v '\.claude/' \
    | grep -v '\.cursor/rules/personal/' \
    | wc -l | tr -d ' ')
  
  # Also count new commits since baseline (cursor-agent may commit directly)
  local new_commits=0
  if [ -n "${BASELINE_HEAD:-}" ]; then
    new_commits=$(git rev-list --count "${BASELINE_HEAD}..HEAD" 2>/dev/null || echo 0)
  fi
  
  echo $((uncommitted + new_commits))
}

fail_count() {
  local task="$1"
  local count
  count="$(grep -c "^$task$" "$FAILED_TASKS_FILE" 2>/dev/null)" || count=0
  echo "$count"
}

record_fail() { echo "$1" >> "$FAILED_TASKS_FILE"; }

clear_fail() {
  local task="$1"
  if [ -f "$FAILED_TASKS_FILE" ]; then
    sed -i '' "/^$task$/d" "$FAILED_TASKS_FILE" 2>/dev/null || sed -i "/^$task$/d" "$FAILED_TASKS_FILE" 2>/dev/null || true
  fi
}

eslint_fix_if_enabled() {
  [ "$ENABLE_ESLINT_FIX" = "1" ] || return 0
  local changed
  changed="$(git status --porcelain | awk '{print $2}' | grep -E '\.tsx?$' || true)"
  if [ -n "$changed" ]; then
    log "Running eslint --fix on changed TS/TSX files"
    # shellcheck disable=SC2086
    npx eslint --fix --max-warnings=1000 $changed 2>&1 | tail -50 || true
  fi
}

run_validate() {
  log "Validate: $VALIDATE_CMD"
  bash -c "$VALIDATE_CMD"
}

# Find remote branches for a given epic prefix
epic_remote_refs_any() {
  local epic="$1"
  local e; e="$(sanitize_id_for_branch "$epic")"
  git fetch origin --quiet || true
  git for-each-ref --format='%(refname:short)' "refs/remotes/origin/epic/$e/" 2>/dev/null | head -1 | grep -q . || true
}

# Find existing branch for a task under epic prefix
find_task_branch() {
  local epic="$1" task="$2"
  local e; e="$(sanitize_id_for_branch "$epic")"
  local t; t="$(sanitize_id_for_branch "$task")"
  git fetch origin --quiet || true
  
  # Try new convention first: epic/<epic-id>/<task-id>-...
  local branch
  branch="$(git for-each-ref --format='%(refname:short)' "refs/remotes/origin/epic/$e/" 2>/dev/null \
    | grep -i "$t" \
    | head -1 \
    | sed 's|^origin/||')" || true
  
  # Fall back to flat branches: <task-id>-... or <task-id>
  if [ -z "$branch" ]; then
    branch="$(git for-each-ref --format='%(refname:short)' refs/remotes/origin/ 2>/dev/null \
      | grep -E "^origin/.*${t}" \
      | head -1 \
      | sed 's|^origin/||')" || true
  fi
  
  echo "$branch"
}

# Find "tip" branch for an epic (newest by committerdate)
# Only matches branches in the epic/<epic-id>/ namespace
find_epic_tip_branch() {
  local epic="$1"
  local e; e="$(sanitize_id_for_branch "$epic")"
  git fetch origin --quiet || true
  
  # Only use branches that follow the epic/<epic-id>/... convention
  local branch
  branch="$(git for-each-ref --sort=-committerdate --format='%(refname:short)' "refs/remotes/origin/epic/$e/" 2>/dev/null \
    | head -1 \
    | sed 's|^origin/||')" || true
  
  echo "$branch"
}

# Prefer stacking on a dependency's branch (within same epic), if any
find_parent_branch_for_task() {
  local epic="$1" task="$2"
  local details deps d b
  details="$(bd_show_text "$task")"
  deps="$(extract_dep_ids_from_show "$details")"
  while IFS=$'\n' read -r d; do
    [ -n "$d" ] || continue
    b="$(find_task_branch "$epic" "$d")"
    if [ -n "$b" ]; then
      echo "$b"
      return 0
    fi
  done <<< "$deps"
  echo ""
}

# Best-effort: does gt log show PR for task?
task_has_pr() {
  local task="$1"
  # Disable pipefail temporarily to allow gt log to fail without killing the script
  set +o pipefail
  local out
  out="$(gt log 2>&1)"
  local ret=$?
  set -o pipefail
  
  if [ $ret -ne 0 ]; then
     log "WARNING: gt log failed (code $ret). Output: $(echo "$out" | head -1)"
     return 1
  fi
  
  echo "$out" | grep -i "$task" | grep -qi "PR #"
}

# ──────────────────────────────────────────────────────────────────────────────
# AGENT HELPERS
# ──────────────────────────────────────────────────────────────────────────────
run_agent_with_retries() {
  local model="$1"
  local prompt="$2"

  # If CLI adapter is loaded, use it
  if type run_agent_cli >/dev/null 2>&1; then
    # Prepend CLI-specific prompt prefix if available
    local prefix=""
    if type get_cli_prompt_prefix >/dev/null 2>&1; then
      prefix="$(get_cli_prompt_prefix)"
    fi
    local full_prompt="${prefix}${prompt}"
    
    local attempt=0
    local delay="$RETRY_DELAY_SECS"
    local out="" code=0

    while [ "$attempt" -lt "$MAX_AGENT_RETRIES" ]; do
      log "Agent attempt $((attempt+1))/$MAX_AGENT_RETRIES (cli=$AGENT_CLI, model=$model)"
      set +e
      out="$(run_agent_cli "$model" "$full_prompt")"
      code=$?
      set -e

      if [ "$code" -eq 0 ]; then
        printf "%s" "$out"
        return 0
      fi

      if [ "$code" -eq 124 ] || echo "$out" | grep -qi "provider\|rate limit\|503\|502\|500\|timeout\|overloaded\|capacity"; then
        attempt=$((attempt+1))
        log "Retryable error. Sleeping ${delay}s."
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

  # Legacy fallback: use AGENT_BIN directly
  local attempt=0
  local delay="$RETRY_DELAY_SECS"
  local out="" code=0
  local agent_bin="${AGENT_BIN:-$HOME/.local/bin/cursor-agent}"

  while [ "$attempt" -lt "$MAX_AGENT_RETRIES" ]; do
    log "Agent attempt $((attempt+1))/$MAX_AGENT_RETRIES (model=$model)"
    set +e
    out="$(timeout "$AGENT_TIMEOUT_SECS" "$agent_bin" --model "$model" -p --force "$prompt" 2>&1)"
    code=$?
    set -e

    if [ "$code" -eq 0 ]; then
      printf "%s" "$out"
      return 0
    fi

    if [ "$code" -eq 124 ] || echo "$out" | grep -qi "provider\|rate limit\|503\|502\|500\|timeout\|overloaded\|capacity"; then
      attempt=$((attempt+1))
      log "Retryable error. Sleeping ${delay}s."
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
}

agent_reported_blocked() {
  local out="$1"
  echo "$out" | grep -q "^STATUS: BLOCKED"
}

normalize_checker_json() {
  local raw="$1"
  local s
  s="$(echo "$raw" | sed -e 's/^```json[[:space:]]*$//g' -e 's/^```[[:space:]]*$//g' -e 's/```$//g')"
  echo "$s" | awk '
    BEGIN{found=0}
    {
      if (!found) {
        p=index($0,"{");
        if (p>0) { found=1; print substr($0,p); }
      } else {
        print $0;
      }
    }
  ' | awk '
    { buf = buf $0 "\n"; }
    END {
      last = 0;
      for (i=length(buf); i>=1; i--) { if (substr(buf,i,1)=="}") { last=i; break; } }
      if (last>0) { printf "%s", substr(buf,1,last); }
      else { printf "%s", buf; }
    }
  '
}

build_implementer_prompt() {
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

build_checker_prompt() {
  local task="$1" title="$2" details="$3" diffstat="$4" difftext="$5"

  cat <<EOF
You are a strict completeness checker.

Task: $task
Title: $title

FULL TASK DETAILS:
$details

Validation PASSED:
- $VALIDATE_CMD

Diffstat:
$diffstat

Diff (truncated):
$difftext

Return ONLY valid JSON (no markdown fences, no commentary) with schema:
{
  "complete": boolean,
  "confidence": number,
  "blocking_gaps": [{"ac": string, "issue": string, "evidence": string}],
  "suggested_edits": [{"issue": string, "evidence": string}]
}

Rules:
- If any acceptance criterion is not clearly satisfied, complete=false.
- Prefer evidence-based blocking_gaps.
- Do not expand scope beyond acceptance criteria.
EOF
}

build_repair_prompt() {
  local task="$1" title="$2" checker_json="$3"
  cat <<EOF
You are repairing an implementation for Beads task $task.

TASK: $title

Fix ONLY the blocking_gaps reported below. Do NOT expand scope.

CRITICAL RULES - NEVER VIOLATE:
1. NEVER run git commands: git commit, git checkout, git push
2. NEVER run Graphite commands: gt create, gt submit, gt modify
3. ALWAYS leave changes UNCOMMITTED - the orchestrator handles commits and PRs

CHECKER_JSON:
$checker_json

IF BLOCKED:
Output exactly:
STATUS: BLOCKED
REASON: <one paragraph>
QUESTIONS:
- <up to 3 concrete questions>
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# EPIC AUTO-CLOSE (best-effort, no GitHub API)
# ──────────────────────────────────────────────────────────────────────────────
# Close epic E when:
#   A) no remote branches remain under origin/epic/E/...
#   B) no READY non-epic beads resolve to epic E
#
# This is conservative: if tasks are open-but-not-ready, Beads may not surface them
# via `bd ready`, so epics may close later than ideal (never earlier).
maybe_close_epics() {
  local epics e
  epics="$(bd_ready_all_epics 2>/dev/null || true)"
  [ -n "$epics" ] || return 0

  # Precompute ready-task -> epic mapping (bounded; expensive but safe)
  local ready_tasks t te
  ready_tasks="$(bd_ready_all_tasks 2>/dev/null || true)"

  while IFS=$'\n' read -r e; do
    [ -n "$e" ] || continue

    # If any remote branches for this epic exist, not merged.
    if epic_remote_refs_any "$e"; then
      continue
    fi

    # If any READY task belongs to this epic, don't close.
    local has_ready_child=0
    while IFS=$'\n' read -r t; do
      [ -n "$t" ] || continue
      te="$(get_epic_id "$t" 6)"
      if [ -n "$te" ] && [ "$te" = "$e" ]; then
        has_ready_child=1
        break
      fi
    done <<< "$ready_tasks"

    if [ "$has_ready_child" -eq 1 ]; then
      continue
    fi

    bd_close "$e" "Epic complete: no remaining remote epic branches and no READY child beads"
  done <<< "$epics"
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN LOOP
# ──────────────────────────────────────────────────────────────────────────────
log "Starting orchestrator loop (flavor=$ORCH_FLAVOR)"
log "MAIN_REPO=$MAIN_REPO"
log "EXEC_REPO=$EXEC_REPO"
log "VALIDATE_CMD=$VALIDATE_CMD"
log "IMPLEMENTER_MODEL=$IMPLEMENTER_MODEL"
log "CHECKER_MODEL=$CHECKER_MODEL (ENABLE_CHECKER=$ENABLE_CHECKER)"
log "REVIEWER_MODEL=$REVIEWER_MODEL (ENABLE_REVIEWER=$ENABLE_REVIEWER, depth=$REVIEW_DEPTH)"

# Pre-flight health check before starting
log "Running initial pre-flight check..."
preflight_result=0
preflight_check || preflight_result=$?
if [ "$preflight_result" -eq 2 ]; then
  log "Pre-flight failed with too many errors. Sleeping before retry..."
  sleep $((SLEEP_SECS * 10))
fi

while true; do
  # Periodic sync check
  if needs_sync; then
    log "Periodic sync triggered (interval: ${SYNC_INTERVAL_SECS}s)"
    sync_worktree || log "Periodic sync failed (will retry)"
  fi

  cd "$EXEC_REPO" || { log "ERROR: cannot cd to EXEC_REPO=$EXEC_REPO"; sleep "$SLEEP_SECS"; continue; }

  if ! acquire_lock_or_wait; then
    sleep "$SLEEP_SECS"
    continue
  fi

  git fetch origin --quiet || true

  TASK="$(bd_ready_next_task)"
  if [ -z "$TASK" ] || [ "$TASK" = "null" ]; then
    log "No tasks available"
    rm -f "$LOCK_FILE"
    maybe_close_epics || true
    sleep "$SLEEP_SECS"
    continue
  fi

  if [ "$(fail_count "$TASK")" -ge "$MAX_COMMIT_FAILURES" ]; then
    log "Task $TASK exceeded failure threshold -> blocking"
    bd_update_blocked "$TASK" "Exceeded failure threshold ($MAX_COMMIT_FAILURES). Needs manual review."
    rm -f "$LOCK_FILE"
    sleep "$SLEEP_SECS"
    continue
  fi

  TITLE="$(bd_title_from_ready "$TASK")"
  DETAILS="$(bd_show_text "$TASK")"

  log "═══════════════════════════════════════════"
  log "Task: $TASK - $TITLE"
  log "DEBUG: PATH=$PATH"
  log "DEBUG: gt location: $(command -v gt || echo 'not found')"
  set -x
  echo "$TASK" > "$CURRENT_TASK_FILE"
  set +x

  log "DEBUG: Checking for existing PR..."
  # If already has a PR, close and move on
  if task_has_pr "$TASK"; then
    log "DEBUG: Task has PR"
    PR_INFO="$(gt log 2>&1 | grep -i "$TASK" -A3 | grep -m1 "PR #" || true)"
    PR_NUM="$(echo "$PR_INFO" | grep -oE '#[0-9]+' | head -1 | tr -d '#')"
    bd_close "$TASK" "Already completed in PR #${PR_NUM:-unknown}"
    rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
    maybe_close_epics || true
    sleep "$SLEEP_SECS"
    continue
  fi

  log "DEBUG: Getting Epic ID..."
  EPIC_ID="$(get_epic_id "$TASK" 6)"
  log "DEBUG: Epic ID is: ${EPIC_ID:-none}"

  # Branch context selection
  BRANCH_MODE="new"
  EXISTING_BRANCH=""
  if [ -n "$EPIC_ID" ]; then
    EXISTING_BRANCH="$(find_task_branch "$EPIC_ID" "$TASK")"
  else
    git fetch origin --quiet || true
    EXISTING_BRANCH="$(git branch -r | grep -i "$TASK" | head -1 | sed 's|origin/||' | tr -d ' ' || true)"
  fi

  # Compute desired branch name
  clean_title="$(slugify "$TITLE")"
  task_id_clean="$(sanitize_id_for_branch "$TASK")"
  commit_msg="[$TASK] $TITLE"

  if [ -n "$EPIC_ID" ]; then
    epic_clean="$(sanitize_id_for_branch "$EPIC_ID")"
    desired_branch="epic/${epic_clean}/${task_id_clean}-${clean_title}"
  else
    desired_branch="agent/${task_id_clean}-${clean_title}"
  fi

  USING_TEMP_BRANCH=""
  PARENT_BRANCH="$BASE_BRANCH"

  if [ -n "$EXISTING_BRANCH" ]; then
    BRANCH_MODE="modify"
    log "Found existing branch: $EXISTING_BRANCH"
    # Use gt checkout to keep Graphite state in sync
    gt checkout "$EXISTING_BRANCH" --no-interactive 2>/dev/null || \
      git checkout "$EXISTING_BRANCH" 2>/dev/null || \
      git checkout -b "$EXISTING_BRANCH" "origin/$EXISTING_BRANCH"
    git pull origin "$EXISTING_BRANCH" --rebase 2>/dev/null || true
  else
    BRANCH_MODE="new"

    if [ -n "$EPIC_ID" ]; then
      dep_parent="$(find_parent_branch_for_task "$EPIC_ID" "$TASK")"
      if [ -n "$dep_parent" ]; then
        PARENT_BRANCH="$dep_parent"
      else
        tip="$(find_epic_tip_branch "$EPIC_ID")"
        [ -n "$tip" ] && PARENT_BRANCH="$tip"
      fi
    fi

    log "Starting new work from parent: $PARENT_BRANCH"
    
    # Checkout parent using gt (keeps Graphite state in sync)
    PARENT_CHECKOUT_OK="false"
    if gt checkout "$PARENT_BRANCH" --no-interactive >/dev/null 2>&1; then
      PARENT_CHECKOUT_OK="true"
    elif git checkout "$PARENT_BRANCH" >/dev/null 2>&1; then
      PARENT_CHECKOUT_OK="true"
    else
      # Parent branch locked by another worktree - create temp tracking branch
      # gt create requires a real branch, not detached HEAD
      log "Local branch $PARENT_BRANCH unavailable (locked?); using temp tracking branch"
      TEMP_PARENT="agent-base-${PARENT_BRANCH//\//-}"
      git fetch origin "$PARENT_BRANCH" --quiet || true
      
      # Check if temp branch already exists
      if git rev-parse --verify "$TEMP_PARENT" >/dev/null 2>&1; then
        # Temp branch exists - checkout and reset to latest
        git checkout "$TEMP_PARENT" >/dev/null 2>&1 || true
        git reset --hard "origin/$PARENT_BRANCH" >/dev/null 2>&1 || true
        PARENT_CHECKOUT_OK="true"
        USING_TEMP_BRANCH="true"
      elif git checkout -b "$TEMP_PARENT" "origin/$PARENT_BRANCH" >/dev/null 2>&1; then
        # Created new temp branch
        PARENT_CHECKOUT_OK="true"
        USING_TEMP_BRANCH="true"
      fi
      
      # Track with Graphite so gt create works
      if [ "$PARENT_CHECKOUT_OK" = "true" ]; then
        gt track "$TEMP_PARENT" --force >/dev/null 2>&1 || true
      fi
    fi
    
    if [ "$PARENT_CHECKOUT_OK" != "true" ]; then
      log "ERROR: Could not checkout $PARENT_BRANCH or create tracking branch"
      bd_update_blocked "$TASK" "Failed to checkout parent branch $PARENT_BRANCH"
      rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
      sleep "$SLEEP_SECS"
      continue
    fi
    
    git pull origin "$PARENT_BRANCH" --rebase >/dev/null 2>&1 || true

    # Create branch BEFORE agent runs - this locks the agent to this branch
    log "Graphite: gt create $desired_branch (before agent)"
    
    # Try gt create - it will use the current branch as parent
    if ! gt create "${GT_CREATE_ARGS[@]}" "$desired_branch" -m "[$TASK] WIP" >/dev/null 2>&1; then
      log "ERROR: gt create failed for $desired_branch"
      bd_update_blocked "$TASK" "Failed to create branch $desired_branch with Graphite"
      rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
      sleep "$SLEEP_SECS"
      continue
    fi
    log "Branch $desired_branch created and tracked by Graphite"
  fi

  # Baseline validation with self-healing
  log "Baseline validation gate..."
  BASELINE_VALID="false"
  if run_validate 2>&1 | tee /tmp/orch-validate.log; then
    BASELINE_VALID="true"
  else
    log "Baseline validation failed - attempting self-heal..."
    
    # Try syncing and re-validating
    if sync_worktree; then
      # Re-checkout to the current branch after sync
      if [ -n "$EXISTING_BRANCH" ]; then
        gt checkout "$EXISTING_BRANCH" --no-interactive 2>/dev/null || \
          git checkout "$EXISTING_BRANCH" 2>/dev/null || true
      else
        gt checkout "$desired_branch" --no-interactive 2>/dev/null || \
          git checkout "$desired_branch" 2>/dev/null || true
      fi
      
      if run_validate 2>&1 | tee /tmp/orch-validate.log; then
        log "Self-heal successful - baseline now passes"
        BASELINE_VALID="true"
        clear_infra_failures
      fi
    fi

  fi
  
  if [ "$BASELINE_VALID" != "true" ]; then
    record_infra_failure "baseline_validation_$TASK"
    fail_cnt=$(infra_failure_count)
    
    if [ "$fail_cnt" -ge "$MAX_INFRA_FAILURES" ]; then
      # This is an infrastructure issue, not a task issue - don't block the task
      notify "Orchestrator: baseline validation failing repeatedly ($fail_cnt times). Infrastructure issue, not blocking task." "warning" "$TASK"
      log "Infrastructure issue detected. Sleeping for extended period."
      rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
      sleep $((SLEEP_SECS * 5))
      continue
    fi
    
    tailmsg="$(tail -140 /tmp/orch-validate.log | tr '\n' ' ' | sed 's/  */ /g')"
    bd_update_blocked "$TASK" "Baseline validation failed (self-heal attempted). Tail: $tailmsg"
    rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
    maybe_close_epics || true
    sleep "$SLEEP_SECS"
    continue
  fi

  # Run implementer
  # Capture baseline HEAD to detect if cursor-agent commits directly
  BASELINE_HEAD="$(git rev-parse HEAD)"
  export BASELINE_HEAD
  
  # Use desired_branch for new branches, EXISTING_BRANCH for existing ones
  CURRENT_BRANCH="${EXISTING_BRANCH:-$desired_branch}"
  PROMPT="$(build_implementer_prompt "$TASK" "$TITLE" "$DETAILS" "$CURRENT_BRANCH")"
  OUT="$(run_agent_with_retries "$IMPLEMENTER_MODEL" "$PROMPT" || true)"

  if agent_reported_blocked "$OUT"; then
    bd_update_blocked "$TASK" "$(echo "$OUT" | tail -120 | tr '\n' ' ' | sed 's/  */ /g')"
    rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
    maybe_close_epics || true
    sleep "$SLEEP_SECS"
    continue
  fi

  if [ "$(count_changes)" -eq 0 ]; then
    bd_update_blocked "$TASK" "Agent produced no changes. Likely underspecified. Add clearer acceptance criteria or examples."
    rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
    maybe_close_epics || true
    sleep "$SLEEP_SECS"
    continue
  fi

  eslint_fix_if_enabled

  # Post-change validation
  log "Post-change validation gate..."
  if ! run_validate 2>&1 | tee /tmp/orch-validate.log; then
    tailmsg="$(tail -180 /tmp/orch-validate.log | tr '\n' ' ' | sed 's/  */ /g')"
    git stash push -m "validate-failed-$TASK-$(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1 || true
    bd_update_blocked "$TASK" "Post-change validation failed. Changes stashed. Tail: $tailmsg"
    rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
    maybe_close_epics || true
    sleep "$SLEEP_SECS"
    continue
  fi

  # ═══════════════════════════════════════════════════════════════════════════
  # CLEAN REVIEWER AGENT - Fresh eyes review by a different model
  # ═══════════════════════════════════════════════════════════════════════════
  if [ "$ENABLE_REVIEWER" = "1" ] && type run_reviewer_agent >/dev/null 2>&1; then
    # Check if change is substantial enough for review
    changed_lines="$(git diff HEAD~1 --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
    
    if [ "$changed_lines" -ge "$MIN_LINES_FOR_REVIEW" ]; then
      log "═══════════════════════════════════════════"
      log "CLEAN REVIEWER: $REVIEWER_MODEL reviewing changes (depth=$REVIEW_DEPTH)"
      log "═══════════════════════════════════════════"
      
      review_attempt=0
      review_passed="false"
      
      while [ "$review_attempt" -lt "$MAX_REVIEW_FIX_ATTEMPTS" ]; do
        review_attempt=$((review_attempt + 1))
        
        # Run the clean reviewer
        REVIEW_RESULT="$(run_reviewer_agent "$TASK" "$TITLE" "HEAD~1" 2>/dev/null || echo '{"approved":false,"error":"reviewer failed"}')"
        
        # Check if approved
        if echo "$REVIEW_RESULT" | grep -q '"approved":\s*true'; then
          log "REVIEWER APPROVED ✓ (attempt $review_attempt)"
          review_passed="true"
          break
        fi
        
        # Extract issues for logging
        blocking_count="$(echo "$REVIEW_RESULT" | grep -o '"blocking_issues"' | wc -l | tr -d ' ')"
        summary="$(echo "$REVIEW_RESULT" | grep -o '"summary":"[^"]*"' | cut -d'"' -f4 | head -1)"
        log "REVIEWER FOUND ISSUES (attempt $review_attempt): $summary"
        
        # Can we fix?
        if [ "$REVIEWER_CAN_FIX" != "1" ]; then
          log "Reviewer cannot fix, blocking task"
          break
        fi
        
        if [ "$review_attempt" -ge "$MAX_REVIEW_FIX_ATTEMPTS" ]; then
          log "Max review fix attempts reached"
          break
        fi
        
        # Ask implementer to fix the issues
        log "Asking implementer to fix reviewer issues..."
        FIX_PROMPT="$(cat <<EOF
A code reviewer (different AI with fresh perspective) found issues in your implementation.

REVIEW FINDINGS:
$REVIEW_RESULT

INSTRUCTIONS:
1. Read the blocking_issues carefully
2. Fix each issue mentioned
3. Do NOT change anything unrelated to these issues
4. The reviewer will check again after you fix

Fix the issues now.
EOF
)"
        
        FIX_OUT="$(run_agent_with_retries "$IMPLEMENTER_MODEL" "$FIX_PROMPT" || true)"
        
        if agent_reported_blocked "$FIX_OUT"; then
          log "Implementer blocked while fixing reviewer issues"
          break
        fi
        
        # Stage and amend
        stage_safely
        if [ "$(count_changes)" -gt 0 ]; then
          gt modify "${GT_MODIFY_ARGS[@]}" -m "[$TASK] Fix reviewer issues" >/dev/null 2>&1 || \
            git commit --amend --no-edit >/dev/null 2>&1 || true
        fi
        
        # Re-validate before next review
        if ! run_validate 2>&1 | tee /tmp/orch-validate.log; then
          log "Validation failed after reviewer fix"
          break
        fi
      done
      
      if [ "$review_passed" != "true" ]; then
        issues_text="$(echo "$REVIEW_RESULT" | tr '\n' ' ' | sed 's/  */ /g' | head -c 500)"
        bd_update_blocked "$TASK" "Clean reviewer did not approve after $review_attempt attempts. Issues: $issues_text"
        rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
        maybe_close_epics || true
        sleep "$SLEEP_SECS"
        continue
      fi
    else
      log "Skipping reviewer: only $changed_lines lines changed (min: $MIN_LINES_FOR_REVIEW)"
    fi
  fi

  # Optional checker + bounded repair
  if [ "$ENABLE_CHECKER" = "1" ]; then
    diffstat="$(git diff --stat || true)"
    diff_full="$(git diff || true)"
    diff_head="$(echo "$diff_full" | head -1200)"
    diff_tail="$(echo "$diff_full" | tail -400)"
    difftext="${diff_head}"$'\n...\n'"${diff_tail}"

    CHECK_PROMPT="$(build_checker_prompt "$TASK" "$TITLE" "$DETAILS" "$diffstat" "$difftext")"
    RAW_CHECK="$(run_agent_with_retries "$CHECKER_MODEL" "$CHECK_PROMPT" || true)"
    CHECK_JSON="$(normalize_checker_json "$RAW_CHECK")"

    complete="false"; conf="0"
    if echo "$CHECK_JSON" | jq -e . >/dev/null 2>&1; then
      complete="$(echo "$CHECK_JSON" | jq -r '.complete // false')"
      conf="$(echo "$CHECK_JSON" | jq -r '.confidence // 0')"
    fi

    repair_attempts=0
    while :; do
      conf_ok="$(awk -v c="$conf" -v t="$CHECKER_CONF_THRESHOLD" 'BEGIN{print (c>=t) ? "1":"0"}')"
      if [ "$complete" = "true" ] && [ "$conf_ok" = "1" ]; then
        log "Checker PASS (complete=true, confidence=$conf)"
        break
      fi

      if [ "$repair_attempts" -ge "$MAX_REPAIR_ATTEMPTS" ]; then
        bd_update_blocked "$TASK" "Checker did not confirm completeness (complete=$complete conf=$conf). JSON: $(echo "$CHECK_JSON" | tr '\n' ' ' | sed 's/  */ /g')"
        rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
        maybe_close_epics || true
        sleep "$SLEEP_SECS"
        continue 2
      fi

      log "Checker FAIL (complete=$complete conf=$conf). Repair attempt $((repair_attempts+1))/$MAX_REPAIR_ATTEMPTS"
      REPAIR_PROMPT="$(build_repair_prompt "$TASK" "$TITLE" "$CHECK_JSON")"
      R_OUT="$(run_agent_with_retries "$IMPLEMENTER_MODEL" "$REPAIR_PROMPT" || true)"

      if agent_reported_blocked "$R_OUT"; then
        bd_update_blocked "$TASK" "Repair blocked. Output: $(echo "$R_OUT" | tail -120 | tr '\n' ' ' | sed 's/  */ /g')"
        rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
        maybe_close_epics || true
        sleep "$SLEEP_SECS"
        continue 2
      fi

      log "Validate after repair..."
      if ! run_validate 2>&1 | tee /tmp/orch-validate.log; then
        tailmsg="$(tail -180 /tmp/orch-validate.log | tr '\n' ' ' | sed 's/  */ /g')"
        git stash push -m "repair-validate-failed-$TASK-$(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1 || true
        bd_update_blocked "$TASK" "Validation failed after repair. Changes stashed. Tail: $tailmsg"
        rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
        maybe_close_epics || true
        sleep "$SLEEP_SECS"
        continue 2
      fi

      # Re-run checker
      diffstat="$(git diff --stat || true)"
      diff_full="$(git diff || true)"
      diff_head="$(echo "$diff_full" | head -1200)"
      diff_tail="$(echo "$diff_full" | tail -400)"
      difftext="${diff_head}"$'\n...\n'"${diff_tail}"

      CHECK_PROMPT="$(build_checker_prompt "$TASK" "$TITLE" "$DETAILS" "$diffstat" "$difftext")"
      RAW_CHECK="$(run_agent_with_retries "$CHECKER_MODEL" "$CHECK_PROMPT" || true)"
      CHECK_JSON="$(normalize_checker_json "$RAW_CHECK")"

      complete="false"; conf="0"
      if echo "$CHECK_JSON" | jq -e . >/dev/null 2>&1; then
        complete="$(echo "$CHECK_JSON" | jq -r '.complete // false')"
        conf="$(echo "$CHECK_JSON" | jq -r '.confidence // 0')"
      fi

      repair_attempts=$((repair_attempts+1))
    done
  fi

  # Commit/PR flow - Agent should have done gt modify + gt submit
  # We check if that happened and fall back if needed
  
  # Check if agent already committed (HEAD moved from baseline)
  AGENT_COMMITTED="false"
  if [ -n "${BASELINE_HEAD:-}" ] && [ "$(git rev-parse HEAD)" != "$BASELINE_HEAD" ]; then
    log "Agent committed (HEAD moved from $BASELINE_HEAD to $(git rev-parse --short HEAD))"
    AGENT_COMMITTED="true"
  fi

  # Check if there are uncommitted changes (agent may have forgotten to commit)
  UNCOMMITTED_CHANGES="$(git status --porcelain | grep -v '\.beads/' | grep -v '\.claude/' | grep -v '\.cursor/rules/personal/' | wc -l | tr -d ' ')"

  GT_OK="false"
  PR_OUT=""

  if [ "$UNCOMMITTED_CHANGES" -gt 0 ]; then
    # Agent left uncommitted changes - orchestrator commits them
    log "Agent left $UNCOMMITTED_CHANGES uncommitted changes, committing with gt modify"
    stage_safely
    if gt modify "${GT_MODIFY_ARGS[@]}" -m "$commit_msg" >/dev/null 2>&1; then
      GT_OK="true"
      AGENT_COMMITTED="true"
    fi
  elif [ "$AGENT_COMMITTED" = "true" ]; then
    # Agent committed, check if there's anything to sync
    GT_OK="true"
  fi

  if [ "$GT_OK" != "true" ] && [ "$UNCOMMITTED_CHANGES" -gt 0 ]; then
    record_fail "$TASK"
    git stash push -m "gt-modify-failed-$TASK-$(date +%Y%m%d-%H%M%S)" >/dev/null 2>&1 || true
    bd_update_blocked "$TASK" "Graphite modify failed; changes stashed."
    rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
    maybe_close_epics || true
    sleep "$SLEEP_SECS"
    continue
  fi

  # Check if agent already submitted (PR exists)
  if task_has_pr "$TASK"; then
    log "Agent already submitted PR for $TASK"
    PR_NUM="$(gt log 2>&1 | grep -i "$TASK" -A3 | grep -m1 -oE '#[0-9]+' | head -1 | tr -d '#' || true)"
  else
    # Agent didn't submit - orchestrator submits
    log "Graphite: gt submit (agent didn't submit)"
    set +e
    PR_OUT="$(gt submit "${GT_SUBMIT_ARGS[@]}" 2>&1)"
    PR_CODE=$?
    set -e

    if [ "$PR_CODE" -ne 0 ]; then
      record_fail "$TASK"
      bd_update_blocked "$TASK" "gt submit failed. Tail: $(echo "$PR_OUT" | tail -80 | tr '\n' ' ' | sed 's/  */ /g')"
      rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"
      maybe_close_epics || true
      sleep "$SLEEP_SECS"
      continue
    fi
    PR_NUM="$(echo "$PR_OUT" | grep -oE '#[0-9]+' | head -1 | tr -d '#')"
  fi

  if [ -n "${PR_NUM:-}" ]; then
    bd_close "$TASK" "Completed in PR #$PR_NUM"
    clear_fail "$TASK"
  else
    bd_update_blocked "$TASK" "PR submitted but PR number not captured. Tail: $(echo "$PR_OUT" | tail -80 | tr '\n' ' ' | sed 's/  */ /g')"
  fi

  rm -f "$CURRENT_TASK_FILE" "$LOCK_FILE"

  maybe_close_epics || true

  log "═══════════════════════════════════════════"
  sleep "$SLEEP_SECS"
done

