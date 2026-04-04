#!/usr/bin/env bash
# meta-harness.sh - Entry point for meta-harness optimization
#
# Analyzes execution traces from past orchestrator runs and proposes
# configuration improvements using an agentic proposer (inspired by
# "Meta-Harness: End-to-End Optimization of Model Harnesses", Lee et al. 2026).
#
# Usage:
#   # Run one optimization cycle (analyze traces, propose improvements)
#   ./meta-harness.sh optimize
#
#   # View current performance stats from traces
#   ./meta-harness.sh stats
#
#   # View the latest optimization proposal
#   ./meta-harness.sh report
#
#   # Apply a proposal (sources the generated config patch)
#   ./meta-harness.sh apply [candidate-id]
#
#   # List all optimization candidates
#   ./meta-harness.sh list

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="${LIB_DIR:-$SCRIPT_DIR/../lib/orchestrator}"

# Source required modules
source "$LIB_DIR/cli_adapter.sh"
source "$LIB_DIR/trace_collector.sh"
source "$LIB_DIR/meta_harness.sh"

MH_ROOT="${MH_ROOT:-${HOME}/.local/share/orchestrator/meta-harness}"
TRACE_ROOT="${TRACE_ROOT:-${HOME}/.local/share/orchestrator/traces}"

_log() { echo "$(date): [meta-harness-cli] $*"; }

usage() {
  cat <<EOF
meta-harness.sh - Optimize orchestrator configuration from execution traces

Commands:
  optimize    Run one optimization cycle (analyze → propose → score)
  stats       Show aggregate performance statistics from traces
  report      Show the latest optimization proposal
  apply [id]  Apply a candidate's config patch (prints the env vars to source)
  list        List all optimization candidates
  traces      Show recent task trace summaries
  help        Show this message

Environment:
  TRACE_ROOT          Trace storage (default: ~/.local/share/orchestrator/traces)
  MH_ROOT             Meta-harness data (default: ~/.local/share/orchestrator/meta-harness)
  MH_PROPOSER_MODEL   Model for proposer agent (default: opus-4.5-thinking)
  MH_MIN_TRACES       Min traces before proposing (default: 10)
EOF
}

cmd_optimize() {
  _log "Starting optimization cycle..."
  mh_run_optimization_cycle
}

cmd_stats() {
  # Check if traces exist
  local count
  count="$(find "$TRACE_ROOT" -name "outcome.json" 2>/dev/null | wc -l | tr -d ' ')"
  if [ "$count" -eq 0 ]; then
    echo "No traces found in $TRACE_ROOT"
    echo "Run the orchestrator with trace collection enabled (TRACE_ENABLED=1) to collect traces."
    return 0
  fi

  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "ORCHESTRATOR PERFORMANCE STATISTICS ($count traces)"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""

  mh_init >/dev/null 2>&1
  local stats_file
  stats_file="$(mh_compute_stats)"
  jq '.' "$stats_file" 2>/dev/null

  echo ""
  echo "--- Recent Task Outcomes ---"
  trace_summary 20

  echo ""
  echo "--- Failure Distribution ---"
  find "$TRACE_ROOT" -name "*-failure-*" 2>/dev/null \
    | head -100 \
    | xargs -I{} jq -r '.failure_class // empty' {} 2>/dev/null \
    | sort | uniq -c | sort -rn
}

cmd_report() {
  mh_init >/dev/null 2>&1
  mh_report
}

cmd_apply() {
  local candidate_id="${1:-}"
  local candidate_dir

  if [ -n "$candidate_id" ]; then
    candidate_dir="$MH_ROOT/candidates/$candidate_id"
  else
    candidate_dir="$(ls -1dr "$MH_ROOT"/candidates/*/ 2>/dev/null | head -1)"
  fi

  if [ -z "$candidate_dir" ] || [ ! -d "$candidate_dir" ]; then
    echo "No candidate found. Run 'meta-harness.sh optimize' first."
    return 1
  fi

  local apply_file="$candidate_dir/apply.sh"
  if [ ! -f "$apply_file" ]; then
    echo "No apply.sh in $candidate_dir"
    return 1
  fi

  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "APPLYING CANDIDATE: $(basename "$candidate_dir")"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  echo "The following environment variables will be set:"
  echo ""
  grep "^export " "$apply_file"
  echo ""
  echo "To apply, source this in your orchestrator environment:"
  echo "  source $apply_file"
}

cmd_list() {
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "OPTIMIZATION CANDIDATES"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""

  local count=0
  while IFS= read -r candidate_dir; do
    [ -d "$candidate_dir" ] || continue
    count=$((count + 1))
    local name
    name="$(basename "$candidate_dir")"
    local confidence proposals status
    confidence="$(jq -r '.confidence // "?"' "$candidate_dir/proposal.json" 2>/dev/null || echo "?")"
    proposals="$(jq -r '.proposals | length // 0' "$candidate_dir/proposal.json" 2>/dev/null || echo "?")"
    status="$(jq -r '.status // "unknown"' "$candidate_dir/score.json" 2>/dev/null || echo "unknown")"
    echo "  $name  confidence=$confidence  proposals=$proposals  status=$status"
  done < <(ls -1dr "$MH_ROOT"/candidates/*/ 2>/dev/null)

  if [ "$count" -eq 0 ]; then
    echo "  No candidates yet. Run 'meta-harness.sh optimize' to generate one."
  fi
}

cmd_traces() {
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo "RECENT TASK TRACES"
  echo "═══════════════════════════════════════════════════════════════════════════════"
  echo ""
  trace_summary "${1:-20}"
}

# ──────────────────────────────────────────────────────────────────────────────
# MAIN
# ──────────────────────────────────────────────────────────────────────────────

case "${1:-help}" in
  optimize)  cmd_optimize ;;
  stats)     cmd_stats ;;
  report)    cmd_report ;;
  apply)     cmd_apply "${2:-}" ;;
  list)      cmd_list ;;
  traces)    cmd_traces "${2:-20}" ;;
  help|*)    usage ;;
esac
