#!/usr/bin/env bash
# cross_repo_messaging.sh - File-based messaging between orchestrators
#
# Enables async communication between repo-specific orchestrators.
# Messages are markdown files in a shared .comms/ directory.
#
# Usage:
#   source cross_repo_messaging.sh
#   msg_init "ios"                           # Set this orchestrator's identity
#   msg_send "backend" "question" "What is the login response schema?" "ios-3gu"
#   msg_check_inbox                          # Check for replies, unblock tasks
#   msg_list_pending                         # List messages awaiting reply

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Root of the shared comms directory (override with COMMS_ROOT)
COMMS_ROOT="${COMMS_ROOT:-}"

# This orchestrator's identity (set via msg_init)
MSG_SELF=""

# Message log
MSG_LOG="${MSG_LOG:-/tmp/orchestrator-messages.log}"

# ──────────────────────────────────────────────────────────────────────────────
# INITIALIZATION
# ──────────────────────────────────────────────────────────────────────────────

# Initialize messaging for this orchestrator
# Usage: msg_init <identity> [comms_root]
msg_init() {
  local identity="$1"
  local comms_root="${2:-}"

  MSG_SELF="$identity"

  # Auto-detect comms root if not provided
  if [ -n "$comms_root" ]; then
    COMMS_ROOT="$comms_root"
  elif [ -z "$COMMS_ROOT" ]; then
    # Try to find .comms in parent directories
    local dir="$PWD"
    while [ "$dir" != "/" ]; do
      if [ -d "$dir/.comms" ]; then
        COMMS_ROOT="$dir/.comms"
        break
      fi
      dir="$(dirname "$dir")"
    done
  fi

  if [ -z "$COMMS_ROOT" ] || [ ! -d "$COMMS_ROOT" ]; then
    _msg_log "ERROR: Could not find .comms directory"
    return 1
  fi

  # Ensure our inbox exists
  mkdir -p "$COMMS_ROOT/$MSG_SELF"

  _msg_log "Initialized messaging: identity=$MSG_SELF, comms=$COMMS_ROOT"
}

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────────────────────────────────────

_msg_log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): [msg:$MSG_SELF] $*" | tee -a "$MSG_LOG" >&2
}

# ──────────────────────────────────────────────────────────────────────────────
# MESSAGE SENDING
# ──────────────────────────────────────────────────────────────────────────────

# Generate a unique message ID
_msg_generate_id() {
  echo "msg-$(date +%s)-$(head -c 4 /dev/urandom | xxd -p)"
}

# Send a message to another orchestrator
# Usage: msg_send <to> <type> <body> [blocks_task]
# Types: question, answer, notification
# Returns: message ID
msg_send() {
  local to="$1"
  local msg_type="$2"
  local body="$3"
  local blocks_task="${4:-}"

  local msg_id
  msg_id=$(_msg_generate_id)
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local filename="$COMMS_ROOT/$to/${msg_id}.md"

  cat > "$filename" << EOF
---
from: ${MSG_SELF}-orchestrator
to: ${to}-orchestrator
message-id: $msg_id
type: $msg_type
timestamp: $timestamp
blocks-task: $blocks_task
---

$body
EOF

  _msg_log "Sent $msg_type to $to: $msg_id"

  # If this blocks a task, mark it as blocked
  if [ -n "$blocks_task" ] && command -v bd >/dev/null 2>&1; then
    bd update "$blocks_task" --status blocked --notes "Waiting for reply: $msg_id from $to" 2>/dev/null || true
    _msg_log "Blocked task $blocks_task waiting for $msg_id"
  fi

  echo "$msg_id"
}

# Send a reply to a message
# Usage: msg_reply <original_msg_id> <body>
msg_reply() {
  local original_id="$1"
  local body="$2"

  # Find the original message to get the sender
  local original_file
  original_file=$(find "$COMMS_ROOT" -name "${original_id}.md" 2>/dev/null | head -1)

  if [ -z "$original_file" ]; then
    _msg_log "ERROR: Cannot find original message $original_id"
    return 1
  fi

  # Extract sender from original
  local original_from
  original_from=$(grep "^from:" "$original_file" | sed 's/from: //' | sed 's/-orchestrator//')

  local msg_id
  msg_id=$(_msg_generate_id)
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local filename="$COMMS_ROOT/$original_from/${msg_id}.md"

  cat > "$filename" << EOF
---
from: ${MSG_SELF}-orchestrator
to: ${original_from}-orchestrator
message-id: $msg_id
in-reply-to: $original_id
type: answer
timestamp: $timestamp
---

$body
EOF

  _msg_log "Replied to $original_id with $msg_id"
  echo "$msg_id"
}

# ──────────────────────────────────────────────────────────────────────────────
# MESSAGE RECEIVING
# ──────────────────────────────────────────────────────────────────────────────

