#!/usr/bin/env bash
# meta_harness.sh - Meta-optimization loop for the orchestrator harness
#
# Implements the core idea from "Meta-Harness: End-to-End Optimization of
# Model Harnesses" (Lee et al., 2026): treat the harness itself as the
# optimization target, using an agentic proposer that reads structured
# execution traces to propose harness improvements.
#
# Architecture:
#   1. ANALYZE  - Proposer reads the trace filesystem (configs, agent outputs,
#                 validation results, failure classifications, outcomes)
#   2. PROPOSE  - Proposer generates a concrete harness diff (config changes,
#                 prompt rewrites, pipeline adjustments)
#   3. EVALUATE - Run N tasks with the proposed harness variant
#   4. SCORE    - Compare variant outcomes against baseline
#   5. ADOPT    - If variant improves on baseline, make it the new default
#
# The filesystem stores every candidate harness and its evaluation results,
# giving the proposer full diagnostic context for credit assignment.
#
# Usage:
#   source meta_harness.sh
#   mh_run_optimization_cycle

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Root for meta-harness data (candidates, evaluations, proposals)
MH_ROOT="${MH_ROOT:-${HOME}/.local/share/orchestrator/meta-harness}"

# Trace root (where trace_collector.sh writes)
TRACE_ROOT="${TRACE_ROOT:-${HOME}/.local/share/orchestrator/traces}"

# Proposer model (should be strong at code analysis)
MH_PROPOSER_MODEL="${MH_PROPOSER_MODEL:-opus-4.5-thinking}"

# Minimum traces needed before proposing improvements
MH_MIN_TRACES="${MH_MIN_TRACES:-10}"

# Number of tasks to evaluate each candidate on
MH_EVAL_TASK_COUNT="${MH_EVAL_TASK_COUNT:-5}"

# Minimum improvement to adopt (percentage points)
MH_ADOPTION_THRESHOLD="${MH_ADOPTION_THRESHOLD:-5}"

# Max candidates to keep in history
MH_MAX_HISTORY="${MH_MAX_HISTORY:-50}"

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────

_mhlog() { echo "$(date): [meta-harness] $*" >&2; }

_json_escape_mh() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

# ──────────────────────────────────────────────────────────────────────────────
# FILESYSTEM MANAGEMENT
# ──────────────────────────────────────────────────────────────────────────────

# Initialize the meta-harness filesystem
mh_init() {
  mkdir -p "$MH_ROOT"/{candidates,proposals,baselines}

  # Record current harness as baseline if none exists
  if [ ! -f "$MH_ROOT/baselines/current.json" ]; then
    mh_snapshot_current_harness "$MH_ROOT/baselines/current.json"
    _mhlog "Recorded initial baseline harness"
  fi
}

# Snapshot the current harness configuration into a JSON file
mh_snapshot_current_harness() {
  local output_file="$1"

  cat > "$output_file" <<EOF
{
  "snapshot_at": "$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")",
  "config": {
    "implementer_model": "$(_json_escape_mh "${IMPLEMENTER_MODEL:-opus-4.5-thinking}")",
    "checker_model": "$(_json_escape_mh "${CHECKER_MODEL:-gemini-3-flash}")",
    "reviewer_model": "$(_json_escape_mh "${REVIEWER_MODEL:-sonnet-4}")",
    "validate_cmd": "$(_json_escape_mh "${VALIDATE_CMD:-}")",
    "enable_checker": "${ENABLE_CHECKER:-1}",
    "checker_conf_threshold": "${CHECKER_CONF_THRESHOLD:-0.70}",
    "enable_reviewer": "${ENABLE_REVIEWER:-1}",
    "review_depth": "$(_json_escape_mh "${REVIEW_DEPTH:-standard}")",
    "reviewer_can_fix": "${REVIEWER_CAN_FIX:-0}",
    "max_repair_attempts": "${MAX_REPAIR_ATTEMPTS:-1}",
    "max_review_fix_attempts": "${MAX_REVIEW_FIX_ATTEMPTS:-2}",
    "max_agent_retries": "${MAX_AGENT_RETRIES:-10}",
    "agent_timeout_secs": "${AGENT_TIMEOUT_SECS:-1800}",
    "validation_stages": "$(_json_escape_mh "${VALIDATION_STAGES:-lint typecheck}")"
  }
}
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# TRACE ANALYSIS
# ──────────────────────────────────────────────────────────────────────────────

