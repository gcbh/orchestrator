#!/usr/bin/env bash
# cli_adapter.sh - Abstraction layer for different AI CLI tools
#
# Supports: cursor, claude-code
# Usage: source this file, then call run_agent_cli "$model" "$prompt"
#

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Which CLI to use: cursor | claude-code
AGENT_CLI="${AGENT_CLI:-cursor}"

# Binary paths (auto-detected if not set)
CURSOR_BIN="${CURSOR_BIN:-}"
CLAUDE_CODE_BIN="${CLAUDE_CODE_BIN:-}"

# Timeouts
AGENT_TIMEOUT_SECS="${AGENT_TIMEOUT_SECS:-1800}"

# Retry settings
MAX_AGENT_RETRIES="${MAX_AGENT_RETRIES:-10}"
RETRY_DELAY_SECS="${RETRY_DELAY_SECS:-60}"
BACKOFF_MULTIPLIER="${BACKOFF_MULTIPLIER:-2}"
MAX_DELAY_SECS="${MAX_DELAY_SECS:-600}"

# ──────────────────────────────────────────────────────────────────────────────
# CLI DETECTION
# ──────────────────────────────────────────────────────────────────────────────

_detect_cursor_bin() {
  if [ -n "$CURSOR_BIN" ]; then
    echo "$CURSOR_BIN"
    return
  fi
  
  # Try common locations
  for bin in \
    "$HOME/.local/bin/cursor-agent" \
    "$HOME/.cursor/bin/cursor" \
    "/Applications/Cursor.app/Contents/MacOS/Cursor" \
    "$(command -v cursor 2>/dev/null)" \
    "$(command -v cursor-agent 2>/dev/null)"; do
    if [ -x "$bin" ]; then
      echo "$bin"
      return
    fi
  done
  
  echo ""
}

_detect_claude_code_bin() {
  if [ -n "$CLAUDE_CODE_BIN" ]; then
    echo "$CLAUDE_CODE_BIN"
    return
  fi
  
  # Try common locations
  for bin in \
    "$HOME/.local/bin/claude" \
    "$HOME/.claude/bin/claude" \
    "$(command -v claude 2>/dev/null)"; do
    if [ -x "$bin" ]; then
      echo "$bin"
      return
    fi
  done
  
  echo ""
}

# ──────────────────────────────────────────────────────────────────────────────
# CLI-SPECIFIC INVOCATION
# ──────────────────────────────────────────────────────────────────────────────

# Cursor CLI invocation
# Usage: _run_cursor "$model" "$prompt"
_run_cursor() {
  local model="$1"
  local prompt="$2"
  local bin
  bin="$(_detect_cursor_bin)"
  
  if [ -z "$bin" ]; then
    echo "ERROR: Cursor CLI not found" >&2
    return 1
  fi
  
  # Cursor agent format: cursor-agent --model MODEL -p --force "PROMPT"
  timeout "$AGENT_TIMEOUT_SECS" "$bin" --model "$model" -p --force "$prompt" 2>&1
}