# Check inbox and process messages
# - Unblocks tasks that have received replies
# - Returns list of unread messages
msg_check_inbox() {
  local inbox="$COMMS_ROOT/$MSG_SELF"
  local processed_dir="$inbox/.processed"
  mkdir -p "$processed_dir"

  local unread=()
  local unblocked=()

  for msg_file in "$inbox"/*.md; do
    [ -f "$msg_file" ] || continue

    local msg_id
    msg_id=$(basename "$msg_file" .md)
    local in_reply_to
    in_reply_to=$(grep "^in-reply-to:" "$msg_file" 2>/dev/null | sed 's/in-reply-to: //' || echo "")

    # If this is a reply, unblock the waiting task
    if [ -n "$in_reply_to" ]; then
      _msg_unblock_task "$in_reply_to" "$msg_file"
      unblocked+=("$in_reply_to")
    else
      unread+=("$msg_id")
    fi

    # Move to processed
    mv "$msg_file" "$processed_dir/"
    _msg_log "Processed message: $msg_id"
  done

  if [ ${#unblocked[@]} -gt 0 ]; then
    echo "Unblocked tasks from replies: ${unblocked[*]}"
  fi

  if [ ${#unread[@]} -gt 0 ]; then
    echo "New messages: ${unread[*]}"
  fi
}

# Unblock a task that was waiting for a message
_msg_unblock_task() {
  local waiting_for="$1"
  local reply_file="$2"

  if ! command -v bd >/dev/null 2>&1; then
    return 0
  fi

  # Find blocked tasks waiting for this message
  local blocked_tasks
  blocked_tasks=$(bd list --status blocked 2>/dev/null | awk '{print $1}' || true)

  for task in $blocked_tasks; do
    local notes
    notes=$(bd show "$task" --json 2>/dev/null | jq -r '.notes // ""' || true)

    if echo "$notes" | grep -q "Waiting for reply: $waiting_for"; then
      # Extract reply content for the notes
      local reply_body
      reply_body=$(sed -n '/^---$/,/^---$/d; p' "$reply_file" | head -20)

      bd update "$task" --status open --notes "Reply received: $reply_body" 2>/dev/null || true
      _msg_log "Unblocked task $task (received reply to $waiting_for)"
    fi
  done
}

# List pending outgoing messages (questions awaiting replies)
msg_list_pending() {
  if ! command -v bd >/dev/null 2>&1; then
    echo "bd not available"
    return 0
  fi

  bd list --status blocked 2>/dev/null | while read -r line; do
    local task
    task=$(echo "$line" | awk '{print $1}')
    local notes
    notes=$(bd show "$task" --json 2>/dev/null | jq -r '.notes // ""' || true)

    if echo "$notes" | grep -q "Waiting for reply:"; then
      echo "$line"
    fi
  done
}

# Read a specific message
# Usage: msg_read <message_id>
msg_read() {
  local msg_id="$1"

  local msg_file
  msg_file=$(find "$COMMS_ROOT" -name "${msg_id}.md" 2>/dev/null | head -1)

  if [ -z "$msg_file" ]; then
    # Check processed folders
    msg_file=$(find "$COMMS_ROOT" -path "*/.processed/${msg_id}.md" 2>/dev/null | head -1)
  fi

  if [ -n "$msg_file" ]; then
    cat "$msg_file"
  else
    echo "Message not found: $msg_id"
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# BROADCAST MESSAGES
# ──────────────────────────────────────────────────────────────────────────────

# Send a broadcast message (all orchestrators see it)
# Usage: msg_broadcast <subject> <body>
msg_broadcast() {
  local subject="$1"
  local body="$2"

  local msg_id
  msg_id=$(_msg_generate_id)
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local safe_subject
  safe_subject=$(echo "$subject" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
  local filename="$COMMS_ROOT/broadcast/${timestamp%T*}-${safe_subject}.md"

  cat > "$filename" << EOF
---
from: ${MSG_SELF}-orchestrator
message-id: $msg_id
type: broadcast
subject: $subject
timestamp: $timestamp
---

$body
EOF

  _msg_log "Broadcast: $subject ($msg_id)"
  echo "$msg_id"
}

# Check for new broadcasts
msg_check_broadcasts() {
  local broadcast_dir="$COMMS_ROOT/broadcast"
  local seen_file="$COMMS_ROOT/$MSG_SELF/.seen_broadcasts"

  touch "$seen_file"

  for msg_file in "$broadcast_dir"/*.md; do
    [ -f "$msg_file" ] || continue

    local msg_id
    msg_id=$(grep "^message-id:" "$msg_file" | sed 's/message-id: //')

    if ! grep -q "$msg_id" "$seen_file" 2>/dev/null; then
      echo "=== New Broadcast ==="
      cat "$msg_file"
      echo "===================="
      echo "$msg_id" >> "$seen_file"
    fi
  done
}

# ──────────────────────────────────────────────────────────────────────────────
# API CONTRACT (Special broadcast for API definitions)
# ──────────────────────────────────────────────────────────────────────────────

# Update the shared API contract
# Usage: msg_update_contract <content>
msg_update_contract() {
  local content="$1"
  local contract_file="$COMMS_ROOT/broadcast/api-contract.md"
  local timestamp
  timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  cat > "$contract_file" << EOF
---
last-updated: $timestamp
updated-by: ${MSG_SELF}-orchestrator
---

# API Contract

$content
EOF

  _msg_log "Updated API contract"
}

# Read the current API contract
msg_read_contract() {
  local contract_file="$COMMS_ROOT/broadcast/api-contract.md"

  if [ -f "$contract_file" ]; then
    cat "$contract_file"
  else
    echo "No API contract found"
    return 1
  fi
}
