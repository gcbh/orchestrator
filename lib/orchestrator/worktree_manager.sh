#!/usr/bin/env bash
# worktree_manager.sh - Manage git worktrees for agent tasks
#
# Supports per-epic worktrees with shared node_modules
#

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Where worktrees live
WORKTREE_BASE="${WORKTREE_BASE:-$HOME/.local/worktrees}"

# Main repository (source for worktrees)
MAIN_REPO="${MAIN_REPO:-}"

# Project name (derived from MAIN_REPO if not set)
PROJECT_NAME="${PROJECT_NAME:-}"

# Whether to share node_modules
SHARE_NODE_MODULES="${SHARE_NODE_MODULES:-1}"

# ──────────────────────────────────────────────────────────────────────────────
# HELPERS
# ──────────────────────────────────────────────────────────────────────────────

_wt_log() { echo "$(date): [worktree] $*" >&2; }

_get_project_name() {
  if [ -n "$PROJECT_NAME" ]; then
    echo "$PROJECT_NAME"
    return
  fi
  
  if [ -n "$MAIN_REPO" ]; then
    basename "$MAIN_REPO"
  else
    echo "unknown"
  fi
}

_get_worktree_dir() {
  local project
  project="$(_get_project_name)"
  echo "$WORKTREE_BASE/$project"
}

_sanitize_name() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]/-/g' | sed 's/--*/-/g' | sed 's/^-//;s/-$//'
}

# ──────────────────────────────────────────────────────────────────────────────
# WORKTREE OPERATIONS
# ──────────────────────────────────────────────────────────────────────────────

# Initialize worktree directory structure
# Usage: wt_init
wt_init() {
  if [ -z "$MAIN_REPO" ]; then
    _wt_log "ERROR: MAIN_REPO not set"
    return 1
  fi
  
  local wt_dir
  wt_dir="$(_get_worktree_dir)"
  
  mkdir -p "$wt_dir/.shared"
  
  # Create shared node_modules if using FE
  if [ "$SHARE_NODE_MODULES" = "1" ] && [ ! -d "$wt_dir/.shared/node_modules" ]; then
    if [ -d "$MAIN_REPO/node_modules" ]; then
      _wt_log "Copying node_modules to shared location (one-time)..."
      cp -R "$MAIN_REPO/node_modules" "$wt_dir/.shared/"
      _wt_log "Shared node_modules ready"
    fi
  fi
  
  _wt_log "Worktree base initialized at $wt_dir"
  echo "$wt_dir"
}

# Get or create worktree for an epic
# Usage: wt_get_epic_worktree <epic_id>
# Returns: Path to worktree
wt_get_epic_worktree() {
  local epic_id="$1"
  
  if [ -z "$MAIN_REPO" ]; then
    _wt_log "ERROR: MAIN_REPO not set"
    return 1
  fi
  
  local wt_dir epic_name wt_path
  wt_dir="$(_get_worktree_dir)"
  epic_name="$(_sanitize_name "$epic_id")"
  wt_path="$wt_dir/$epic_name"
  
  # If worktree exists, return it
  if [ -d "$wt_path" ]; then
    echo "$wt_path"
    return 0
  fi
  
  # Create new worktree
  _wt_log "Creating worktree for epic $epic_id at $wt_path"
  
  cd "$MAIN_REPO" || return 1
  
  # Fetch latest
  git fetch origin --quiet 2>/dev/null || true
  
  # Create worktree from origin/master (or main)
  local base_ref="origin/master"
  git rev-parse "$base_ref" >/dev/null 2>&1 || base_ref="origin/main"
  
  if ! git worktree add "$wt_path" "$base_ref" --detach 2>/dev/null; then
    _wt_log "ERROR: Failed to create worktree"
    return 1
  fi
  
  # Setup shared node_modules if enabled
  if [ "$SHARE_NODE_MODULES" = "1" ] && [ -d "$wt_dir/.shared/node_modules" ]; then
    _wt_log "Linking shared node_modules"
    rm -rf "$wt_path/node_modules" 2>/dev/null || true
    ln -s "$wt_dir/.shared/node_modules" "$wt_path/node_modules"
  fi
  
  # Disable husky in worktree
  cd "$wt_path" || return 1
  export HUSKY=0
  
  # Run any setup (pnpm install for new packages, etc.)
  if [ -f "$wt_path/pnpm-lock.yaml" ] && [ "$SHARE_NODE_MODULES" != "1" ]; then
    _wt_log "Installing dependencies..."
    pnpm install --frozen-lockfile >/dev/null 2>&1 || pnpm install >/dev/null 2>&1 || true
  fi
  
  _wt_log "Worktree ready: $wt_path"
  echo "$wt_path"
}

