#!/usr/bin/env bash
# failure_classifier.sh - LLM-based failure classification
#
# The LLM is only called when a failure occurs. It classifies the failure
# into a bounded taxonomy and recommends remediation from an allowlist.
#
# Key principle: LLMs are excellent at diagnosis, but poor sources of truth.
# The classifier diagnoses; code executes.
#
# Usage:
#   source failure_classifier.sh
#   CLASSIFICATION=$(classify_failure "SUBMIT_PR" "1" "$CONTEXT_JSON" "$ERROR_OUTPUT")

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────
CLASSIFIER_MODEL="${CLASSIFIER_MODEL:-gemini-3-flash}"
AGENT_BIN="${AGENT_BIN:-$HOME/.local/bin/cursor-agent}"
CLASSIFIER_TIMEOUT="${CLASSIFIER_TIMEOUT:-90}"

# ──────────────────────────────────────────────────────────────────────────────
# FAILURE TAXONOMY (bounded, exhaustive)
# ──────────────────────────────────────────────────────────────────────────────
# Every failure maps to exactly one of these classes.
# This ensures bounded remediation strategies.
#
# RATE_LIMIT         - Provider rate limiting, temporary
# GRAPHITE_DRIFT     - gt tracking/stack out of sync
# PR_EXISTS          - PR already exists for this work
# BRANCH_EXISTS      - Branch already exists
# MERGE_CONFLICT     - Git merge/rebase conflict
# AUTH_FAILURE       - Authentication/permission issue
# VALIDATION_FAILURE - Code doesn't pass validation
# IMPLEMENTATION_GAP - Implementer didn't make required changes
# NETWORK_ERROR      - Transient network issue
# UNKNOWN            - Unclassified (requires human)

VALID_FAILURE_CLASSES=(
  "RATE_LIMIT"
  "GRAPHITE_DRIFT"
  "PR_EXISTS"
  "BRANCH_EXISTS"
  "MERGE_CONFLICT"
  "AUTH_FAILURE"
  "VALIDATION_FAILURE"
  "IMPLEMENTATION_GAP"
  "NETWORK_ERROR"
  "UNKNOWN"
)

# ──────────────────────────────────────────────────────────────────────────────
# CLASSIFICATION PROMPT
# ──────────────────────────────────────────────────────────────────────────────