# Compute aggregate statistics from recent traces
mh_compute_stats() {
  local limit="${1:-50}"
  local stats_file="$MH_ROOT/latest_stats.json"

  local total=0 successes=0 failures=0 total_duration=0
  local failure_classes=""
  local avg_duration=0 success_rate=0

  while IFS= read -r outcome_file; do
    [ -f "$outcome_file" ] || continue
    total=$((total + 1))

    local outcome duration fails
    outcome="$(jq -r '.outcome // "unknown"' "$outcome_file" 2>/dev/null)"
    duration="$(jq -r '.total_duration_secs // 0' "$outcome_file" 2>/dev/null)"
    fails="$(jq -r '.failures // 0' "$outcome_file" 2>/dev/null)"

    total_duration=$((total_duration + duration))

    if [ "$outcome" = "success" ]; then
      successes=$((successes + 1))
    else
      failures=$((failures + 1))
    fi
  done < <(find "$TRACE_ROOT" -name "outcome.json" 2>/dev/null | sort -r | head -n "$limit")

  if [ "$total" -gt 0 ]; then
    avg_duration=$((total_duration / total))
    success_rate="$(awk -v s="$successes" -v t="$total" 'BEGIN{printf "%.1f", (s/t)*100}')"
  fi

  # Collect failure class distribution from event files
  local class_counts
  class_counts="$(find "$TRACE_ROOT" -name "*-failure-*" -newer "$TRACE_ROOT" 2>/dev/null \
    | head -n 200 \
    | xargs -I{} jq -r '.failure_class // empty' {} 2>/dev/null \
    | sort | uniq -c | sort -rn | head -10 \
    | awk '{printf "    \"%s\": %s,\n", $2, $1}' || true)"
  # Remove trailing comma
  class_counts="$(echo "$class_counts" | sed '$ s/,$//')"

  cat > "$stats_file" <<EOF
{
  "computed_at": "$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")",
  "total_tasks": $total,
  "successes": $successes,
  "failures": $failures,
  "success_rate_pct": $success_rate,
  "avg_duration_secs": $avg_duration,
  "failure_class_distribution": {
$class_counts
  }
}
EOF

  _mhlog "Stats: $total tasks, ${success_rate}% success, avg ${avg_duration}s"
  echo "$stats_file"
}

# ──────────────────────────────────────────────────────────────────────────────
# PROPOSER
# ──────────────────────────────────────────────────────────────────────────────

