#!/usr/bin/env bash
# reviewer_agent.sh - Clean agent review step for quality assurance
#
# A separate agent with NO prior context reviews the changes.
# This catches issues the implementer might have blind spots to.
#

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Reviewer model (can be different from implementer)
REVIEWER_MODEL="${REVIEWER_MODEL:-sonnet-4}"

# Review depth: minimal | standard | thorough
REVIEW_DEPTH="${REVIEW_DEPTH:-standard}"

# Whether reviewer can make fixes directly
REVIEWER_CAN_FIX="${REVIEWER_CAN_FIX:-0}"

# Max lines of surrounding context to include
CONTEXT_LINES="${CONTEXT_LINES:-50}"

# Timeout for reviewer
REVIEWER_TIMEOUT_SECS="${REVIEWER_TIMEOUT_SECS:-600}"

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────

_rlog() { echo "$(date): [reviewer] $*" >&2; }

# Get the diff with surrounding context
_get_diff_with_context() {
  local base_ref="${1:-HEAD~1}"
  
  # Get changed files
  local changed_files
  changed_files="$(git diff --name-only "$base_ref" HEAD 2>/dev/null)"
  
  if [ -z "$changed_files" ]; then
    echo "No changes detected"
    return
  fi
  
  echo "=== CHANGED FILES ==="
  echo "$changed_files"
  echo ""
  
  echo "=== DIFF ==="
  git diff "$base_ref" HEAD 2>/dev/null
  echo ""
  
  # For each changed file, show surrounding context
  echo "=== FILE CONTEXT ==="
  while IFS= read -r file; do
    [ -f "$file" ] || continue
    echo "--- $file (full file for context) ---"
    head -200 "$file" 2>/dev/null
    echo ""
  done <<< "$changed_files"
}

# Get acceptance criteria from beads task
_get_acceptance_criteria() {
  local task="$1"
  local main_repo="${MAIN_REPO:-$(pwd)}"
  
  (cd "$main_repo" && bd show "$task" 2>/dev/null) | \
    sed -n '/^Acceptance Criteria:/,/^[A-Z]/p' | \
    head -20
}

# ──────────────────────────────────────────────────────────────────────────────
# REVIEW PROMPTS
# ──────────────────────────────────────────────────────────────────────────────

_build_minimal_review_prompt() {
  local task="$1"
  local title="$2"
  local diff="$3"
  
  cat <<EOF
You are a code reviewer. Review this change for obvious issues.

TASK: $task - $title

CHANGES:
$diff

Quick check for:
1. Obvious bugs or typos
2. Missing null checks
3. Broken imports

OUTPUT (JSON only):
{
  "approved": boolean,
  "blocking_issues": ["issue1", "issue2"],
  "suggestions": ["optional improvement"]
}
EOF
}

_build_standard_review_prompt() {
  local task="$1"
  local title="$2"
  local diff="$3"
  local acceptance="$4"
  
  cat <<EOF
You are a senior code reviewer examining changes made by another developer.
You have NOT seen the implementation process - review with fresh eyes.

═══════════════════════════════════════════════════════════════════════════════
TASK CONTEXT
═══════════════════════════════════════════════════════════════════════════════

Task: $task
Title: $title

$acceptance

═══════════════════════════════════════════════════════════════════════════════
CODE CHANGES
═══════════════════════════════════════════════════════════════════════════════

$diff

═══════════════════════════════════════════════════════════════════════════════
REVIEW CHECKLIST
═══════════════════════════════════════════════════════════════════════════════

1. CORRECTNESS
   - Does the code do what the task asks?
   - Are there logic errors or off-by-one bugs?
   - Are edge cases handled? (null, undefined, empty arrays, etc.)

2. INTEGRATION
   - Will this break existing functionality?
   - Are imports correct?
   - Does it follow existing patterns in the codebase?

3. ERROR HANDLING
   - Are errors caught and handled appropriately?
   - Are there potential runtime exceptions?

4. SECURITY (if applicable)
   - Any injection vulnerabilities?
   - Sensitive data exposure?

5. PERFORMANCE
   - Any obvious N+1 queries or infinite loops?
   - Memory leaks (event listeners, subscriptions)?

═══════════════════════════════════════════════════════════════════════════════
OUTPUT FORMAT
═══════════════════════════════════════════════════════════════════════════════

Return ONLY valid JSON:
{
  "approved": boolean,
  "confidence": 0.0-1.0,
  "blocking_issues": [
    {
      "severity": "high|medium",
      "file": "path/to/file.ts",
      "line": 42,
      "issue": "Description of the problem",
      "suggestion": "How to fix it"
    }
  ],
  "suggestions": [
    {
      "severity": "low",
      "file": "path/to/file.ts",
      "issue": "Optional improvement",
      "suggestion": "Consider doing X instead"
    }
  ],
  "missing_from_acceptance": ["AC item not addressed"],
  "summary": "One sentence summary of review"
}

Rules:
- approved=false if ANY blocking_issues exist
- blocking_issues = bugs, security issues, broken functionality
- suggestions = style, minor improvements, nice-to-haves
- Be specific: include file names and line numbers
- Don't nitpick style if it follows existing patterns
EOF
}

