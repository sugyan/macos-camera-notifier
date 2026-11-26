# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a macOS camera monitoring utility with extensible handler system for automated device control. The project uses a modular architecture that allows easy integration of different services and devices based on camera state changes.

## Architecture Details

### Core Components

**camera-monitor.swift**: CameraMonitor library that:

- Provides a `CameraMonitor` class for real-time camera monitoring (`start(onStateChange:)`)
- Uses CoreMediaIO framework for low-level camera device access
- Tracks the device list dynamically: cameras connected or re-enumerated after startup are picked up
- Combines CoreMediaIO property listeners with a periodic rescan (every 1s) as a safety net
- Reports ON at once, but OFF only after no camera has been in use for the off delay (default 5s)
- Reports the current state once at startup, then every change, on its own serial queue
- Logs device add/remove and wake from sleep for diagnostics

**power-observer.swift**: `SystemPowerObserver`, a thin IOKit (`IORegisterForSystemPower`) wrapper
that calls back right before the system sleeps and after it wakes

**camera-state-handler.swift**: Handler protocol and registry system that:

- Defines `CameraStateHandler` protocol for all camera state handlers
- Provides `CameraStateHandlerRegistry` for managing multiple handlers
- Includes `HandlerLogger` utility for timestamped logging
- Dispatches to each handler on its own serial queue (non-blocking, in order)
- Handles configuration errors and validation

**switchbot-sync.swift**: SwitchBot integration handler that:

- Implements `CameraStateHandler` protocol
- Automatically controls SwitchBot Plug devices when camera state changes
- Uses SwitchBot Cloud API v1.1 with HMAC-SHA256 authentication
- Supports auto-detection of available devices
- Sends one command at a time (only the latest state), retrying failures with backoff

**camera-notifier.swift**: Main application entry point that:

- Uses Swift Argument Parser for type-safe CLI argument parsing
- Supports --handlers, --verbose and --off-delay command-line options
- Environment variable configuration system
- Signal handling for graceful shutdown (SIGINT, SIGTERM) via dispatch signal sources: reports a
  pending OFF at once and gives the handlers a few seconds to deliver it before exiting
- Before sleep, reports a pending OFF and lets the handlers deliver it (sleep waits, at most ~4s)
- Registry-based handler management
- Runs the main run loop; everything after startup is event driven

**log-handler.swift**: Log-only handler (`--handlers log`) that prints camera state changes without side effects

## Project Structure

```
camera-notifier/
├── Package.swift                 # Swift Package Manager configuration
├── Sources/                      # Source code directory
│   ├── camera-monitor.swift      # Camera monitoring library
│   ├── camera-state-handler.swift # Handler protocol and registry
│   ├── switchbot-sync.swift      # SwitchBot integration handler
│   ├── log-handler.swift         # Log-only handler (diagnostics)
│   ├── power-observer.swift      # Sleep/wake notifications (IOKit)
│   └── camera-notifier.swift     # Main application entry point
├── .build/release/camera-notifier # Compiled binary (SPM output)
├── Makefile                      # Build configuration
├── README.md                     # User documentation
├── CLAUDE.md                     # This file
└── .gitignore                    # Git ignore rules
```

## Common Commands

### Using Makefile (Recommended)

```bash
# Build the camera notifier
make build

# Build and run the notifier (requires environment variables)
make run

# Clean compiled binaries
make clean

# Format Swift code (requires swift-format)
make format

# Show Makefile help
make help
```

### Using Swift Package Manager Directly

```bash
# Build with Swift Package Manager
swift build -c release

# Run the built binary directly
./.build/release/camera-notifier --help
./.build/release/camera-notifier --verbose
./.build/release/camera-notifier --handlers switchbot

# Check camera detection only, without controlling any device
./.build/release/camera-notifier --handlers log

# Run with environment variables
SWITCHBOT_TOKEN="your_token" SWITCHBOT_SECRET="your_secret" ./.build/release/camera-notifier
```

## Configuration Options

### Command Line Arguments (via Swift Argument Parser)

- `--handlers <handlers>`: Comma-separated list of handlers to enable: `switchbot`, `log` (default: "switchbot")
- `--verbose` / `-v`: Enable verbose logging
- `--off-delay <seconds>`: Seconds without camera use before OFF is reported (default: 5)
- `--help` / `-h`: Show help information
- `--version`: Show version information

