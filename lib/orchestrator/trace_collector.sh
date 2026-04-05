#!/usr/bin/env bash
# trace_collector.sh - Structured execution trace collection for meta-optimization
#
# Inspired by the Meta-Harness paper (Lee et al., 2026), which shows that
# storing structured per-task execution traces (source code, scores, agent
# outputs, validation results) in a filesystem enables an agentic proposer
# to diagnose failures and improve the harness with long-horizon credit
# assignment.
#
# This module captures structured, machine-readable traces for every task
# the orchestrator processes, storing them in a per-task directory that
# includes: configuration snapshot, agent prompts/outputs, validation
# results, reviewer verdicts, confidence scores, failure classifications,
# and timing data.
#
# Usage:
#   source trace_collector.sh
#   trace_init "$TASK" "$EPIC_ID"
#   trace_event "implement" "start" ""
#   trace_agent_call "implementer" "$MODEL" "$PROMPT" "$OUTPUT" "$EXIT_CODE" "$DURATION_SECS"
#   trace_validation "lint" "pass" "" "3.2"
#   trace_review "$REVIEW_JSON"
#   trace_checker "$CHECK_JSON"
#   trace_failure "$STEP" "$CLASS" "$ACTION" "$ERROR"
#   trace_finalize "success" "$PR_NUMBER"

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Root directory for all traces
TRACE_ROOT="${TRACE_ROOT:-${HOME}/.local/share/orchestrator/traces}"

# Max lines of agent output to capture (keep traces manageable)
TRACE_MAX_OUTPUT_LINES="${TRACE_MAX_OUTPUT_LINES:-500}"

# Whether tracing is enabled
TRACE_ENABLED="${TRACE_ENABLED:-1}"

# ──────────────────────────────────────────────────────────────────────────────
# STATE
# ──────────────────────────────────────────────────────────────────────────────

_TRACE_DIR=""
_TRACE_TASK=""
_TRACE_START_TS=""
_TRACE_EVENT_SEQ=0

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────

_tlog() { echo "$(date): [trace] $*" >&2; }

_ts() { date +%s; }

