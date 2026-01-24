#!/usr/bin/env bash
# ios_simulator_mcp.sh - iOS Simulator MCP integration for agent-based UI testing
#
# Provides functions to interact with iOS simulators via the ios-simulator-mcp server.
# Requires: idb_companion (brew install facebook/fb/idb-companion), fb-idb (pipx install fb-idb)
#
# Usage: source this file, then call functions like:
#   ios_sim_boot
#   ios_sim_install_app "/path/to/App.app"
#   ios_sim_launch_app "com.example.app"
#   ios_sim_screenshot "/tmp/screen.png"
#   ios_sim_tap 200 400
#   ios_sim_describe_ui

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

# Default simulator device (can be overridden)
IOS_SIMULATOR_UDID="${IOS_SIMULATOR_UDID:-}"
IOS_SIMULATOR_DEVICE="${IOS_SIMULATOR_DEVICE:-iPhone 16 Pro}"
IOS_SIMULATOR_OS="${IOS_SIMULATOR_OS:-18.1}"

# Screenshot settings
IOS_SCREENSHOT_DIR="${IOS_SCREENSHOT_DIR:-/tmp/ios-screenshots}"

# MCP server settings (if using MCP directly)
IOS_SIMULATOR_MCP_PORT="${IOS_SIMULATOR_MCP_PORT:-}"

# Timeouts
IOS_SIM_BOOT_TIMEOUT="${IOS_SIM_BOOT_TIMEOUT:-60}"
IOS_SIM_INSTALL_TIMEOUT="${IOS_SIM_INSTALL_TIMEOUT:-120}"

# Logging
IOS_SIM_LOG="${IOS_SIM_LOG:-/tmp/ios-simulator.log}"

# ──────────────────────────────────────────────────────────────────────────────
# LOGGING
# ──────────────────────────────────────────────────────────────────────────────

_ios_log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S'): [ios-sim] $*" | tee -a "$IOS_SIM_LOG" >&2
}

# ──────────────────────────────────────────────────────────────────────────────
# DEPENDENCY CHECKS
# ──────────────────────────────────────────────────────────────────────────────