build_classifier_prompt() {
  local failed_step="$1" exit_code="$2" context_json="$3" error_output="$4"
  
  cat <<EOF
You are a failure classifier for a software orchestration system.

A step in the orchestration pipeline has failed. Your job is to:
1. Classify the failure into exactly ONE category
2. Determine if it's retryable
3. Recommend remediation actions from the allowed list

═══════════════════════════════════════════════════════════════════════════════
FAILED STEP: $failed_step
EXIT CODE: $exit_code
═══════════════════════════════════════════════════════════════════════════════

ERROR OUTPUT (last 100 lines):
$error_output

CONTEXT:
$context_json

═══════════════════════════════════════════════════════════════════════════════
FAILURE CLASSES (pick exactly one)
═══════════════════════════════════════════════════════════════════════════════
- RATE_LIMIT: Provider rate limiting (503, 429, "overloaded", "capacity")
- GRAPHITE_DRIFT: Graphite tracking out of sync ("diverged", "needs restack", "not tracked")
- PR_EXISTS: PR already exists for this branch/task
- BRANCH_EXISTS: Branch already exists when trying to create
- MERGE_CONFLICT: Git merge/rebase conflict markers
- AUTH_FAILURE: Authentication or permission denied
- VALIDATION_FAILURE: Code doesn't pass linting/typecheck/tests
- IMPLEMENTATION_GAP: Agent produced no changes or incomplete work
- NETWORK_ERROR: Transient network issue (timeout, connection reset)
- UNKNOWN: None of the above (requires human intervention)

═══════════════════════════════════════════════════════════════════════════════
ALLOWED REMEDIATION ACTIONS (pick 0-3, in order)
═══════════════════════════════════════════════════════════════════════════════
- GT_SYNC: Run gt sync to sync with remote
- GT_RESTACK: Run gt restack --no-interactive
- GT_TRACK_FORCE: Run gt track <branch> --force
- GIT_FETCH: Run git fetch origin
- GIT_PULL_REBASE: Run git pull --rebase
- GIT_STASH_PUSH: Stash uncommitted changes
- GIT_REBASE_ABORT: Abort in-progress rebase
- RETRY_STEP: Retry the failed step
- RETRY_WITH_DELAY: Wait 60s then retry
- SKIP_TO_CLOSE: Skip to closing the bead (PR exists)
- BLOCK_TASK: Block the task with reason
- NOTIFY_HUMAN: Requires human intervention

═══════════════════════════════════════════════════════════════════════════════
OUTPUT FORMAT (valid JSON only, no markdown)
═══════════════════════════════════════════════════════════════════════════════
{
  "failure_class": "ONE_OF_THE_CLASSES_ABOVE",
  "retryable": true|false,
  "recommended_actions": ["ACTION1", "ACTION2"],
  "needs_human": true|false,
  "human_message": "Message for human if needs_human=true",
  "diagnosis": "Brief explanation of what went wrong"
}
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# HEURISTIC CLASSIFIER (fast, no LLM)
# ──────────────────────────────────────────────────────────────────────────────

# Attempt to classify using simple pattern matching before calling LLM
# Returns empty string if can't classify, otherwise returns JSON
heuristic_classify() {
  local error_output="$1"
  
  # Rate limiting patterns
  if echo "$error_output" | grep -qiE "rate limit|429|503|502|overloaded|capacity|too many requests"; then
    echo '{"failure_class":"RATE_LIMIT","retryable":true,"recommended_actions":["RETRY_WITH_DELAY"],"needs_human":false,"human_message":"","diagnosis":"Provider rate limiting detected"}'
    return 0
  fi
  
  # Graphite drift patterns
  if echo "$error_output" | grep -qiE "diverged|needs restack|not tracked|Cannot submit"; then
    echo '{"failure_class":"GRAPHITE_DRIFT","retryable":true,"recommended_actions":["GT_TRACK_FORCE","GT_RESTACK","RETRY_STEP"],"needs_human":false,"human_message":"","diagnosis":"Graphite tracking out of sync"}'
    return 0
  fi
  
  # PR exists patterns
  if echo "$error_output" | grep -qiE "pull request already exists|PR already|already has a pull request"; then
    echo '{"failure_class":"PR_EXISTS","retryable":false,"recommended_actions":["SKIP_TO_CLOSE"],"needs_human":false,"human_message":"","diagnosis":"PR already exists for this work"}'
    return 0
  fi
  
  # Branch exists patterns
  if echo "$error_output" | grep -qiE "branch.*already exists|fatal: A branch named"; then
    echo '{"failure_class":"BRANCH_EXISTS","retryable":true,"recommended_actions":["GIT_FETCH","RETRY_STEP"],"needs_human":false,"human_message":"","diagnosis":"Branch already exists"}'
    return 0
  fi
  
  # Merge conflict patterns
  if echo "$error_output" | grep -qiE "CONFLICT|merge conflict|Automatic merge failed|needs merge"; then
    echo '{"failure_class":"MERGE_CONFLICT","retryable":false,"recommended_actions":["GIT_REBASE_ABORT","BLOCK_TASK"],"needs_human":true,"human_message":"Merge conflict requires manual resolution","diagnosis":"Git merge/rebase conflict"}'
    return 0
  fi
  
  # Auth patterns
  if echo "$error_output" | grep -qiE "permission denied|401|403|authentication|not authorized"; then
    echo '{"failure_class":"AUTH_FAILURE","retryable":false,"recommended_actions":["BLOCK_TASK","NOTIFY_HUMAN"],"needs_human":true,"human_message":"Authentication or permission issue","diagnosis":"Auth/permission failure"}'
    return 0
  fi
  
  # Network patterns
  if echo "$error_output" | grep -qiE "connection reset|ETIMEDOUT|ECONNREFUSED|network|timeout"; then
    echo '{"failure_class":"NETWORK_ERROR","retryable":true,"recommended_actions":["RETRY_WITH_DELAY"],"needs_human":false,"human_message":"","diagnosis":"Transient network error"}'
    return 0
  fi
  
  # No match - need LLM
  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# LLM CLASSIFIER
# ──────────────────────────────────────────────────────────────────────────────

normalize_classifier_json() {
  local raw="$1"
  
  # Strip markdown fences
  local s
  s="$(echo "$raw" | sed -e 's/^```json[[:space:]]*$//g' -e 's/^```[[:space:]]*$//g' -e 's/```$//g')"
  
  # Extract JSON object
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

# Validate classification output
validate_classification() {
  local json="$1"
  
  # Check it's valid JSON
  if ! echo "$json" | jq -e . >/dev/null 2>&1; then
    return 1
  fi
  
  # Check required fields
  local failure_class
  failure_class="$(echo "$json" | jq -r '.failure_class // ""')"
  if [ -z "$failure_class" ]; then
    return 1
  fi
  
  # Validate failure_class is in allowed list
  local valid=false
  for fc in "${VALID_FAILURE_CLASSES[@]}"; do
    if [ "$fc" = "$failure_class" ]; then
      valid=true
      break
    fi
  done
  
  if [ "$valid" != "true" ]; then
    return 1
  fi
  
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN CLASSIFIER FUNCTION
# ──────────────────────────────────────────────────────────────────────────────

# Classify a failure
# Usage: classify_failure <step> <exit_code> <context_json> <error_output>
# Returns: JSON classification
classify_failure() {
  local failed_step="$1"
  local exit_code="$2"
  local context_json="$3"
  local error_output="$4"
  
  # Try heuristic first (fast, no LLM cost)
  local heuristic_result
  heuristic_result="$(heuristic_classify "$error_output")"
  if [ -n "$heuristic_result" ]; then
    echo "$heuristic_result"
    return 0
  fi
  
  # Fall back to LLM classifier
  local prompt
  prompt="$(build_classifier_prompt "$failed_step" "$exit_code" "$context_json" "$error_output")"
  
  local raw_output
  set +e
  # Note: timeout removed for macOS compatibility
  raw_output="$("$AGENT_BIN" --model "$CLASSIFIER_MODEL" -p --force "$prompt" 2>&1)"
  local agent_exit=$?
  set -e
  
  if [ "$agent_exit" -ne 0 ]; then
    # LLM failed - return UNKNOWN
    echo '{"failure_class":"UNKNOWN","retryable":false,"recommended_actions":["BLOCK_TASK","NOTIFY_HUMAN"],"needs_human":true,"human_message":"Classifier failed to run","diagnosis":"LLM classifier unavailable"}'
    return 0
  fi
  
  local classification
  classification="$(normalize_classifier_json "$raw_output")"
  
  # Validate the classification
  if validate_classification "$classification"; then
    echo "$classification"
  else
    # Invalid output - return UNKNOWN
    echo '{"failure_class":"UNKNOWN","retryable":false,"recommended_actions":["BLOCK_TASK","NOTIFY_HUMAN"],"needs_human":true,"human_message":"Classifier returned invalid output","diagnosis":"LLM classifier returned unparseable response"}'
  fi
}



