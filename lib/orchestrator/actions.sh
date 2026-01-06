#!/usr/bin/env bash
# actions.sh - State machine step implementations
#
# Each function corresponds to a step in the orchestration state machine:
# PICK_TASK → PREPARE_BRANCH → RUN_IMPLEMENTER → VALIDATE → SUBMIT_PR → CLOSE_BEAD
#
# All steps are:
# - Idempotent (safe to retry)
# - Independently verifiable
# - Return success/failure + context
#
# Usage:
#   source actions.sh
#   RESULT=$(step_prepare_branch "$TASK" "$EPIC_ID" "$TITLE")

set -euo pipefail

# Source dependencies
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
IMPLEMENTER_MODEL="${IMPLEMENTER_MODEL:-opus-4.5-thinking}"
CHECKER_MODEL="${CHECKER_MODEL:-gemini-3-flash}"
AGENT_BIN="${AGENT_BIN:-$HOME/.local/bin/cursor-agent}"
AGENT_TIMEOUT_SECS="${AGENT_TIMEOUT_SECS:-1800}"
MAX_AGENT_RETRIES="${MAX_AGENT_RETRIES:-10}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-60}"
BACKOFF_MULTIPLIER="${BACKOFF_MULTIPLIER:-2}"
MAX_DELAY_SECS="${MAX_DELAY_SECS:-600}"

# Flavor-specific
ORCH_FLAVOR="${ORCH_FLAVOR:-be}"
if [ "$ORCH_FLAVOR" = "fe" ]; then
  VALIDATE_CMD="${VALIDATE_CMD:-pnpm run typecheck}"
else
  VALIDATE_CMD="${VALIDATE_CMD:-make fmt}"
fi

# Disable husky hooks
export HUSKY="${HUSKY:-0}"

# Dev server for visual testing (FE only)
DEV_SERVER_CMD="${DEV_SERVER_CMD:-pnpm dev:movio}"
DEV_SERVER_PORT="${DEV_SERVER_PORT:-8081}"
DEV_SERVER_URL="${DEV_SERVER_URL:-http://localhost:8081}"
DEV_SERVER_PID_FILE="${DEV_SERVER_PID_FILE:-/tmp/agent-dev-server-v2.pid}"
ENABLE_VISUAL_CHECK="${ENABLE_VISUAL_CHECK:-0}"

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────────────────────────────────────
_log() { echo "$(date): [actions] $*"; }

# ──────────────────────────────────────────────────────────────────────────────
# DEV SERVER MANAGEMENT (FE only)
# ──────────────────────────────────────────────────────────────────────────────
dev_server_running() {
  [ "$ORCH_FLAVOR" != "fe" ] && return 1
  [ ! -f "${DEV_SERVER_PID_FILE:-}" ] && return 1
  local pid
  pid="$(cat "$DEV_SERVER_PID_FILE" 2>/dev/null)" || return 1
  kill -0 "$pid" 2>/dev/null
}

start_dev_server() {
  [ "$ORCH_FLAVOR" != "fe" ] && return 0
  [ "${ENABLE_VISUAL_CHECK:-0}" != "1" ] && return 0
  
  if dev_server_running; then
    _log "Dev server already running (PID $(cat "$DEV_SERVER_PID_FILE"))"
    return 0
  fi
  
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  _log "Starting dev server: $DEV_SERVER_CMD"
  cd "$exec_repo" || return 1
  
  # Start dev server in background
  nohup bash -c "$DEV_SERVER_CMD" > /tmp/agent-dev-server.log 2>&1 &
  local pid=$!
  echo "$pid" > "$DEV_SERVER_PID_FILE"
  
  # Wait for server to be ready (max 60 seconds)
  _log "Waiting for dev server on port $DEV_SERVER_PORT..."
  local attempts=0
  while [ "$attempts" -lt 30 ]; do
    if curl -s --max-time 2 "$DEV_SERVER_URL" >/dev/null 2>&1; then
      _log "Dev server ready at $DEV_SERVER_URL"
      return 0
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      _log "Dev server process died. Check /tmp/agent-dev-server.log"
      rm -f "$DEV_SERVER_PID_FILE"
      return 1
    fi
    sleep 2
    attempts=$((attempts + 1))
  done
  
  _log "Dev server did not become ready in time"
  return 1
}