_ts_iso() { date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z"; }

_json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

# ──────────────────────────────────────────────────────────────────────────────
# INITIALIZATION
# ──────────────────────────────────────────────────────────────────────────────

# Initialize tracing for a task run.
# Creates: $TRACE_ROOT/<task>/<timestamp>/
trace_init() {
  [ "${TRACE_ENABLED:-1}" = "1" ] || return 0

  local task="$1"
  local epic_id="${2:-}"

  _TRACE_TASK="$task"
  _TRACE_START_TS="$(_ts)"
  _TRACE_EVENT_SEQ=0

  local run_ts
  run_ts="$(date +%Y%m%d-%H%M%S)"
  _TRACE_DIR="${TRACE_ROOT}/${task}/${run_ts}"

  mkdir -p "$_TRACE_DIR"/{agents,validation,events}

  # Snapshot the harness configuration
  cat > "$_TRACE_DIR/config.json" <<EOF
{
  "task": "$(_json_escape "$task")",
  "epic_id": "$(_json_escape "${epic_id:-}")",
  "run_timestamp": "$(_ts_iso)",
  "flavor": "$(_json_escape "${ORCH_FLAVOR:-be}")",
  "harness_config": {
    "implementer_model": "$(_json_escape "${IMPLEMENTER_MODEL:-}")",
    "checker_model": "$(_json_escape "${CHECKER_MODEL:-}")",
    "reviewer_model": "$(_json_escape "${REVIEWER_MODEL:-}")",
    "agent_cli": "$(_json_escape "${AGENT_CLI:-auto}")",
    "validate_cmd": "$(_json_escape "${VALIDATE_CMD:-}")",
    "enable_checker": "${ENABLE_CHECKER:-1}",
    "checker_conf_threshold": "${CHECKER_CONF_THRESHOLD:-0.70}",
    "enable_reviewer": "${ENABLE_REVIEWER:-1}",
    "review_depth": "$(_json_escape "${REVIEW_DEPTH:-standard}")",
    "reviewer_can_fix": "${REVIEWER_CAN_FIX:-0}",
    "max_repair_attempts": "${MAX_REPAIR_ATTEMPTS:-1}",
    "max_review_fix_attempts": "${MAX_REVIEW_FIX_ATTEMPTS:-2}",
    "max_agent_retries": "${MAX_AGENT_RETRIES:-10}",
    "agent_timeout_secs": "${AGENT_TIMEOUT_SECS:-1800}",
    "validation_stages": "$(_json_escape "${VALIDATION_STAGES:-lint typecheck}")"
  }
}
EOF

  _tlog "Trace initialized: $_TRACE_DIR"
}

# ──────────────────────────────────────────────────────────────────────────────
# EVENT RECORDING
# ──────────────────────────────────────────────────────────────────────────────

# Record a generic pipeline event (state transition, retry, etc.)
trace_event() {
  [ "${TRACE_ENABLED:-1}" = "1" ] || return 0
  [ -n "$_TRACE_DIR" ] || return 0

  local step="$1" action="$2" detail="${3:-}"

  _TRACE_EVENT_SEQ=$((_TRACE_EVENT_SEQ + 1))
  local seq
  seq="$(printf '%04d' "$_TRACE_EVENT_SEQ")"

  cat > "$_TRACE_DIR/events/${seq}-${step}-${action}.json" <<EOF
{
  "seq": $_TRACE_EVENT_SEQ,
  "timestamp": "$(_ts_iso)",
  "elapsed_secs": $(( $(_ts) - _TRACE_START_TS )),
  "step": "$(_json_escape "$step")",
  "action": "$(_json_escape "$action")",
  "detail": "$(_json_escape "$detail")"
}
EOF
}

# Record an agent call with prompt, output, and timing
trace_agent_call() {
  [ "${TRACE_ENABLED:-1}" = "1" ] || return 0
  [ -n "$_TRACE_DIR" ] || return 0

  local role="$1" model="$2" prompt="$3" output="$4" exit_code="$5" duration_secs="${6:-0}"

  _TRACE_EVENT_SEQ=$((_TRACE_EVENT_SEQ + 1))
  local seq
  seq="$(printf '%04d' "$_TRACE_EVENT_SEQ")"
  local agent_dir="$_TRACE_DIR/agents/${seq}-${role}"
  mkdir -p "$agent_dir"

  # Store prompt and output as separate files (can be large)
  printf '%s' "$prompt" > "$agent_dir/prompt.txt"
  printf '%s' "$output" | tail -n "${TRACE_MAX_OUTPUT_LINES}" > "$agent_dir/output.txt"

  cat > "$agent_dir/meta.json" <<EOF
{
  "seq": $_TRACE_EVENT_SEQ,
  "timestamp": "$(_ts_iso)",
  "elapsed_secs": $(( $(_ts) - _TRACE_START_TS )),
  "role": "$(_json_escape "$role")",
  "model": "$(_json_escape "$model")",
  "exit_code": $exit_code,
  "duration_secs": $duration_secs,
  "prompt_chars": ${#prompt},
  "output_chars": ${#output}
}
EOF

  trace_event "agent_call" "$role" "model=$model exit=$exit_code duration=${duration_secs}s"
}

# Record validation stage result
trace_validation() {
  [ "${TRACE_ENABLED:-1}" = "1" ] || return 0
  [ -n "$_TRACE_DIR" ] || return 0

  local stage="$1" result="$2" output="${3:-}" duration_secs="${4:-0}"

  _TRACE_EVENT_SEQ=$((_TRACE_EVENT_SEQ + 1))
  local seq
  seq="$(printf '%04d' "$_TRACE_EVENT_SEQ")"

  # Truncate large validation output
  local truncated_output
  truncated_output="$(printf '%s' "$output" | tail -n 100)"

  cat > "$_TRACE_DIR/validation/${seq}-${stage}.json" <<EOF
{
  "seq": $_TRACE_EVENT_SEQ,
  "timestamp": "$(_ts_iso)",
  "elapsed_secs": $(( $(_ts) - _TRACE_START_TS )),
  "stage": "$(_json_escape "$stage")",
  "result": "$(_json_escape "$result")",
  "duration_secs": $duration_secs,
  "output": "$(_json_escape "$truncated_output")"
}
EOF

  trace_event "validation" "$stage" "result=$result"
}

# Record reviewer verdict
trace_review() {
  [ "${TRACE_ENABLED:-1}" = "1" ] || return 0
  [ -n "$_TRACE_DIR" ] || return 0

  local review_json="$1" attempt="${2:-1}"

  printf '%s' "$review_json" > "$_TRACE_DIR/review-attempt-${attempt}.json"

  local approved
  approved="$(echo "$review_json" | grep -o '"approved":\s*[a-z]*' | head -1 | grep -o 'true\|false' || echo "unknown")"
  trace_event "review" "attempt-${attempt}" "approved=$approved"
}

# Record checker verdict
trace_checker() {
  [ "${TRACE_ENABLED:-1}" = "1" ] || return 0
  [ -n "$_TRACE_DIR" ] || return 0

  local check_json="$1" attempt="${2:-1}"

  printf '%s' "$check_json" > "$_TRACE_DIR/checker-attempt-${attempt}.json"

  local complete conf
  complete="$(echo "$check_json" | jq -r '.complete // "unknown"' 2>/dev/null || echo "unknown")"
  conf="$(echo "$check_json" | jq -r '.confidence // 0' 2>/dev/null || echo "0")"
  trace_event "checker" "attempt-${attempt}" "complete=$complete confidence=$conf"
}

# Record failure classification
trace_failure() {
  [ "${TRACE_ENABLED:-1}" = "1" ] || return 0
  [ -n "$_TRACE_DIR" ] || return 0

  local step="$1" failure_class="$2" remediation_action="${3:-}" error_output="${4:-}"

  _TRACE_EVENT_SEQ=$((_TRACE_EVENT_SEQ + 1))
  local seq
  seq="$(printf '%04d' "$_TRACE_EVENT_SEQ")"

  cat > "$_TRACE_DIR/events/${seq}-failure-${step}.json" <<EOF
{
  "seq": $_TRACE_EVENT_SEQ,
  "timestamp": "$(_ts_iso)",
  "elapsed_secs": $(( $(_ts) - _TRACE_START_TS )),
  "type": "failure",
  "step": "$(_json_escape "$step")",
  "failure_class": "$(_json_escape "$failure_class")",
  "remediation_action": "$(_json_escape "$remediation_action")",
  "error_excerpt": "$(_json_escape "$(printf '%s' "$error_output" | tail -n 50)")"
}
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# FINALIZATION
# ──────────────────────────────────────────────────────────────────────────────

# Finalize the trace with outcome summary
trace_finalize() {
  [ "${TRACE_ENABLED:-1}" = "1" ] || return 0
  [ -n "$_TRACE_DIR" ] || return 0

  local outcome="$1" pr_number="${2:-}" notes="${3:-}"
  local end_ts
  end_ts="$(_ts)"
  local total_secs=$((end_ts - _TRACE_START_TS))

  # Count agent calls, validation stages, failures
  local agent_calls validation_stages failures
  agent_calls="$(find "$_TRACE_DIR/agents" -name "meta.json" 2>/dev/null | wc -l | tr -d ' ')"
  validation_stages="$(find "$_TRACE_DIR/validation" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')"
  failures="$(find "$_TRACE_DIR/events" -name "*-failure-*" 2>/dev/null | wc -l | tr -d ' ')"

  # Capture git diff stats
  local diff_stats=""
  if command -v git >/dev/null 2>&1; then
    diff_stats="$(git diff --stat HEAD~1 HEAD 2>/dev/null | tail -1 || true)"
  fi

  cat > "$_TRACE_DIR/outcome.json" <<EOF
{
  "task": "$(_json_escape "$_TRACE_TASK")",
  "outcome": "$(_json_escape "$outcome")",
  "pr_number": "$(_json_escape "${pr_number:-}")",
  "total_duration_secs": $total_secs,
  "total_events": $_TRACE_EVENT_SEQ,
  "agent_calls": $agent_calls,
  "validation_stages": $validation_stages,
  "failures": $failures,
  "diff_stats": "$(_json_escape "$diff_stats")",
  "notes": "$(_json_escape "$notes")",
  "finalized_at": "$(_ts_iso)"
}
EOF

  _tlog "Trace finalized: outcome=$outcome duration=${total_secs}s events=$_TRACE_EVENT_SEQ ($_TRACE_DIR)"
}

# ──────────────────────────────────────────────────────────────────────────────
# QUERY HELPERS (for meta-harness proposer)
# ──────────────────────────────────────────────────────────────────────────────

# Get the trace directory for the current run
trace_get_dir() {
  echo "$_TRACE_DIR"
}

# List all trace runs for a given task, most recent first
trace_list_runs() {
  local task="${1:-}"
  if [ -n "$task" ]; then
    ls -1dr "${TRACE_ROOT}/${task}/"*/ 2>/dev/null || true
  else
    # All tasks, all runs
    find "$TRACE_ROOT" -name "outcome.json" -exec dirname {} \; 2>/dev/null | sort -r || true
  fi
}

# Summarize outcomes across all traces (for meta-analysis)
trace_summary() {
  local limit="${1:-50}"

  find "$TRACE_ROOT" -name "outcome.json" -newer "$TRACE_ROOT" -o -name "outcome.json" 2>/dev/null \
    | sort -r | head -n "$limit" \
    | while read -r f; do
        jq -c '{task: .task, outcome: .outcome, duration: .total_duration_secs, failures: .failures, pr: .pr_number}' "$f" 2>/dev/null
      done
}