### Environment Variables (fallback)

- `CAMERA_HANDLERS`: Comma-separated list of handlers to enable (default: "switchbot")
- `VERBOSE`: Enable verbose logging ("1" to enable)
- `CAMERA_OFF_DELAY`: Seconds without camera use before OFF is reported (default: 5)

### SwitchBot Handler Configuration

- `SWITCHBOT_TOKEN`: SwitchBot API token (required)
- `SWITCHBOT_SECRET`: SwitchBot API secret (required)
- `SWITCHBOT_DEVICE_ID`: Target device ID (optional, auto-detects if not set)

## Implementation Notes

### Camera Monitoring

- Uses CoreMediaIO framework for low-level camera device access
- A camera is "in use" when `kCMIODevicePropertyDeviceIsRunningSomewhere` is non-zero for any device
- The device list (`kCMIOHardwarePropertyDevices`) must never be cached for the process lifetime:
  a USB camera gets a new `CMIOObjectID` whenever it is re-enumerated (unplug/replug, dock
  reconnect, sometimes after sleep). Caching it made the tool stop reacting until restarted.
- `CMIOObjectAddPropertyListenerBlock` listeners on the device list and on each device give low
  latency; a 1s `DispatchSourceTimer` rescans and re-evaluates as a safety net
- OFF is debounced: apps stop and restart capture for up to a few seconds (meeting app preview →
  call, camera switch), which would otherwise toggle the plug. Gaps of 1-4s were seen in practice.
  The initial OFF at startup is delayed too, so a restart never flashes the light.
- Nothing is reported until the device list has been read once (an unreadable list is not "OFF");
  a failed per-device read counts as "not in use", which the off delay absorbs
- Right before sleep (`SystemPowerObserver`), a pending OFF is reported at once, and until wake OFF
  is not delayed: the process is suspended during sleep, so a delayed OFF would only fire after wake
- Per-device listeners are registered once per object ID and never removed: Swift bridges the
  closure to a new block on each call, so `CMIOObjectRemovePropertyListenerBlock` cannot match it
- Wake from sleep is detected (for logging) by comparing `CLOCK_MONOTONIC_RAW` and `CLOCK_UPTIME_RAW`
- `CameraMonitor` runs on its own queue; the main thread only runs `RunLoop.main.run()` and handles
  signals, so Ctrl+C and SIGTERM work even if a CoreMediaIO call hangs

### Handler System

- Protocol-based design allows easy extension
- Registry pattern manages multiple handlers
- Each handler gets its own serial queue: slow handlers never block monitoring, and changes arrive in order
- `flush(timeout:)` (before sleep) and `cleanup()` (before exit) let a handler finish pending work;
  both block briefly, with a bounded wait
- Configuration validation with meaningful error messages

### SwitchBot Integration

- Uses SwitchBot Cloud API v1.1 with HMAC-SHA256 authentication
- Automatically turns plug ON when camera starts
- Automatically turns plug OFF when camera stops
- Syncs the plug with the current camera state at startup
- Auto-detection of available devices if device ID not specified
- One request in flight at a time; if the state changes meanwhile, only the latest state is sent
- Retries with exponential backoff (2s up to 60s, max 8 attempts) on network errors, HTTP 429/5xx,
  and API statusCode 161/171/190; not on 401 or other client errors
- `URLSession` with `waitsForConnectivity` so requests right after wake wait for the network
- Checks both the HTTP status and the API `statusCode` (100 = success), before decoding the body
- Before sleep and at shutdown, a command waiting for its retry is sent at once; at shutdown the
  last command gets up to 5s and is not retried afterwards

### Build System

- Uses Swift Package Manager for dependency management
- Swift Argument Parser for CLI argument parsing
- Modular source file organization in Sources/ directory
- Simplified Makefile with essential targets
- Binary output in .build/release/ directory

## Adding New Handlers

To add a new handler type (e.g., Slack notifications):

1. **Create Handler File**: `slack-notification.swift`

```swift
public class SlackNotificationHandler: CameraStateHandler {
    public let name = "Slack"
    public var isEnabled: Bool { /* check config */ }

    public func configure() throws {
        // Load SLACK_WEBHOOK_URL, etc.
    }

    public func handleCameraStateChange(_ change: CameraStateChange) {
        // Send notification to Slack
    }
}
```