stop_dev_server() {
  [ "$ORCH_FLAVOR" != "fe" ] && return 0
  [ ! -f "${DEV_SERVER_PID_FILE:-}" ] && return 0
  
  local pid
  pid="$(cat "$DEV_SERVER_PID_FILE" 2>/dev/null)" || return 0
  
  if kill -0 "$pid" 2>/dev/null; then
    _log "Stopping dev server (PID $pid)"
    kill "$pid" 2>/dev/null || true
    pkill -P "$pid" 2>/dev/null || true
    sleep 1
    kill -9 "$pid" 2>/dev/null || true
    pkill -9 -P "$pid" 2>/dev/null || true
  fi
  
  rm -f "$DEV_SERVER_PID_FILE"
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP: PICK_TASK
# ──────────────────────────────────────────────────────────────────────────────

# Pick next ready task from beads
# Returns: JSON { "task": "id", "title": "...", "epic": "..." } or empty
step_pick_task() {
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  local ready_json task_id title epic_id
  ready_json="$(cd "$main_repo" && bd ready --json 2>/dev/null || echo "[]")"
  
  # Get first non-epic task
  task_id="$(echo "$ready_json" | jq -r '[.[] | select(.issue_type != "epic")] | first | .id // empty')"
  
  if [ -z "$task_id" ] || [ "$task_id" = "null" ]; then
    echo '{"task":"","title":"","epic":""}'
    return 0
  fi
  
  title="$(echo "$ready_json" | jq -r ".[] | select(.id == \"$task_id\") | .title // \"\"")"
  
  # Get epic by walking dependencies (simplified - just check direct deps for Type: epic)
  local task_details deps
  task_details="$(cd "$main_repo" && bd show "$task_id" 2>/dev/null || true)"
  deps="$(echo "$task_details" | grep -E '→ ' | sed 's/.*→ //' | cut -d: -f1 | tr -d ' ' | head -10)"
  
  epic_id=""
  while IFS=$'\n' read -r d; do
    [ -n "$d" ] || continue
    local d_details
    d_details="$(cd "$main_repo" && bd show "$d" 2>/dev/null || true)"
    if echo "$d_details" | grep -qiE '^\s*(Issue\s*)?Type:\s*epic'; then
      epic_id="$d"
      break
    fi
  done <<< "$deps"
  
  cat <<EOF
{"task":"$task_id","title":"$(echo "$title" | sed 's/"/\\"/g')","epic":"$epic_id"}
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP: PREPARE_BRANCH
# ──────────────────────────────────────────────────────────────────────────────

# Slugify title for branch name
_slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//' | cut -c1-60
}

# Prepare the branch for work
# - If existing branch: checkout and pull
# - If new: create from parent with Graphite
# Returns: JSON { "success": bool, "branch": "...", "error": "..." }
step_prepare_branch() {
  local task="$1" epic_id="$2" title="$3"
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  local base_branch="${BASE_BRANCH:-master}"
  
  cd "$exec_repo"
  git fetch origin --quiet 2>/dev/null || true
  
  # Generate desired branch name
  local slug task_clean branch_name
  slug="$(_slugify "$title")"
  task_clean="$(echo "$task" | sed 's/[^a-zA-Z0-9._\/-]/-/g')"
  
  if [ -n "$epic_id" ]; then
    local epic_clean
    epic_clean="$(echo "$epic_id" | sed 's/[^a-zA-Z0-9._\/-]/-/g')"
    branch_name="epic/${epic_clean}/${task_clean}-${slug}"
  else
    branch_name="agent/${task_clean}-${slug}"
  fi
  
  # Source graphite helpers
  source "$SCRIPT_DIR/graphite.sh" 2>/dev/null || true
  
  # Check for existing branch
  local existing_branch=""
  if [ -n "$epic_id" ]; then
    existing_branch="$(find_task_branch "$epic_id" "$task" 2>/dev/null || true)"
  fi
  
  if [ -n "$existing_branch" ]; then
    # Use existing branch
    _log "Using existing branch: $existing_branch"
    if gt checkout "$existing_branch" --no-interactive >/dev/null 2>&1 || \
       git checkout "$existing_branch" >/dev/null 2>&1; then
      git pull origin "$existing_branch" --rebase >/dev/null 2>&1 || true
      echo "{\"success\":true,\"branch\":\"$existing_branch\",\"error\":\"\"}"
      return 0
    else
      echo "{\"success\":false,\"branch\":\"\",\"error\":\"Failed to checkout existing branch $existing_branch\"}"
      return 1
    fi
  fi
  
  # Create new branch
  _log "Creating new branch: $branch_name"
  
  # Determine parent branch
  local parent_branch="$base_branch"
  if [ -n "$epic_id" ]; then
    # Try to stack on dependency or epic tip
    local dep_parent
    dep_parent="$(find_parent_branch_for_task "$epic_id" "$task" "$MAIN_REPO" 2>/dev/null || true)"
    if [ -n "$dep_parent" ]; then
      parent_branch="$dep_parent"
    else
      local tip
      tip="$(find_epic_tip_branch "$epic_id" 2>/dev/null || true)"
      [ -n "$tip" ] && parent_branch="$tip"
    fi
  fi
  
  # Checkout parent
  if ! gt checkout "$parent_branch" --no-interactive >/dev/null 2>&1; then
    if ! git checkout "$parent_branch" >/dev/null 2>&1; then
      # Parent locked - create temp tracking branch
      local temp_parent="agent-base-${parent_branch//\//-}"
      git fetch origin "$parent_branch" --quiet 2>/dev/null || true
      git branch -D "$temp_parent" >/dev/null 2>&1 || true
      if ! git checkout -b "$temp_parent" "origin/$parent_branch" >/dev/null 2>&1; then
        echo "{\"success\":false,\"branch\":\"\",\"error\":\"Failed to checkout parent $parent_branch\"}"
        return 1
      fi
    fi
  fi
  
  git pull origin "$parent_branch" --rebase >/dev/null 2>&1 || true
  
  # Create branch with Graphite
  local create_err
  if create_err="$(gt create --no-interactive -a "$branch_name" -m "[$task] WIP" 2>&1)"; then
    # Clean up temp branch if used
    git branch -D "agent-base-${parent_branch//\//-}" >/dev/null 2>&1 || true
    echo "{\"success\":true,\"branch\":\"$branch_name\",\"error\":\"\"}"
    return 0
  else
    echo "{\"success\":false,\"branch\":\"\",\"error\":\"gt create failed: $(echo "$create_err" | head -3 | tr '\n' ' ')\"}"
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP: RUN_IMPLEMENTER
# ──────────────────────────────────────────────────────────────────────────────

# Run agent with exponential backoff retries
_run_agent_with_retries() {
  local model="$1" prompt="$2"
  local attempt=0 delay="$RETRY_DELAY_SECS" out="" code=0

  while [ "$attempt" -lt "$MAX_AGENT_RETRIES" ]; do
    _log "Agent attempt $((attempt+1))/$MAX_AGENT_RETRIES (model=$model)"
    set +e
    # Note: timeout removed for macOS compatibility
    out="$("$AGENT_BIN" --model "$model" -p --force "$prompt" 2>&1)"
    code=$?
    set -e

    if [ "$code" -eq 0 ]; then
      printf "%s" "$out"
      return 0
    fi

    if [ "$code" -eq 124 ] || echo "$out" | grep -qi "provider\|rate limit\|503\|502\|500\|timeout\|overloaded\|capacity"; then
      attempt=$((attempt+1))
      _log "Retryable error. Sleeping ${delay}s."
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

# Build implementer prompt
_build_implementer_prompt() {
  local task="$1" title="$2" branch="$3"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  local details
  details="$(cd "$main_repo" && bd show "$task" 2>/dev/null || true)"
  
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
EOF

  # Add visual testing section for FE
  if [ "$ORCH_FLAVOR" = "fe" ] && [ "${ENABLE_VISUAL_CHECK:-0}" = "1" ]; then
    cat <<EOF

═══════════════════════════════════════════════════════════════════════════════
VISUAL TESTING (RECOMMENDED)
═══════════════════════════════════════════════════════════════════════════════
A dev server is running at: ${DEV_SERVER_URL:-http://localhost:8081}

You can use Playwright MCP to test your UI changes:
- playwright_navigate to view affected pages
- playwright_screenshot to capture the current state
- playwright_click, playwright_hover to test interactions

If a Figma link is in the task details, use figma MCP to compare:
- Get the Figma design screenshot
- Verify your implementation matches the design
EOF
  fi

  cat <<EOF

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

# Run the implementer agent
# Returns: JSON { "success": bool, "result": "success|blocked|no_changes", "error": "..." }
step_run_implementer() {
  local task="$1" title="$2" branch="$3"
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  
  cd "$exec_repo"
  
  # Record baseline HEAD
  local baseline_head
  baseline_head="$(git rev-parse HEAD 2>/dev/null || echo "")"
  
  local prompt
  prompt="$(_build_implementer_prompt "$task" "$title" "$branch")"
  
  local out
  out="$(_run_agent_with_retries "$IMPLEMENTER_MODEL" "$prompt" || true)"
  
  # Check if agent reported blocked
  if echo "$out" | grep -q "^STATUS: BLOCKED"; then
    local reason
    reason="$(echo "$out" | grep -A20 "^REASON:" | head -20 | tr '\n' ' ')"
    echo "{\"success\":false,\"result\":\"blocked\",\"error\":\"$reason\"}"
    return 1
  fi
  
  # Check for changes
  local uncommitted new_commits
  uncommitted="$(git status --porcelain 2>/dev/null | grep -v '\.beads/' | grep -v '\.claude/' | grep -v '\.cursor/rules/personal/' | wc -l | tr -d ' ')"
  
  new_commits=0
  if [ -n "$baseline_head" ] && [ "$(git rev-parse HEAD 2>/dev/null)" != "$baseline_head" ]; then
    new_commits="$(git rev-list --count "${baseline_head}..HEAD" 2>/dev/null || echo 0)"
  fi
  
  if [ "$uncommitted" -gt 0 ] || [ "$new_commits" -gt 0 ]; then
    echo "{\"success\":true,\"result\":\"success\",\"error\":\"\",\"uncommitted\":$uncommitted,\"new_commits\":$new_commits}"
    return 0
  else
    echo "{\"success\":false,\"result\":\"no_changes\",\"error\":\"Agent produced no changes\"}"
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP: CHECK_COMPLETE (optional visual verification)
# ──────────────────────────────────────────────────────────────────────────────

# Build checker prompt with optional visual verification
_build_checker_prompt() {
  local task="$1" title="$2" diffstat="$3" difftext="$4"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  local details
  details="$(cd "$main_repo" && bd show "$task" 2>/dev/null || true)"
  
  # Add visual verification section for FE
  local visual_section=""
  if [ "$ORCH_FLAVOR" = "fe" ] && [ "${ENABLE_VISUAL_CHECK:-0}" = "1" ]; then
    visual_section="
═══════════════════════════════════════════════════════════════════════════════
VISUAL VERIFICATION (REQUIRED for UI changes)
═══════════════════════════════════════════════════════════════════════════════

A dev server is running at: ${DEV_SERVER_URL:-http://localhost:8081}

Use Playwright MCP to verify the UI changes visually:

1. Navigate to the relevant page/component:
   playwright_navigate to ${DEV_SERVER_URL:-http://localhost:8081}/<path-to-affected-page>

2. Take a screenshot:
   playwright_screenshot with name 'after-changes'

3. If a Figma link is in the task, compare the screenshot to the Figma design:
   - Use figma MCP to get the design screenshot
   - Compare layouts, colors, spacing, typography

4. Test interactions if applicable:
   - playwright_click on interactive elements
   - playwright_hover to test hover states
   - Take screenshots of different states

Report visual issues in blocking_gaps with evidence from screenshots.
"
  fi

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
$visual_section
═══════════════════════════════════════════════════════════════════════════════
OUTPUT FORMAT
═══════════════════════════════════════════════════════════════════════════════

Return ONLY valid JSON (no markdown fences, no commentary) with schema:
{
  "complete": boolean,
  "confidence": number,
  "visual_verified": boolean,
  "blocking_gaps": [{"ac": string, "issue": string, "evidence": string}],
  "suggested_edits": [{"issue": string, "evidence": string}]
}

Rules:
- If any acceptance criterion is not clearly satisfied, complete=false.
- For UI changes: visual_verified must be true (you used Playwright to check).
- Prefer evidence-based blocking_gaps.
- Do not expand scope beyond acceptance criteria.
EOF
}

# Run optional checker step
# Returns: JSON { "success": bool, "complete": bool, "confidence": number }
step_check_complete() {
  local task="$1" title="$2"
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  local checker_model="${CHECKER_MODEL:-gemini-3-flash}"
  
  cd "$exec_repo"
  
  # Get diff for context
  local diffstat difftext
  diffstat="$(git diff --stat HEAD~1 2>/dev/null || git diff --stat 2>/dev/null || echo 'No diff available')"
  local diff_full
  diff_full="$(git diff HEAD~1 2>/dev/null || git diff 2>/dev/null || echo '')"
  local diff_head diff_tail
  diff_head="$(echo "$diff_full" | head -1200)"
  diff_tail="$(echo "$diff_full" | tail -400)"
  difftext="${diff_head}"$'\n...\n'"${diff_tail}"
  
  local prompt
  prompt="$(_build_checker_prompt "$task" "$title" "$diffstat" "$difftext")"
  
  local out
  out="$(_run_agent_with_retries "$checker_model" "$prompt" || true)"
  
  # Parse response
  local complete conf
  if echo "$out" | jq -e . >/dev/null 2>&1; then
    complete="$(echo "$out" | jq -r '.complete // false')"
    conf="$(echo "$out" | jq -r '.confidence // 0')"
    echo "{\"success\":true,\"complete\":$complete,\"confidence\":$conf}"
  else
    # Failed to parse - assume complete
    echo '{"success":false,"complete":true,"confidence":0.5}'
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP: VALIDATE
# ──────────────────────────────────────────────────────────────────────────────

# Run validation command
# Returns: JSON { "success": bool, "error": "..." }
step_validate() {
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  
  cd "$exec_repo"
  _log "Validating: $VALIDATE_CMD"
  
  local output
  set +e
  output="$(bash -c "$VALIDATE_CMD" 2>&1)"
  local code=$?
  set -e
  
  if [ "$code" -eq 0 ]; then
    echo '{"success":true,"error":""}'
    return 0
  else
    local tail_output
    tail_output="$(echo "$output" | tail -100 | tr '\n' ' ' | sed 's/"/\\"/g')"
    echo "{\"success\":false,\"error\":\"$tail_output\"}"
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP: SUBMIT_PR
# ──────────────────────────────────────────────────────────────────────────────

# Stage changes safely (exclude config dirs)
_stage_safely() {
  if git add -A -- ":(exclude).beads" ":(exclude).claude" ":(exclude).cursor/rules/personal" >/dev/null 2>&1; then
    return 0
  fi
  git add -A
  git reset HEAD .beads/ .claude/ .cursor/rules/personal/ 2>/dev/null || true
}

# Submit PR for current work
# Returns: JSON { "success": bool, "pr_number": "...", "error": "..." }
step_submit_pr() {
  local task="$1" title="$2"
  local exec_repo="${EXEC_REPO:-$(pwd)}"
  
  cd "$exec_repo"
  
  # Check if there are uncommitted changes to commit first
  local uncommitted
  uncommitted="$(git status --porcelain 2>/dev/null | grep -v '\.beads/' | grep -v '\.claude/' | grep -v '\.cursor/rules/personal/' | wc -l | tr -d ' ')"
  
  if [ "$uncommitted" -gt 0 ]; then
    _log "Committing $uncommitted uncommitted changes"
    _stage_safely
    if ! gt modify --no-interactive -a -m "[$task] $title" >/dev/null 2>&1; then
      echo '{"success":false,"pr_number":"","error":"gt modify failed"}'
      return 1
    fi
  fi
  
  # Submit PR
  _log "Submitting PR"
  local output pr_num
  set +e
  output="$(gt submit --no-interactive --draft --no-edit --ai 2>&1)"
  local code=$?
  set -e
  
  if [ "$code" -ne 0 ]; then
    local tail_output
    tail_output="$(echo "$output" | tail -50 | tr '\n' ' ' | sed 's/"/\\"/g')"
    echo "{\"success\":false,\"pr_number\":\"\",\"error\":\"$tail_output\"}"
    return 1
  fi
  
  pr_num="$(echo "$output" | grep -oE '#[0-9]+' | head -1 | tr -d '#' || true)"
  echo "{\"success\":true,\"pr_number\":\"${pr_num:-unknown}\",\"error\":\"\"}"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP: CLOSE_BEAD
# ──────────────────────────────────────────────────────────────────────────────

# Close the bead with reason
# Returns: JSON { "success": bool }
step_close_bead() {
  local task="$1" reason="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  if (cd "$main_repo" && bd close "$task" --reason "$reason" 2>/dev/null); then
    echo '{"success":true}'
    return 0
  else
    echo '{"success":false}'
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# STEP: BLOCK_BEAD
# ──────────────────────────────────────────────────────────────────────────────

# Block the bead with reason
step_block_bead() {
  local task="$1" reason="$2"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd update "$task" --status blocked --notes "$reason" 2>/dev/null) || true
  echo '{"success":true}'
}