# Build the proposer prompt that gives full filesystem context
mh_build_proposer_prompt() {
  local stats_file="$1"

  local stats_content
  stats_content="$(cat "$stats_file" 2>/dev/null || echo '{}')"

  local baseline_content
  baseline_content="$(cat "$MH_ROOT/baselines/current.json" 2>/dev/null || echo '{}')"

  # Collect recent failure traces (the most diagnostic signal)
  local failure_traces=""
  local count=0
  while IFS= read -r failure_file; do
    [ -f "$failure_file" ] || continue
    count=$((count + 1))
    [ "$count" -le 10 ] || break
    failure_traces="${failure_traces}
--- Failure $count ---
$(cat "$failure_file" 2>/dev/null)"
  done < <(find "$TRACE_ROOT" -name "*-failure-*" 2>/dev/null | sort -r | head -10)

  # Collect recent validation failures
  local validation_failures=""
  count=0
  while IFS= read -r val_file; do
    [ -f "$val_file" ] || continue
    local result
    result="$(jq -r '.result // ""' "$val_file" 2>/dev/null)"
    if [ "$result" = "fail" ] || [ "$result" = "error" ]; then
      count=$((count + 1))
      [ "$count" -le 10 ] || break
      validation_failures="${validation_failures}
--- Validation Failure $count ---
$(cat "$val_file" 2>/dev/null)"
    fi
  done < <(find "$TRACE_ROOT" -name "*.json" -path "*/validation/*" 2>/dev/null | sort -r | head -30)

  # Collect recent reviewer rejections
  local review_rejections=""
  count=0
  while IFS= read -r review_file; do
    [ -f "$review_file" ] || continue
    local approved
    approved="$(grep -o '"approved":\s*[a-z]*' "$review_file" | head -1 | grep -o 'true\|false' || echo "unknown")"
    if [ "$approved" = "false" ]; then
      count=$((count + 1))
      [ "$count" -le 5 ] || break
      review_rejections="${review_rejections}
--- Review Rejection $count ---
$(cat "$review_file" 2>/dev/null | head -100)"
    fi
  done < <(find "$TRACE_ROOT" -name "review-attempt-*.json" 2>/dev/null | sort -r | head -20)

  # Collect previous candidate proposals and their scores
  local prior_candidates=""
  count=0
  while IFS= read -r candidate_dir; do
    [ -d "$candidate_dir" ] || continue
    count=$((count + 1))
    [ "$count" -le 10 ] || break
    prior_candidates="${prior_candidates}
--- Candidate $count: $(basename "$candidate_dir") ---
Proposal: $(cat "$candidate_dir/proposal.json" 2>/dev/null | head -50)
Score: $(cat "$candidate_dir/score.json" 2>/dev/null || echo 'not evaluated')"
  done < <(ls -1dr "$MH_ROOT"/candidates/*/ 2>/dev/null | head -10)

  cat <<'PROMPT_HEADER'
You are a harness optimization agent. Your job is to analyze execution traces
from an autonomous software development orchestrator and propose specific,
testable improvements to its configuration and behavior.

The orchestrator is a bash-based system that:
1. Picks tasks from a queue
2. Prepares git branches
3. Runs an AI agent (implementer) to write code
4. Validates the code (lint, typecheck, test)
5. Reviews changes with a separate reviewer agent
6. Checks completeness with a checker agent
7. Submits PRs via Graphite

You have access to:
- Current harness configuration (baseline)
- Aggregate statistics from recent runs
- Failure traces with full error context
- Validation failure details
- Reviewer rejection reasons
- Previous optimization candidates and their scores

IMPORTANT CONSTRAINTS:
- Propose ONLY configuration changes (not code changes to the orchestrator itself)
- Each proposal must be a concrete key-value change
- Explain your credit assignment: which trace evidence led to each proposal
- Proposals must be safe and reversible
- Focus on the highest-leverage changes first

Output valid JSON with this schema:
{
  "analysis": "Brief analysis of current harness performance",
  "credit_assignment": [
    {"observation": "what you saw in traces", "root_cause": "why it happened", "proposed_fix": "what to change"}
  ],
  "proposals": [
    {
      "key": "CONFIG_VAR_NAME",
      "current_value": "...",
      "proposed_value": "...",
      "rationale": "why this change should help",
      "expected_impact": "what metric should improve"
    }
  ],
  "confidence": 0.0
}
PROMPT_HEADER

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "CURRENT BASELINE CONFIGURATION"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "$baseline_content"

  echo ""
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "AGGREGATE STATISTICS (recent runs)"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "$stats_content"

  if [ -n "$failure_traces" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "RECENT FAILURE TRACES"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "$failure_traces"
  fi

  if [ -n "$validation_failures" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "RECENT VALIDATION FAILURES"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "$validation_failures"
  fi

  if [ -n "$review_rejections" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "RECENT REVIEWER REJECTIONS"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "$review_rejections"
  fi

  if [ -n "$prior_candidates" ]; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "PREVIOUS OPTIMIZATION CANDIDATES"
    echo "═══════════════════════════════════════════════════════════════════════════════"
    echo "$prior_candidates"
  fi
}

# Run the proposer agent and save the candidate
mh_run_proposer() {
  local stats_file="$1"

  local candidate_ts
  candidate_ts="$(date +%Y%m%d-%H%M%S)"
  local candidate_dir="$MH_ROOT/candidates/$candidate_ts"
  mkdir -p "$candidate_dir"

  _mhlog "Running proposer agent (model=$MH_PROPOSER_MODEL)..."

  local prompt
  prompt="$(mh_build_proposer_prompt "$stats_file")"

  # Save the prompt for reproducibility
  printf '%s' "$prompt" > "$candidate_dir/proposer_prompt.txt"

  # Call the proposer via CLI adapter
  local output=""
  local exit_code=0
  if type run_agent_cli >/dev/null 2>&1; then
    output="$(run_agent_cli "$MH_PROPOSER_MODEL" "$prompt" 2>/dev/null)" || exit_code=$?
  else
    _mhlog "ERROR: run_agent_cli not available. Source cli_adapter.sh first."
    return 1
  fi

  printf '%s' "$output" > "$candidate_dir/proposer_output.txt"

  # Extract JSON from output (may be wrapped in markdown code blocks)
  local json_output
  json_output="$(echo "$output" | sed -n '/^{/,/^}/p' | head -100)"
  if [ -z "$json_output" ]; then
    # Try extracting from code block
    json_output="$(echo "$output" | sed -n '/```json/,/```/p' | sed '1d;$d')"
  fi

  if echo "$json_output" | jq -e . >/dev/null 2>&1; then
    printf '%s' "$json_output" > "$candidate_dir/proposal.json"
    _mhlog "Proposer generated candidate: $candidate_dir"
    echo "$candidate_dir"
  else
    _mhlog "WARNING: Proposer output was not valid JSON"
    echo '{"error": "invalid output", "raw_length": '${#output}'}' > "$candidate_dir/proposal.json"
    echo "$candidate_dir"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# SCORING
# ──────────────────────────────────────────────────────────────────────────────

# Score a candidate by comparing its evaluation results to the baseline
mh_score_candidate() {
  local candidate_dir="$1"

  local proposal_file="$candidate_dir/proposal.json"
  [ -f "$proposal_file" ] || { _mhlog "No proposal.json in $candidate_dir"; return 1; }

  # Read baseline stats
  local baseline_success_rate
  baseline_success_rate="$(jq -r '.success_rate_pct // 0' "$MH_ROOT/latest_stats.json" 2>/dev/null || echo 0)"

  # For now, scoring is based on the proposer's self-assessed confidence
  # and the structural quality of the proposal.
  # Full evaluation requires running tasks with the variant (see mh_evaluate_candidate).
  local confidence num_proposals
  confidence="$(jq -r '.confidence // 0' "$proposal_file" 2>/dev/null || echo 0)"
  num_proposals="$(jq -r '.proposals | length // 0' "$proposal_file" 2>/dev/null || echo 0)"

  cat > "$candidate_dir/score.json" <<EOF
{
  "scored_at": "$(date -Iseconds 2>/dev/null || date +"%Y-%m-%dT%H:%M:%S%z")",
  "baseline_success_rate_pct": $baseline_success_rate,
  "proposer_confidence": $confidence,
  "num_proposals": $num_proposals,
  "status": "pending_evaluation"
}
EOF

  _mhlog "Scored candidate: confidence=$confidence proposals=$num_proposals"
}

# ──────────────────────────────────────────────────────────────────────────────
# ADOPTION
# ──────────────────────────────────────────────────────────────────────────────

# Generate a shell snippet that applies a candidate's proposed config changes
mh_generate_config_patch() {
  local candidate_dir="$1"
  local output_file="${2:-$candidate_dir/apply.sh}"

  local proposal_file="$candidate_dir/proposal.json"
  [ -f "$proposal_file" ] || { _mhlog "No proposal.json"; return 1; }

  # Only allow known safe config keys
  local SAFE_KEYS=(
    "IMPLEMENTER_MODEL" "CHECKER_MODEL" "REVIEWER_MODEL"
    "ENABLE_CHECKER" "CHECKER_CONF_THRESHOLD"
    "ENABLE_REVIEWER" "REVIEW_DEPTH" "REVIEWER_CAN_FIX"
    "MAX_REPAIR_ATTEMPTS" "MAX_REVIEW_FIX_ATTEMPTS"
    "MAX_AGENT_RETRIES" "AGENT_TIMEOUT_SECS"
    "VALIDATION_STAGES" "AUTO_FIX_LINT"
    "RETRY_DELAY_SECS" "BACKOFF_MULTIPLIER" "MAX_DELAY_SECS"
    "MIN_LINES_FOR_REVIEW" "SELF_REVIEW_MODEL"
  )

  {
    echo "#!/usr/bin/env bash"
    echo "# Auto-generated config patch from meta-harness candidate: $(basename "$candidate_dir")"
    echo "# Apply with: source $output_file"
    echo ""

    local proposals
    proposals="$(jq -c '.proposals[]' "$proposal_file" 2>/dev/null || true)"

    while IFS= read -r proposal; do
      [ -n "$proposal" ] || continue
      local key value rationale
      key="$(echo "$proposal" | jq -r '.key // ""')"
      value="$(echo "$proposal" | jq -r '.proposed_value // ""')"
      rationale="$(echo "$proposal" | jq -r '.rationale // ""' | head -1)"

      # Safety: only allow known config keys
      local is_safe="false"
      for safe_key in "${SAFE_KEYS[@]}"; do
        if [ "$key" = "$safe_key" ]; then
          is_safe="true"
          break
        fi
      done

      if [ "$is_safe" = "true" ]; then
        # Sanitize value to prevent shell injection when sourced
        # Only allow alphanumeric, hyphens, underscores, dots, slashes, and spaces
        if printf '%s' "$value" | grep -qE '[`$"\\!;&|(){}<>]'; then
          echo "# SKIPPED (unsafe characters in value): $key"
        else
          echo "# $rationale"
          echo "export ${key}=\"${value}\""
          echo ""
        fi
      else
        echo "# SKIPPED (not in safe keys): $key=$value"
      fi
    done <<< "$proposals"
  } > "$output_file"

  chmod +x "$output_file"
  _mhlog "Generated config patch: $output_file"
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN OPTIMIZATION CYCLE
# ──────────────────────────────────────────────────────────────────────────────

# Run one full optimization cycle: analyze → propose → score → generate patch
mh_run_optimization_cycle() {
  _mhlog "Starting meta-harness optimization cycle"

  # 1. Initialize filesystem
  mh_init

  # 2. Check if we have enough traces
  local trace_count
  trace_count="$(find "$TRACE_ROOT" -name "outcome.json" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$trace_count" -lt "$MH_MIN_TRACES" ]; then
    _mhlog "Not enough traces ($trace_count < $MH_MIN_TRACES). Skipping optimization."
    return 0
  fi

  # 3. Compute aggregate statistics
  local stats_file
  stats_file="$(mh_compute_stats)"

  # 4. Run proposer
  local candidate_dir
  candidate_dir="$(mh_run_proposer "$stats_file")"

  # 5. Score candidate
  mh_score_candidate "$candidate_dir"

  # 6. Generate config patch
  mh_generate_config_patch "$candidate_dir"

  # 7. Prune old candidates if over limit
  local candidate_count
  candidate_count="$(find "$MH_ROOT/candidates" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$candidate_count" -gt "$MH_MAX_HISTORY" ]; then
    local to_remove=$((candidate_count - MH_MAX_HISTORY))
    find "$MH_ROOT/candidates" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
      | sort | head -n "$to_remove" \
      | xargs rm -rf
    _mhlog "Pruned $to_remove old candidates"
  fi

  _mhlog "Optimization cycle complete. Candidate: $candidate_dir"
  _mhlog "To apply: source $candidate_dir/apply.sh"
  echo "$candidate_dir"
}

# Print a human-readable report of the latest optimization analysis
mh_report() {
  local latest_candidate
  latest_candidate="$(ls -1dr "$MH_ROOT"/candidates/*/ 2>/dev/null | head -1)"

  if [ -z "$latest_candidate" ]; then
    echo "No optimization candidates found. Run mh_run_optimization_cycle first."
    return 0
  fi

  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "META-HARNESS OPTIMIZATION REPORT"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""

  if [ -f "$MH_ROOT/latest_stats.json" ]; then
    echo "--- Current Performance ---"
    jq '.' "$MH_ROOT/latest_stats.json" 2>/dev/null
    echo ""
  fi

  echo "--- Latest Candidate: $(basename "$latest_candidate") ---"
  if [ -f "$latest_candidate/proposal.json" ]; then
    jq '.' "$latest_candidate/proposal.json" 2>/dev/null
  fi
  echo ""

  if [ -f "$latest_candidate/score.json" ]; then
    echo "--- Score ---"
    jq '.' "$latest_candidate/score.json" 2>/dev/null
  fi

  echo ""
  echo "To apply: source ${latest_candidate}apply.sh"
}