_build_thorough_review_prompt() {
  local task="$1"
  local title="$2"
  local diff="$3"
  local acceptance="$4"
  local context="$5"
  
  cat <<EOF
You are a thorough code reviewer performing a comprehensive review.
Take your time to understand the full context before reviewing.

═══════════════════════════════════════════════════════════════════════════════
TASK
═══════════════════════════════════════════════════════════════════════════════

Task: $task
Title: $title

$acceptance

═══════════════════════════════════════════════════════════════════════════════
FULL FILE CONTEXT (surrounding code)
═══════════════════════════════════════════════════════════════════════════════

$context

═══════════════════════════════════════════════════════════════════════════════
CHANGES MADE
═══════════════════════════════════════════════════════════════════════════════

$diff

═══════════════════════════════════════════════════════════════════════════════
THOROUGH REVIEW
═══════════════════════════════════════════════════════════════════════════════

Perform a comprehensive review covering:

1. FUNCTIONAL CORRECTNESS
   - Does it fully implement the acceptance criteria?
   - Are all code paths correct?
   - Edge cases: null, undefined, empty, boundary values?

2. INTEGRATION IMPACT
   - How does this interact with surrounding code?
   - Could it break callers of modified functions?
   - Are type contracts maintained?

3. ERROR HANDLING & RESILIENCE
   - What happens when things go wrong?
   - Are errors propagated correctly?
   - Any unhandled promise rejections?

4. STATE MANAGEMENT
   - Are state updates correct?
   - Race conditions possible?
   - Memory leaks (subscriptions, listeners)?

5. SECURITY
   - Input validation?
   - XSS/injection risks?
   - Sensitive data handling?

6. TESTABILITY
   - Is this code testable?
   - Should there be tests?
   - What test cases would you write?

7. MAINTAINABILITY
   - Is the code readable?
   - Will future developers understand it?
   - Any magic numbers or unclear logic?

═══════════════════════════════════════════════════════════════════════════════
OUTPUT
═══════════════════════════════════════════════════════════════════════════════

Return ONLY valid JSON:
{
  "approved": boolean,
  "confidence": 0.0-1.0,
  "blocking_issues": [...],
  "suggestions": [...],
  "missing_from_acceptance": [...],
  "test_recommendations": [
    {
      "description": "Test case description",
      "type": "unit|integration",
      "priority": "high|medium|low"
    }
  ],
  "summary": "Comprehensive summary"
}
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# FIX PROMPT
# ──────────────────────────────────────────────────────────────────────────────

_build_fix_prompt() {
  local review_json="$1"
  
  cat <<EOF
A code review found issues that need to be fixed.

REVIEW FINDINGS:
$review_json

INSTRUCTIONS:
1. Fix ALL blocking_issues listed above
2. Consider implementing suggestions if they're easy wins
3. Do NOT change anything else
4. After fixing, the code will be reviewed again

Fix the issues now.
EOF
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN REVIEW FUNCTION
# ──────────────────────────────────────────────────────────────────────────────

# Run a clean agent review
# Usage: run_reviewer_agent <task_id> <title> [base_ref]
# Returns: JSON review result
run_reviewer_agent() {
  local task="$1"
  local title="$2"
  local base_ref="${3:-HEAD~1}"
  
  _rlog "Starting clean agent review for $task"
  _rlog "Reviewer model: $REVIEWER_MODEL"
  _rlog "Review depth: $REVIEW_DEPTH"
  
  # Gather information
  local diff acceptance context prompt
  diff="$(git diff "$base_ref" HEAD 2>/dev/null | head -1000)"
  acceptance="$(_get_acceptance_criteria "$task")"
  
  if [ -z "$diff" ]; then
    _rlog "No changes to review"
    echo '{"approved":true,"summary":"No changes to review"}'
    return 0
  fi
  
  # Build prompt based on depth
  case "$REVIEW_DEPTH" in
    minimal)
      prompt="$(_build_minimal_review_prompt "$task" "$title" "$diff")"
      ;;
    standard)
      prompt="$(_build_standard_review_prompt "$task" "$title" "$diff" "$acceptance")"
      ;;
    thorough)
      context="$(_get_diff_with_context "$base_ref")"
      prompt="$(_build_thorough_review_prompt "$task" "$title" "$diff" "$acceptance" "$context")"
      ;;
    *)
      _rlog "Unknown review depth: $REVIEW_DEPTH, using standard"
      prompt="$(_build_standard_review_prompt "$task" "$title" "$diff" "$acceptance")"
      ;;
  esac
  
  # Call reviewer agent
  local review_output
  if type run_agent_cli >/dev/null 2>&1; then
    _rlog "Invoking reviewer agent..."
    # Note: timeout removed for macOS compatibility
    review_output="$(run_agent_cli "$REVIEWER_MODEL" "$prompt" 2>/dev/null)"
  else
    _rlog "ERROR: CLI adapter not available"
    echo '{"approved":false,"error":"CLI adapter not available"}'
    return 1
  fi
  
  # Extract JSON from response
  local json_result
  json_result="$(echo "$review_output" | grep -o '{.*}' | tail -1)"
  
  if [ -z "$json_result" ]; then
    _rlog "Failed to parse reviewer response"
    echo '{"approved":false,"error":"Failed to parse response","raw":"'"$(echo "$review_output" | head -5 | tr '\n' ' ')"'"}'
    return 1
  fi
  
  # Check if approved
  if echo "$json_result" | grep -q '"approved":\s*true'; then
    _rlog "Review PASSED ✓"
  else
    _rlog "Review found issues"
  fi
  
  echo "$json_result"
}