# Claude Code CLI invocation
# Usage: _run_claude_code "$model" "$prompt"
_run_claude_code() {
  local model="$1"
  local prompt="$2"
  local bin
  bin="$(_detect_claude_code_bin)"
  
  if [ -z "$bin" ]; then
    echo "ERROR: Claude Code CLI not found" >&2
    return 1
  fi
  
  # Claude Code CLI flags (adjust based on your version)
  # Common flags:
  #   -p, --print         Print response without interactive mode
  #   --dangerously-skip-permissions  Skip permission prompts (for automation)
  #   --model MODEL       Specify model
  #   --allowedTools      Specify allowed tools
  #
  # Override with CLAUDE_CODE_ARGS if needed
  local args="${CLAUDE_CODE_ARGS:--p --dangerously-skip-permissions}"
  
  # shellcheck disable=SC2086
  timeout "$AGENT_TIMEOUT_SECS" "$bin" \
    $args \
    --model "$model" \
    "$prompt" 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# MODEL MAPPING
# ──────────────────────────────────────────────────────────────────────────────

# Map generic model names to CLI-specific model identifiers
_map_model() {
  local cli="$1"
  local model="$2"
  
  case "$cli" in
    cursor)
      # Cursor uses its own model names
      case "$model" in
        opus|claude-opus|opus-4.5)
          echo "opus-4.5"
          ;;
        opus-thinking|claude-opus-thinking|opus-4.5-thinking)
          echo "opus-4.5-thinking"
          ;;
        sonnet|claude-sonnet|sonnet-4)
          echo "sonnet-4"
          ;;
        gemini|gemini-flash|gemini-3-flash)
          echo "gemini-3-flash"
          ;;
        *)
          echo "$model"
          ;;
      esac
      ;;
    claude-code)
      # Claude Code uses Anthropic model names
      # See: https://docs.anthropic.com/en/docs/about-claude/models
      case "$model" in
        opus|opus-4|opus-4.5)
          echo "claude-opus-4-20250514"
          ;;
        opus-thinking|opus-4.5-thinking)
          # Claude Code may not support thinking mode the same way
          echo "claude-opus-4-20250514"
          ;;
        sonnet|sonnet-4)
          echo "claude-sonnet-4-20250514"
          ;;
        haiku|haiku-3.5)
          echo "claude-3-5-haiku-20241022"
          ;;
        *)
          # Pass through as-is (user may specify full model name)
          echo "$model"
          ;;
      esac
      ;;
    *)
      echo "$model"
      ;;
  esac
}

# ──────────────────────────────────────────────────────────────────────────────
# UNIFIED INTERFACE
# ──────────────────────────────────────────────────────────────────────────────

# Run the configured agent CLI
# Usage: run_agent_cli "$model" "$prompt"
# Returns: Agent output on stdout, exit code indicates success/failure
run_agent_cli() {
  local model="$1"
  local prompt="$2"
  local mapped_model
  
  mapped_model="$(_map_model "$AGENT_CLI" "$model")"
  
  case "$AGENT_CLI" in
    cursor)
      _run_cursor "$mapped_model" "$prompt"
      ;;
    claude-code|claude)
      _run_claude_code "$mapped_model" "$prompt"
      ;;
    *)
      echo "ERROR: Unknown AGENT_CLI: $AGENT_CLI" >&2
      return 1
      ;;
  esac
}

# Note: run_agent_with_retries is defined in the main orchestrator script
# to support legacy fallback. The orchestrator will call run_agent_cli
# from this adapter when available.

# ──────────────────────────────────────────────────────────────────────────────
# VALIDATION
# ──────────────────────────────────────────────────────────────────────────────

# Check if the configured CLI is available
validate_agent_cli() {
  local bin=""
  
  case "$AGENT_CLI" in
    cursor)
      bin="$(_detect_cursor_bin)"
      ;;
    claude-code|claude)
      bin="$(_detect_claude_code_bin)"
      ;;
  esac
  
  if [ -z "$bin" ]; then
    # Use tr for bash 3.2 compatibility (no ${var^^} support)
    local cli_upper
    cli_upper="$(echo "$AGENT_CLI" | tr '[:lower:]' '[:upper:]')"
    echo "ERROR: $AGENT_CLI CLI not found. Set ${cli_upper}_BIN or install the CLI." >&2
    return 1
  fi
  
  echo "Using $AGENT_CLI CLI: $bin" >&2
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# CAPABILITY DETECTION
# ──────────────────────────────────────────────────────────────────────────────

# Check if CLI supports a specific feature
cli_supports() {
  local feature="$1"
  
  case "$AGENT_CLI" in
    cursor)
      case "$feature" in
        thinking-models) echo "true" ;;
        mcp) echo "true" ;;
        file-edit) echo "true" ;;
        *) echo "false" ;;
      esac
      ;;
    claude-code|claude)
      case "$feature" in
        thinking-models) echo "true" ;;
        mcp) echo "true" ;;
        file-edit) echo "true" ;;
        *) echo "false" ;;
      esac
      ;;
  esac
}

# Get CLI-specific prompt adjustments
get_cli_prompt_prefix() {
  case "$AGENT_CLI" in
    cursor)
      # Cursor-specific instructions
      echo ""
      ;;
    claude-code|claude)
      # Claude Code specific instructions
      cat <<'EOF'
You are running in Claude Code CLI mode. Use the available tools to complete the task.
When editing files, use the appropriate file editing tools.

EOF
      ;;
  esac
}
