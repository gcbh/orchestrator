#!/usr/bin/env bash
# validation_pipeline.sh - Multi-stage validation with auto-fix capabilities
#
# Stages:
#   1. LINT     - Style/formatting (fast, auto-fixable)
#   2. TYPECHECK - Type errors (medium, sometimes auto-fixable)
#   3. TEST     - Unit tests (slow, requires agent fix)
#   4. REVIEW   - LLM self-review (optional)
#

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Which stages to run (space-separated)
VALIDATION_STAGES="${VALIDATION_STAGES:-lint typecheck}"

# Commands per stage (override per project)
LINT_CMD="${LINT_CMD:-}"
LINT_FIX_CMD="${LINT_FIX_CMD:-}"
TYPECHECK_CMD="${TYPECHECK_CMD:-}"
TEST_CMD="${TEST_CMD:-}"
TEST_AFFECTED_CMD="${TEST_AFFECTED_CMD:-}"  # Run only tests for changed files

# Auto-fix settings
AUTO_FIX_LINT="${AUTO_FIX_LINT:-1}"
AUTO_FIX_TYPECHECK="${AUTO_FIX_TYPECHECK:-0}"  # Usually needs agent
MAX_AUTO_FIX_ATTEMPTS="${MAX_AUTO_FIX_ATTEMPTS:-2}"

# LLM review settings
ENABLE_SELF_REVIEW="${ENABLE_SELF_REVIEW:-0}"
SELF_REVIEW_MODEL="${SELF_REVIEW_MODEL:-sonnet-4}"

# Test settings
RUN_AFFECTED_TESTS_ONLY="${RUN_AFFECTED_TESTS_ONLY:-1}"
TEST_TIMEOUT_SECS="${TEST_TIMEOUT_SECS:-300}"

# Output
VALIDATION_LOG="${VALIDATION_LOG:-/tmp/validation-pipeline.log}"

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────────────────────────────────────