2. **Register Handler**: In `camera-notifier.swift`

```swift
if config.enabledHandlers.contains("slack") {
    handlerRegistry.register(SlackNotificationHandler())
}
```

3. **Update Build**: Add file to Sources/ directory (automatically included by SPM)

4. **Update Documentation**: Add environment variables and usage examples

## Troubleshooting

### Camera Detection

- Run `./.build/release/camera-notifier --handlers log` and check for `Camera device added` lines
  and `Camera state changed` when an app starts or stops using the camera
- If no devices are listed, check System Settings → Privacy & Security → Camera

### SwitchBot API Issues

- Verify token/secret are correct and not expired
- Check network connectivity
- Ensure device is online in SwitchBot app
- Test API credentials with SwitchBot mobile app first

### Build Issues

- Ensure CoreMediaIO framework is available (macOS required)
- Check Swift compiler version compatibility
- Verify all source files are present

### Runtime Issues

- Use `--verbose` flag or `VERBOSE=1` environment variable for detailed logging
- `Camera device added/removed` and `Resumed after system sleep` lines show device re-enumeration
- `Device control failed ... retrying in Ns` / `giving up` lines show SwitchBot delivery problems
- Check environment variable names and values
- Verify handler names in `--handlers` option or `CAMERA_HANDLERS` are spelled correctly
- Use Ctrl+C for graceful shutdown

## macOS Auto-Start Setup

### Using launchd (System Service)

To run camera-notifier automatically at startup as a background service:

1. **Build the Binary**:
   ```bash
   make build
   ```

2. **Create Configuration**:
   Copy and customize the plist template:
   ```bash
   cp launchd/com.sugyan.camera-notifier.plist.template ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist
   ```

3. **Update Configuration**:
   Edit `~/Library/LaunchAgents/com.sugyan.camera-notifier.plist` and replace placeholders:
   - `{{BINARY_PATH}}`: Full path to compiled binary (e.g., `/Users/username/dev/camera-notifier/.build/release/camera-notifier`)
   - `{{SWITCHBOT_TOKEN}}`: Your SwitchBot API token
   - `{{SWITCHBOT_SECRET}}`: Your SwitchBot API secret
   - `{{SWITCHBOT_DEVICE_ID_LINE}}`: Delete it to auto-detect the plug, or replace it with
     `<key>SWITCHBOT_DEVICE_ID</key><string>YOUR_DEVICE_ID</string>`

4. **Load Service**:
   ```bash
   chmod 600 ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist
   ```

5. **Verify Service**:
   ```bash
   launchctl print gui/$(id -u)/com.sugyan.camera-notifier | grep -E '^[[:space:]]*(state|pid|program|last exit code) = '
   tail -f /tmp/camera-notifier.log
   ```
   Never share unfiltered `launchctl print` output: it includes the job's environment, i.e. the
   SwitchBot token and secret.

`scripts/install-launchd.sh` performs all of the above (build, plist generation, chmod, bootout/bootstrap).
The plist stores the absolute binary path, so re-run it after moving the repository.

### Service Management Commands

```bash
# Status (filtered: plain `launchctl print` also shows the token and secret)
launchctl print gui/$(id -u)/com.sugyan.camera-notifier | grep -E '^[[:space:]]*(state|pid|program|last exit code) = '

# Restart (e.g. after rebuilding the binary)
launchctl kickstart -k gui/$(id -u)/com.sugyan.camera-notifier

# Stop (until next login or bootstrap)
launchctl bootout gui/$(id -u)/com.sugyan.camera-notifier

# Reload service after plist changes
launchctl bootout gui/$(id -u)/com.sugyan.camera-notifier
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist
```

Note: with `KeepAlive`, the legacy `launchctl stop` only restarts the job.

### Log Files

- Standard output: `/tmp/camera-notifier.log`
- Error output: `/tmp/camera-notifier-error.log`

## Development Workflow

1. **Make Changes**: Edit source files as needed
2. **Clean Build**: `make clean && make build`
3. **Test**: Run with appropriate environment variables
4. **Format**: `make format` if swift-format is available
5. **Commit**: Git will ignore the compiled binary automatically