# Check if required tools are installed
ios_sim_check_deps() {
  local missing=()

  # Check for idb_companion
  if ! command -v idb_companion >/dev/null 2>&1; then
    if [ ! -x "/usr/local/bin/idb_companion" ] && [ ! -x "/opt/homebrew/bin/idb_companion" ]; then
      missing+=("idb_companion (brew install facebook/fb/idb-companion)")
    fi
  fi

  # Check for idb
  if ! command -v idb >/dev/null 2>&1; then
    missing+=("idb (pipx install fb-idb)")
  fi

  # Check for simctl
  if ! command -v xcrun >/dev/null 2>&1; then
    missing+=("Xcode Command Line Tools")
  fi

  if [ ${#missing[@]} -gt 0 ]; then
    _ios_log "Missing dependencies:"
    for dep in "${missing[@]}"; do
      _ios_log "  - $dep"
    done
    return 1
  fi

  _ios_log "All iOS simulator dependencies satisfied"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# SIMULATOR DISCOVERY
# ──────────────────────────────────────────────────────────────────────────────

# Get UDID of a booted simulator (or first available if none booted)
ios_sim_get_udid() {
  # Return cached UDID if set
  if [ -n "$IOS_SIMULATOR_UDID" ]; then
    echo "$IOS_SIMULATOR_UDID"
    return 0
  fi

  # Try to find a booted simulator
  local booted_udid
  booted_udid=$(xcrun simctl list devices -j 2>/dev/null | \
    python3 -c "
import json, sys
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for device in devices:
        if device.get('state') == 'Booted':
            print(device['udid'])
            sys.exit(0)
" 2>/dev/null)

  if [ -n "$booted_udid" ]; then
    echo "$booted_udid"
    return 0
  fi

  # Find a simulator matching our device/OS preference
  local found_udid
  found_udid=$(xcrun simctl list devices -j 2>/dev/null | \
    python3 -c "
import json, sys
device_name = '$IOS_SIMULATOR_DEVICE'
os_version = '$IOS_SIMULATOR_OS'
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    if os_version in runtime:
        for device in devices:
            if device.get('name') == device_name and device.get('isAvailable', False):
                print(device['udid'])
                sys.exit(0)
# Fallback: any available iPhone
for runtime, devices in data.get('devices', {}).items():
    for device in devices:
        if 'iPhone' in device.get('name', '') and device.get('isAvailable', False):
            print(device['udid'])
            sys.exit(0)
" 2>/dev/null)

  if [ -n "$found_udid" ]; then
    echo "$found_udid"
    return 0
  fi

  _ios_log "ERROR: No suitable iOS simulator found"
  return 1
}

# List available simulators
ios_sim_list() {
  xcrun simctl list devices available 2>/dev/null | grep -E "iPhone|iPad"
}

# ──────────────────────────────────────────────────────────────────────────────
# SIMULATOR LIFECYCLE
# ──────────────────────────────────────────────────────────────────────────────

# Boot a simulator
ios_sim_boot() {
  local udid="${1:-$(ios_sim_get_udid)}"

  if [ -z "$udid" ]; then
    _ios_log "ERROR: No simulator UDID provided or found"
    return 1
  fi

  # Check if already booted
  local state
  state=$(xcrun simctl list devices -j 2>/dev/null | \
    python3 -c "
import json, sys
udid = '$udid'
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for device in devices:
        if device.get('udid') == udid:
            print(device.get('state', 'Unknown'))
            sys.exit(0)
" 2>/dev/null)

  if [ "$state" = "Booted" ]; then
    _ios_log "Simulator $udid already booted"
    IOS_SIMULATOR_UDID="$udid"
    return 0
  fi

  _ios_log "Booting simulator $udid..."
  xcrun simctl boot "$udid" 2>/dev/null || true

  # Wait for boot
  local attempts=0
  while [ "$attempts" -lt "$IOS_SIM_BOOT_TIMEOUT" ]; do
    state=$(xcrun simctl list devices -j 2>/dev/null | \
      python3 -c "
import json, sys
udid = '$udid'
data = json.load(sys.stdin)
for runtime, devices in data.get('devices', {}).items():
    for device in devices:
        if device.get('udid') == udid:
            print(device.get('state', 'Unknown'))
            sys.exit(0)
" 2>/dev/null)

    if [ "$state" = "Booted" ]; then
      _ios_log "Simulator $udid booted successfully"
      IOS_SIMULATOR_UDID="$udid"
      return 0
    fi

    sleep 1
    attempts=$((attempts + 1))
  done

  _ios_log "ERROR: Timeout waiting for simulator to boot"
  return 1
}

# Shutdown a simulator
ios_sim_shutdown() {
  local udid="${1:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    _ios_log "No simulator to shutdown"
    return 0
  fi

  _ios_log "Shutting down simulator $udid..."
  xcrun simctl shutdown "$udid" 2>/dev/null || true
}

# Open Simulator.app
ios_sim_open_app() {
  open -a Simulator 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# APP MANAGEMENT
# ──────────────────────────────────────────────────────────────────────────────

# Install an app on the simulator
ios_sim_install_app() {
  local app_path="$1"
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  if [ -z "$app_path" ]; then
    _ios_log "ERROR: No app path provided"
    return 1
  fi

  if [ ! -e "$app_path" ]; then
    _ios_log "ERROR: App not found at $app_path"
    return 1
  fi

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  _ios_log "Installing $app_path on simulator $udid..."

  if xcrun simctl install "$udid" "$app_path" 2>&1; then
    _ios_log "App installed successfully"
    return 0
  else
    _ios_log "ERROR: Failed to install app"
    return 1
  fi
}

# Launch an app by bundle ID
ios_sim_launch_app() {
  local bundle_id="$1"
  local udid="${2:-$IOS_SIMULATOR_UDID}"
  local terminate_first="${3:-false}"

  if [ -z "$bundle_id" ]; then
    _ios_log "ERROR: No bundle ID provided"
    return 1
  fi

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  # Terminate if requested
  if [ "$terminate_first" = "true" ]; then
    xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
    sleep 1
  fi

  _ios_log "Launching $bundle_id on simulator $udid..."

  if xcrun simctl launch "$udid" "$bundle_id" 2>&1; then
    _ios_log "App launched successfully"
    sleep 2  # Give app time to render
    return 0
  else
    _ios_log "ERROR: Failed to launch app"
    return 1
  fi
}

# Terminate an app
ios_sim_terminate_app() {
  local bundle_id="$1"
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  xcrun simctl terminate "$udid" "$bundle_id" 2>/dev/null || true
}

# Uninstall an app
ios_sim_uninstall_app() {
  local bundle_id="$1"
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  xcrun simctl uninstall "$udid" "$bundle_id" 2>/dev/null || true
}

# ──────────────────────────────────────────────────────────────────────────────
# SCREENSHOTS & VISUAL VERIFICATION
# ──────────────────────────────────────────────────────────────────────────────

# Take a screenshot
ios_sim_screenshot() {
  local output_path="${1:-}"
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  # Generate output path if not provided
  if [ -z "$output_path" ]; then
    mkdir -p "$IOS_SCREENSHOT_DIR"
    output_path="$IOS_SCREENSHOT_DIR/screenshot-$(date +%Y%m%d-%H%M%S).png"
  fi

  _ios_log "Taking screenshot to $output_path..."

  if xcrun simctl io "$udid" screenshot "$output_path" 2>&1; then
    _ios_log "Screenshot saved: $output_path"
    echo "$output_path"
    return 0
  else
    _ios_log "ERROR: Failed to take screenshot"
    return 1
  fi
}

# Record a video
ios_sim_start_recording() {
  local output_path="${1:-}"
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  if [ -z "$output_path" ]; then
    mkdir -p "$IOS_SCREENSHOT_DIR"
    output_path="$IOS_SCREENSHOT_DIR/recording-$(date +%Y%m%d-%H%M%S).mov"
  fi

  _ios_log "Starting video recording to $output_path..."

  # Start recording in background
  xcrun simctl io "$udid" recordVideo "$output_path" &
  echo $! > /tmp/ios-sim-recording.pid
  echo "$output_path"
}

ios_sim_stop_recording() {
  if [ -f /tmp/ios-sim-recording.pid ]; then
    local pid
    pid=$(cat /tmp/ios-sim-recording.pid)
    kill -INT "$pid" 2>/dev/null || true
    rm -f /tmp/ios-sim-recording.pid
    _ios_log "Recording stopped"
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# UI INTERACTION (via idb)
# ──────────────────────────────────────────────────────────────────────────────

# Tap at coordinates
ios_sim_tap() {
  local x="$1"
  local y="$2"
  local udid="${3:-$IOS_SIMULATOR_UDID}"

  if [ -z "$x" ] || [ -z "$y" ]; then
    _ios_log "ERROR: Coordinates required for tap"
    return 1
  fi

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  _ios_log "Tapping at ($x, $y)..."

  if idb ui tap --udid "$udid" "$x" "$y" 2>&1; then
    return 0
  else
    _ios_log "ERROR: Tap failed"
    return 1
  fi
}

# Long press at coordinates
ios_sim_long_press() {
  local x="$1"
  local y="$2"
  local duration="${3:-1.0}"
  local udid="${4:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  _ios_log "Long pressing at ($x, $y) for ${duration}s..."

  idb ui tap --udid "$udid" --duration "$duration" "$x" "$y" 2>&1
}

# Swipe gesture
ios_sim_swipe() {
  local x_start="$1"
  local y_start="$2"
  local x_end="$3"
  local y_end="$4"
  local udid="${5:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  _ios_log "Swiping from ($x_start, $y_start) to ($x_end, $y_end)..."

  idb ui swipe --udid "$udid" "$x_start" "$y_start" "$x_end" "$y_end" 2>&1
}

# Type text
ios_sim_type() {
  local text="$1"
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  if [ -z "$text" ]; then
    _ios_log "ERROR: No text provided"
    return 1
  fi

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  _ios_log "Typing text..."

  if idb ui text --udid "$udid" "$text" 2>&1; then
    return 0
  else
    _ios_log "ERROR: Text input failed"
    return 1
  fi
}

# Press a button (home, siri, etc.)
ios_sim_button() {
  local button="$1"  # HOME, LOCK, SIDEBUTTON, SIRI
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  _ios_log "Pressing $button button..."

  idb ui button --udid "$udid" "$button" 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# UI DESCRIPTION (Accessibility)
# ──────────────────────────────────────────────────────────────────────────────

# Describe all UI elements
ios_sim_describe_ui() {
  local udid="${1:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  _ios_log "Describing UI elements..."

  idb ui describe-all --udid "$udid" --json --nested 2>/dev/null
}

# Describe UI element at point
ios_sim_describe_point() {
  local x="$1"
  local y="$2"
  local udid="${3:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  idb ui describe-point --udid "$udid" "$x" "$y" --json 2>/dev/null
}

# ──────────────────────────────────────────────────────────────────────────────
# BUILD & TEST HELPERS
# ──────────────────────────────────────────────────────────────────────────────

# Build iOS app for simulator
ios_sim_build_app() {
  local project_dir="$1"
  local scheme="${2:-}"
  local configuration="${3:-Debug}"
  local udid="${4:-$IOS_SIMULATOR_UDID}"

  if [ -z "$project_dir" ]; then
    _ios_log "ERROR: Project directory required"
    return 1
  fi

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  # Find xcodeproj or xcworkspace
  local project_file=""
  if [ -d "$project_dir"/*.xcworkspace ]; then
    project_file="-workspace $(ls -d "$project_dir"/*.xcworkspace | head -1)"
  elif [ -d "$project_dir"/*.xcodeproj ]; then
    project_file="-project $(ls -d "$project_dir"/*.xcodeproj | head -1)"
  else
    _ios_log "ERROR: No Xcode project found in $project_dir"
    return 1
  fi

  # Auto-detect scheme if not provided
  if [ -z "$scheme" ]; then
    scheme=$(xcodebuild -list $project_file 2>/dev/null | grep -A 100 "Schemes:" | grep -v "Schemes:" | head -1 | tr -d ' ')
  fi

  local derived_data="$project_dir/build"

  _ios_log "Building $scheme for simulator $udid..."

  # shellcheck disable=SC2086
  xcodebuild build \
    $project_file \
    -scheme "$scheme" \
    -configuration "$configuration" \
    -destination "platform=iOS Simulator,id=$udid" \
    -derivedDataPath "$derived_data" \
    2>&1
}

# Run tests on simulator
ios_sim_run_tests() {
  local project_dir="$1"
  local scheme="${2:-}"
  local test_target="${3:-}"
  local udid="${4:-$IOS_SIMULATOR_UDID}"

  if [ -z "$project_dir" ]; then
    _ios_log "ERROR: Project directory required"
    return 1
  fi

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  local project_file=""
  if [ -d "$project_dir"/*.xcworkspace ]; then
    project_file="-workspace $(ls -d "$project_dir"/*.xcworkspace | head -1)"
  elif [ -d "$project_dir"/*.xcodeproj ]; then
    project_file="-project $(ls -d "$project_dir"/*.xcodeproj | head -1)"
  fi

  if [ -z "$scheme" ]; then
    scheme=$(xcodebuild -list $project_file 2>/dev/null | grep -A 100 "Schemes:" | grep -v "Schemes:" | head -1 | tr -d ' ')
  fi

  local test_args=""
  if [ -n "$test_target" ]; then
    test_args="-only-testing:$test_target"
  fi

  _ios_log "Running tests for $scheme on simulator $udid..."

  # shellcheck disable=SC2086
  xcodebuild test \
    $project_file \
    -scheme "$scheme" \
    -configuration Debug \
    -destination "platform=iOS Simulator,id=$udid" \
    -enableCodeCoverage YES \
    $test_args \
    2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# UI TESTING HELPERS
# ──────────────────────────────────────────────────────────────────────────────

# Wait for an element to appear (by label)
ios_sim_wait_for_element() {
  local label="$1"
  local timeout="${2:-30}"
  local udid="${3:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  _ios_log "Waiting for element with label '$label'..."

  local attempts=0
  while [ "$attempts" -lt "$timeout" ]; do
    local ui_json
    ui_json=$(ios_sim_describe_ui "$udid" 2>/dev/null)

    if echo "$ui_json" | grep -q "\"AXLabel\":\"$label\""; then
      _ios_log "Element found: $label"
      return 0
    fi

    sleep 1
    attempts=$((attempts + 1))
  done

  _ios_log "ERROR: Timeout waiting for element: $label"
  return 1
}

# Find element coordinates by label
ios_sim_find_element() {
  local label="$1"
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  if [ -z "$udid" ]; then
    udid=$(ios_sim_get_udid)
  fi

  local ui_json
  ui_json=$(ios_sim_describe_ui "$udid" 2>/dev/null)

  # Parse JSON to find element with matching label and return center coordinates
  echo "$ui_json" | python3 -c "
import json, sys
def find_element(elements, label):
    for el in elements if isinstance(elements, list) else [elements]:
        if el.get('AXLabel') == label:
            frame = el.get('frame', el.get('AXFrame', {}))
            if isinstance(frame, dict):
                x = frame.get('x', 0) + frame.get('width', 0) / 2
                y = frame.get('y', 0) + frame.get('height', 0) / 2
                print(f'{int(x)} {int(y)}')
                return True
        if 'children' in el:
            if find_element(el['children'], label):
                return True
    return False

try:
    data = json.load(sys.stdin)
    find_element(data, '$label')
except:
    pass
" 2>/dev/null
}

# Tap element by label
ios_sim_tap_element() {
  local label="$1"
  local udid="${2:-$IOS_SIMULATOR_UDID}"

  local coords
  coords=$(ios_sim_find_element "$label" "$udid")

  if [ -n "$coords" ]; then
    local x y
    x=$(echo "$coords" | cut -d' ' -f1)
    y=$(echo "$coords" | cut -d' ' -f2)
    ios_sim_tap "$x" "$y" "$udid"
  else
    _ios_log "ERROR: Element not found: $label"
    return 1
  fi
}

# ──────────────────────────────────────────────────────────────────────────────
# VISUAL REGRESSION
# ──────────────────────────────────────────────────────────────────────────────

# Compare screenshots for visual regression
ios_sim_compare_screenshots() {
  local baseline="$1"
  local current="$2"
  local threshold="${3:-0.01}"  # 1% difference allowed

  if [ ! -f "$baseline" ] || [ ! -f "$current" ]; then
    _ios_log "ERROR: Screenshot files not found"
    return 1
  fi

  # Use ImageMagick if available
  if command -v compare >/dev/null 2>&1; then
    local diff_output
    diff_output=$(compare -metric RMSE "$baseline" "$current" /dev/null 2>&1 | cut -d'(' -f2 | tr -d ')')

    if [ -n "$diff_output" ]; then
      local diff_pct
      diff_pct=$(echo "$diff_output" | awk '{print $1}')

      if awk "BEGIN {exit !($diff_pct > $threshold)}"; then
        _ios_log "Visual regression detected: $diff_pct difference (threshold: $threshold)"
        return 1
      fi

      _ios_log "Visual comparison passed: $diff_pct difference"
      return 0
    fi
  fi

  _ios_log "WARN: ImageMagick not available for visual comparison"
  return 0
}

# ──────────────────────────────────────────────────────────────────────────────
# ORCHESTRATOR INTEGRATION
# ──────────────────────────────────────────────────────────────────────────────

# Run a UI test flow
# Usage: ios_sim_run_ui_flow <flow_name> <bundle_id>
# Flow definitions should be in $FLOWS_DIR/<flow_name>.sh
ios_sim_run_ui_flow() {
  local flow_name="$1"
  local bundle_id="$2"
  local flows_dir="${FLOWS_DIR:-./flows}"

  local flow_script="$flows_dir/$flow_name.sh"

  if [ ! -f "$flow_script" ]; then
    _ios_log "ERROR: Flow script not found: $flow_script"
    return 1
  fi

  _ios_log "Running UI flow: $flow_name"

  # Ensure simulator is booted
  ios_sim_boot || return 1

  # Launch app
  ios_sim_launch_app "$bundle_id" "" "true" || return 1

  # Wait for app to load
  sleep 2

  # Run flow script
  # shellcheck disable=SC1090
  source "$flow_script"
}

# Validate app builds and launches successfully
ios_sim_validate_app() {
  local project_dir="$1"
  local bundle_id="$2"
  local scheme="${3:-}"

  _ios_log "Validating iOS app..."

  # 1. Ensure simulator is booted
  ios_sim_boot || return 1

  # 2. Build app
  local build_output
  build_output=$(ios_sim_build_app "$project_dir" "$scheme" 2>&1)

  if ! echo "$build_output" | grep -q "BUILD SUCCEEDED"; then
    _ios_log "ERROR: Build failed"
    echo "$build_output" | tail -50
    return 1
  fi

  # 3. Find built app
  local app_path
  app_path=$(find "$project_dir/build" -name "*.app" -type d | head -1)

  if [ -z "$app_path" ]; then
    _ios_log "ERROR: Built app not found"
    return 1
  fi

  # 4. Install and launch
  ios_sim_install_app "$app_path" || return 1
  ios_sim_launch_app "$bundle_id" || return 1

  # 5. Take verification screenshot
  local screenshot
  screenshot=$(ios_sim_screenshot)

  _ios_log "App validation complete. Screenshot: $screenshot"
  return 0
}