_vlog() { 
  echo "$(date): [validation] $*" | tee -a "$VALIDATION_LOG" >&2
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE: LINT
# ──────────────────────────────────────────────────────────────────────────────

_get_changed_files() {
  local ext="${1:-}"
  local base_ref="${2:-HEAD~1}"
  
  if [ -n "$ext" ]; then
    git diff --name-only "$base_ref" HEAD 2>/dev/null | grep -E "\\.${ext}$" || true
  else
    git diff --name-only "$base_ref" HEAD 2>/dev/null || true
  fi
}

stage_lint() {
  _vlog "=== STAGE: LINT ==="
  
  if [ -z "$LINT_CMD" ]; then
    _vlog "No LINT_CMD configured, skipping"
    return 0
  fi
  
  local attempt=0
  while [ "$attempt" -lt "$MAX_AUTO_FIX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    _vlog "Lint attempt $attempt/$MAX_AUTO_FIX_ATTEMPTS"
    
    # Run lint
    local lint_output lint_code
    lint_output="$(bash -c "$LINT_CMD" 2>&1)"
    lint_code=$?
    
    if [ "$lint_code" -eq 0 ]; then
      _vlog "Lint passed ✓"
      return 0
    fi
    
    # Try auto-fix if enabled
    if [ "$AUTO_FIX_LINT" = "1" ] && [ -n "$LINT_FIX_CMD" ] && [ "$attempt" -lt "$MAX_AUTO_FIX_ATTEMPTS" ]; then
      _vlog "Lint failed, attempting auto-fix..."
      bash -c "$LINT_FIX_CMD" >/dev/null 2>&1 || true
      
      # Stage fixed files
      git add -A 2>/dev/null || true
      continue
    fi
    
    _vlog "Lint failed:"
    echo "$lint_output" | tail -30 | tee -a "$VALIDATION_LOG" >&2
    return 1
  done
  
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE: TYPECHECK
# ──────────────────────────────────────────────────────────────────────────────

stage_typecheck() {
  _vlog "=== STAGE: TYPECHECK ==="
  
  if [ -z "$TYPECHECK_CMD" ]; then
    _vlog "No TYPECHECK_CMD configured, skipping"
    return 0
  fi
  
  local output code
  output="$(bash -c "$TYPECHECK_CMD" 2>&1)"
  code=$?
  
  if [ "$code" -eq 0 ]; then
    _vlog "Typecheck passed ✓"
    return 0
  fi
  
  _vlog "Typecheck failed:"
  echo "$output" | tail -50 | tee -a "$VALIDATION_LOG" >&2
  
  # Return structured error for agent to fix
  echo "$output"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE: TEST
# ──────────────────────────────────────────────────────────────────────────────

stage_test() {
  _vlog "=== STAGE: TEST ==="
  
  if [ -z "$TEST_CMD" ] && [ -z "$TEST_AFFECTED_CMD" ]; then
    _vlog "No TEST_CMD configured, skipping"
    return 0
  fi
  
  local test_cmd="$TEST_CMD"
  
  # Use affected-only tests if enabled and available
  if [ "$RUN_AFFECTED_TESTS_ONLY" = "1" ] && [ -n "$TEST_AFFECTED_CMD" ]; then
    local changed_files
    changed_files="$(_get_changed_files)"
    
    if [ -n "$changed_files" ]; then
      _vlog "Running tests for affected files only"
      test_cmd="$TEST_AFFECTED_CMD"
    else
      _vlog "No changed files, skipping tests"
      return 0
    fi
  fi
  
  local output code
  output="$(timeout "$TEST_TIMEOUT_SECS" bash -c "$test_cmd" 2>&1)"
  code=$?
  
  if [ "$code" -eq 0 ]; then
    _vlog "Tests passed ✓"
    return 0
  fi
  
  if [ "$code" -eq 124 ]; then
    _vlog "Tests timed out after ${TEST_TIMEOUT_SECS}s"
  else
    _vlog "Tests failed:"
  fi
  
  echo "$output" | tail -100 | tee -a "$VALIDATION_LOG" >&2
  echo "$output"
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# STAGE: SELF-REVIEW (LLM)
# ──────────────────────────────────────────────────────────────────────────────

_build_self_review_prompt() {
  local task="$1"
  local diff="$2"
  
  cat <<EOF
You just implemented a code change. Now review your own work critically.

TASK: $task

YOUR CHANGES:
$diff

REVIEW CHECKLIST:
1. Does the code handle edge cases? (null, empty, undefined)
2. Are there any obvious bugs or logic errors?
3. Is error handling adequate?
4. Are there any security concerns?
5. Does the code follow the project's patterns?
6. Should there be unit tests for this change?

OUTPUT FORMAT:
Return JSON:
{
  "approved": boolean,
  "issues": [{"severity": "high|medium|low", "description": "...", "suggestion": "..."}],
  "missing_tests": boolean,
  "test_suggestions": ["..."]
}

If approved=false, list blocking issues.
If missing_tests=true, suggest what tests to add.
EOF
}

stage_self_review() {
  local task="$1"
  
  _vlog "=== STAGE: SELF-REVIEW ==="
  
  if [ "$ENABLE_SELF_REVIEW" != "1" ]; then
    _vlog "Self-review disabled, skipping"
    return 0
  fi
  
  # Get diff
  local diff
  diff="$(git diff HEAD~1 --stat 2>/dev/null; echo '---'; git diff HEAD~1 2>/dev/null | head -500)"
  
  if [ -z "$diff" ]; then
    _vlog "No diff to review"
    return 0
  fi
  
  local prompt
  prompt="$(_build_self_review_prompt "$task" "$diff")"
  
  # Call LLM (requires run_agent_cli from cli_adapter.sh)
  if type run_agent_cli >/dev/null 2>&1; then
    local review_output
    review_output="$(run_agent_cli "$SELF_REVIEW_MODEL" "$prompt" 2>/dev/null)"
    
    # Parse response
    if echo "$review_output" | grep -q '"approved":\s*false'; then
      _vlog "Self-review found issues:"
      echo "$review_output" | tee -a "$VALIDATION_LOG" >&2
      echo "$review_output"
      return 1
    fi
    
    _vlog "Self-review passed ✓"
    return 0
  else
    _vlog "CLI adapter not loaded, skipping self-review"
    return 0
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# PIPELINE RUNNER
# ──────────────────────────────────────────────────────────────────────────────

# Run full validation pipeline
# Usage: run_validation_pipeline [task_id]
# Returns: 0 if all stages pass, 1 if any fail
# Outputs: JSON with results
run_validation_pipeline() {
  local task="${1:-}"
  
  _vlog "Starting validation pipeline for task: ${task:-unknown}"
  _vlog "Stages: $VALIDATION_STAGES"
  
  local results="{\"passed\":true,\"stages\":{"
  local all_passed=true
  local failed_stage=""
  local error_output=""
  
  for stage in $VALIDATION_STAGES; do
    local stage_passed=true
    local stage_output=""
    
    case "$stage" in
      lint)
        stage_output="$(stage_lint 2>&1)" || stage_passed=false
        ;;
      typecheck)
        stage_output="$(stage_typecheck 2>&1)" || stage_passed=false
        ;;
      test)
        stage_output="$(stage_test 2>&1)" || stage_passed=false
        ;;
      review|self-review)
        stage_output="$(stage_self_review "$task" 2>&1)" || stage_passed=false
        ;;
      *)
        _vlog "Unknown stage: $stage"
        continue
        ;;
    esac
    
    if [ "$stage_passed" = "true" ]; then
      results="${results}\"$stage\":\"passed\","
    else
      results="${results}\"$stage\":\"failed\","
      all_passed=false
      failed_stage="$stage"
      error_output="$stage_output"
      break  # Stop on first failure
    fi
  done
  
  # Close JSON
  results="${results%,}}"  # Remove trailing comma
  
  if [ "$all_passed" = "true" ]; then
    results="${results},\"passed\":true}"
    _vlog "Pipeline passed ✓"
  else
    # Escape error output for JSON
    local escaped_error
    escaped_error="$(echo "$error_output" | head -50 | sed 's/"/\\"/g' | tr '\n' ' ')"
    results="${results},\"passed\":false,\"failed_stage\":\"$failed_stage\",\"error\":\"$escaped_error\"}"
    _vlog "Pipeline failed at stage: $failed_stage"
  fi
  
  echo "$results"
  [ "$all_passed" = "true" ]
}

# ──────────────────────────────────────────────────────────────────────────────
# FIX LOOP
# ──────────────────────────────────────────────────────────────────────────────

# Run validation with agent fix loop
# Usage: run_validation_with_fixes <task_id> <max_attempts>
# This will run validation, and if it fails, ask the agent to fix
run_validation_with_fixes() {
  local task="$1"
  local max_attempts="${2:-3}"
  local attempt=0
  
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    _vlog "Validation attempt $attempt/$max_attempts"
    
    local result
    result="$(run_validation_pipeline "$task")"
    
    if echo "$result" | grep -q '"passed":true'; then
      echo "$result"
      return 0
    fi
    
    # Extract failed stage and error
    local failed_stage error_msg
    failed_stage="$(echo "$result" | grep -o '"failed_stage":"[^"]*"' | cut -d'"' -f4)"
    error_msg="$(echo "$result" | grep -o '"error":"[^"]*"' | cut -d'"' -f4)"
    
    if [ "$attempt" -ge "$max_attempts" ]; then
      _vlog "Max fix attempts reached"
      echo "$result"
      return 1
    fi
    
    # Ask agent to fix (if cli_adapter available)
    if type run_agent_cli >/dev/null 2>&1; then
      _vlog "Asking agent to fix $failed_stage errors..."
      
      local fix_prompt
      fix_prompt="$(cat <<EOF
The $failed_stage validation failed. Fix the errors below.

ERROR OUTPUT:
$error_msg

INSTRUCTIONS:
1. Read the error messages carefully
2. Fix ONLY the errors shown - don't change unrelated code
3. After fixing, the validation will run again

Do NOT run any commands - just fix the code.
EOF
)"
      
      run_agent_cli "${IMPLEMENTER_MODEL:-sonnet-4}" "$fix_prompt" >/dev/null 2>&1 || true
    else
      _vlog "No CLI adapter, cannot auto-fix"
      echo "$result"
      return 1
    fi
  done
  
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# PROJECT PRESETS
# ──────────────────────────────────────────────────────────────────────────────

# Load preset for a project type
# Usage: load_validation_preset <type>
load_validation_preset() {
  local preset="$1"
  
  case "$preset" in
    fe|frontend|pacific)
      VALIDATION_STAGES="lint typecheck"
      LINT_CMD="pnpm run lint 2>&1 || true"
      LINT_FIX_CMD="pnpm run lint --fix 2>&1 || true"
      TYPECHECK_CMD="pnpm run typecheck"
      TEST_CMD="pnpm run test"
      TEST_AFFECTED_CMD="pnpm run test --changed"
      AUTO_FIX_LINT=1
      ;;
      
    be|backend|python)
      VALIDATION_STAGES="lint typecheck test"
      LINT_CMD="make lint 2>&1"
      LINT_FIX_CMD="make fmt 2>&1"
      TYPECHECK_CMD="make typecheck 2>&1 || mypy src/ 2>&1"
      TEST_CMD="make test"
      TEST_AFFECTED_CMD="pytest --last-failed 2>&1"
      AUTO_FIX_LINT=1
      ;;
      
    minimal)
      VALIDATION_STAGES="typecheck"
      TYPECHECK_CMD="${VALIDATE_CMD:-echo 'No typecheck configured'}"
      ;;
      
    full)
      VALIDATION_STAGES="lint typecheck test review"
      ENABLE_SELF_REVIEW=1
      ;;
      
    *)
      _vlog "Unknown preset: $preset"
      return 1
      ;;
  esac
  
  _vlog "Loaded preset: $preset"
  _vlog "Stages: $VALIDATION_STAGES"
}