# Run review with fix loop
# Usage: run_reviewer_with_fixes <task_id> <title> <max_attempts>
run_reviewer_with_fixes() {
  local task="$1"
  local title="$2"
  local max_attempts="${3:-2}"
  local attempt=0
  
  while [ "$attempt" -lt "$max_attempts" ]; do
    attempt=$((attempt + 1))
    _rlog "Review attempt $attempt/$max_attempts"
    
    local review_result
    review_result="$(run_reviewer_agent "$task" "$title")"
    
    if echo "$review_result" | grep -q '"approved":\s*true'; then
      _rlog "Review passed on attempt $attempt"
      echo "$review_result"
      return 0
    fi
    
    # Check if we should try to fix
    if [ "$REVIEWER_CAN_FIX" != "1" ]; then
      _rlog "Reviewer cannot fix, returning issues"
      echo "$review_result"
      return 1
    fi
    
    if [ "$attempt" -ge "$max_attempts" ]; then
      _rlog "Max review attempts reached"
      echo "$review_result"
      return 1
    fi
    
    # Ask implementer model to fix
    _rlog "Asking implementer to fix review issues..."
    local fix_prompt
    fix_prompt="$(_build_fix_prompt "$review_result")"
    
    if type run_agent_cli >/dev/null 2>&1; then
      run_agent_cli "${IMPLEMENTER_MODEL:-opus-4.5-thinking}" "$fix_prompt" >/dev/null 2>&1 || true
      
      # Commit fixes
      git add -A 2>/dev/null || true
      git commit --amend --no-edit 2>/dev/null || true
    fi
  done
  
  return 1
}

# ──────────────────────────────────────────────────────────────────────────────
# INTEGRATION HELPERS
# ──────────────────────────────────────────────────────────────────────────────

# Check if review is required for this change
should_run_review() {
  local min_lines="${1:-10}"
  
  local changed_lines
  changed_lines="$(git diff HEAD~1 --stat 2>/dev/null | tail -1 | grep -oE '[0-9]+ insertion' | grep -oE '[0-9]+' || echo 0)"
  
  if [ "$changed_lines" -ge "$min_lines" ]; then
    return 0
  else
    _rlog "Skipping review: only $changed_lines lines changed (min: $min_lines)"
    return 1
  fi
}

# Parse review result for blocking issues
has_blocking_issues() {
  local review_json="$1"
  
  # Check if blocking_issues array is non-empty
  if echo "$review_json" | grep -q '"blocking_issues":\s*\[\]'; then
    return 1  # No blocking issues
  fi
  
  if echo "$review_json" | grep -q '"blocking_issues":\s*\['; then
    return 0  # Has blocking issues
  fi
  
  return 1  # Default: no issues
}

# Get blocking issues as text for task notes
get_blocking_issues_text() {
  local review_json="$1"
  
  echo "$review_json" | \
    grep -o '"blocking_issues":\s*\[[^]]*\]' | \
    sed 's/"blocking_issues":/Issues:/' | \
    tr '{}' '\n' | \
    grep -E '"issue"|"suggestion"' | \
    sed 's/"issue":/- /g; s/"suggestion":/ → /g; s/"//g'
}