# Get base worktree (for non-epic tasks)
# Usage: wt_get_base_worktree
wt_get_base_worktree() {
  local wt_dir wt_path
  wt_dir="$(_get_worktree_dir)"
  wt_path="$wt_dir/base"
  
  # Treat "base" as a special epic
  EPIC_ID="base" wt_get_epic_worktree "base"
}

# Cleanup worktree for an epic
# Usage: wt_remove_epic_worktree <epic_id>
wt_remove_epic_worktree() {
  local epic_id="$1"
  local wt_dir epic_name wt_path
  wt_dir="$(_get_worktree_dir)"
  epic_name="$(_sanitize_name "$epic_id")"
  wt_path="$wt_dir/$epic_name"
  
  if [ ! -d "$wt_path" ]; then
    _wt_log "Worktree $wt_path doesn't exist"
    return 0
  fi
  
  _wt_log "Removing worktree for epic $epic_id"
  
  cd "$MAIN_REPO" || return 1
  
  # Remove symlinked node_modules first (don't delete shared!)
  if [ -L "$wt_path/node_modules" ]; then
    rm "$wt_path/node_modules"
  fi
  
  # Remove worktree
  git worktree remove "$wt_path" --force 2>/dev/null || {
    # Force cleanup if git worktree remove fails
    rm -rf "$wt_path"
    git worktree prune
  }
  
  _wt_log "Worktree removed"
}

# List all worktrees
# Usage: wt_list
wt_list() {
  if [ -z "$MAIN_REPO" ]; then
    _wt_log "ERROR: MAIN_REPO not set"
    return 1
  fi
  
  cd "$MAIN_REPO" && git worktree list
}

# Sync shared node_modules with main repo
# Usage: wt_sync_modules
wt_sync_modules() {
  local wt_dir
  wt_dir="$(_get_worktree_dir)"
  
  if [ ! -d "$MAIN_REPO/node_modules" ]; then
    _wt_log "No node_modules in main repo to sync"
    return 1
  fi
  
  _wt_log "Syncing shared node_modules from main repo..."
  rsync -a --delete "$MAIN_REPO/node_modules/" "$wt_dir/.shared/node_modules/"
  _wt_log "Sync complete"
}

# Get worktree for a task (determines epic, gets appropriate worktree)
# Usage: wt_get_task_worktree <task_id> [epic_id]
wt_get_task_worktree() {
  local task_id="$1"
  local epic_id="${2:-}"
  
  if [ -n "$epic_id" ] && [ "$epic_id" != "null" ]; then
    wt_get_epic_worktree "$epic_id"
  else
    wt_get_base_worktree
  fi
}

# Prune stale worktrees
# Usage: wt_prune
wt_prune() {
  if [ -z "$MAIN_REPO" ]; then
    _wt_log "ERROR: MAIN_REPO not set"
    return 1
  fi
  
  cd "$MAIN_REPO" && git worktree prune
  _wt_log "Pruned stale worktrees"
}

# ──────────────────────────────────────────────────────────────────────────────
# STATUS
# ──────────────────────────────────────────────────────────────────────────────

# Show worktree status
wt_status() {
  local wt_dir
  wt_dir="$(_get_worktree_dir)"
  
  echo "=== Worktree Status ==="
  echo "Base: $wt_dir"
  echo ""
  
  if [ -d "$wt_dir" ]; then
    echo "Epic worktrees:"
    for d in "$wt_dir"/*/; do
      [ -d "$d" ] || continue
      local name branch
      name="$(basename "$d")"
      [ "$name" = ".shared" ] && continue
      branch="$(cd "$d" && git branch --show-current 2>/dev/null || echo "detached")"
      echo "  $name -> $branch"
    done
    echo ""
    
    if [ -d "$wt_dir/.shared/node_modules" ]; then
      local size
      size="$(du -sh "$wt_dir/.shared/node_modules" 2>/dev/null | cut -f1)"
      echo "Shared node_modules: $size"
    fi
  else
    echo "Not initialized. Run: wt_init"
  fi
}
