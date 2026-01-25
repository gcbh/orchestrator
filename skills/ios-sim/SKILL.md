---
name: ios-sim
description: Build, install, and interact with iOS apps on the simulator using MCP tools
argument-hint: "[build|run|screenshot|tap|describe|status]"
allowed-tools: Bash, Read, Write, Glob, Grep, mcp__ios-simulator__*
---

# iOS Simulator Skill

You are an iOS development assistant with access to both shell functions and MCP tools for simulator interaction.

## Available Commands

Based on `$ARGUMENTS`, perform the appropriate action:

### `/ios-sim status`
Show current simulator state:
1. Get booted simulator: `mcp__ios-simulator__get_booted_sim_id`
2. List available simulators: `xcrun simctl list devices available | grep -E "iPhone|iPad" | head -15`
3. Report which simulator is active

### `/ios-sim build [project_path]`
Build an iOS app for the simulator:
1. Find the Xcode project in the given path (or current directory)
2. Detect the scheme: `xcodebuild -list`
3. Get booted simulator UDID
4. Build: `xcodebuild build -scheme <scheme> -configuration Debug -destination 'platform=iOS Simulator,id=<udid>' -derivedDataPath build`
5. Report success/failure

### `/ios-sim run [bundle_id]` or `/ios-sim launch [bundle_id]`
Install and launch an app:
1. Find the built .app in `build/Build/Products/Debug-iphonesimulator/`
2. Use `mcp__ios-simulator__install_app` to install
3. Use `mcp__ios-simulator__launch_app` to launch
4. Take a screenshot to confirm it's running

### `/ios-sim screenshot [output_path]`
Capture the current simulator screen:
1. Use `mcp__ios-simulator__screenshot` with the output path
2. Read and display the screenshot
3. Report the file location

### `/ios-sim describe`
Describe the current UI using accessibility info:
1. Use `mcp__ios-simulator__ui_describe_all` to get the accessibility tree
2. Parse and present the UI elements in a readable format
3. Highlight interactive elements (buttons, text fields)

### `/ios-sim tap <x> <y>` or `/ios-sim tap <element_label>`
Tap on the screen:
- If coordinates given: `mcp__ios-simulator__ui_tap` at x, y
- If label given:
  1. Use `mcp__ios-simulator__ui_describe_all` to find element
  2. Calculate center coordinates
  3. Tap at those coordinates
4. Take a screenshot after to show result

### `/ios-sim type <text>`
Type text into the focused field:
1. Use `mcp__ios-simulator__ui_type` with the text
2. Take a screenshot to confirm

### `/ios-sim swipe <direction>` or `/ios-sim swipe <x1> <y1> <x2> <y2>`
Perform a swipe gesture:
- If direction (up/down/left/right): calculate start/end points
- If coordinates: use directly
1. Use `mcp__ios-simulator__ui_swipe`
2. Take a screenshot after

### `/ios-sim boot [device_name]`
Boot a specific simulator:
1. List available devices if no name given
2. Find matching device UDID
3. Boot with `xcrun simctl boot <udid>`
4. Open Simulator.app: `open -a Simulator`

## Shell Module Integration

For complex operations, you can also use the shell module:
```bash
source ~/.local/lib/orchestrator/ios_simulator_mcp.sh
```

Available functions:
- `ios_sim_boot` - Boot simulator
- `ios_sim_install_app <path>` - Install app
- `ios_sim_launch_app <bundle_id>` - Launch app
- `ios_sim_screenshot [path]` - Take screenshot
- `ios_sim_tap <x> <y>` - Tap coordinates
- `ios_sim_describe_ui` - Get accessibility tree
- `ios_sim_validate_app <project> <bundle_id>` - Full build/install/launch validation

## MCP Tools Reference

| Tool | Purpose |
|------|---------|
| `mcp__ios-simulator__get_booted_sim_id` | Get currently booted simulator |
| `mcp__ios-simulator__open_simulator` | Open Simulator.app |
| `mcp__ios-simulator__ui_describe_all` | Describe all UI elements |
| `mcp__ios-simulator__ui_tap` | Tap at coordinates |
| `mcp__ios-simulator__ui_type` | Input text |
| `mcp__ios-simulator__ui_swipe` | Swipe gesture |
| `mcp__ios-simulator__screenshot` | Take screenshot |
| `mcp__ios-simulator__install_app` | Install .app bundle |
| `mcp__ios-simulator__launch_app` | Launch by bundle ID |

## Example Workflows

### Build and Run
```
/ios-sim build /path/to/ios/project
/ios-sim run com.myapp.bundle
```

### Navigate UI
```
/ios-sim describe
/ios-sim tap "Settings"
/ios-sim screenshot /tmp/settings.png
```

### Full Test Flow
```
/ios-sim status
/ios-sim build
/ios-sim run com.financialadvisor.app
/ios-sim tap "Settings"
/ios-sim tap "Set Up Gmail"
/ios-sim type "test@example.com"
/ios-sim screenshot /tmp/gmail-setup.png
```

## Important Notes

- Always check simulator is booted before operations
- Take screenshots to confirm UI state after interactions
- The MCP tools use `idb` which requires `idb_companion` running
- Coordinates are in screen points (check image scaling notes)
- Use `describe` to find element positions before tapping
