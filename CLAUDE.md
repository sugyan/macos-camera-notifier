# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a macOS camera monitoring utility with extensible handler system for automated device control. The project uses a modular architecture that allows easy integration of different services and devices based on camera state changes.

## Architecture Details

### Core Components

**camera-monitor.swift**: CameraMonitor library that:

- Provides a `CameraMonitor` class for real-time camera monitoring
- Uses CoreMediaIO framework for low-level camera device access
- Offers callback-based state change notifications
- Supports both continuous monitoring and polling modes
- Handles device enumeration and state checking

**camera-state-handler.swift**: Handler protocol and registry system that:

- Defines `CameraStateHandler` protocol for all camera state handlers
- Provides `CameraStateHandlerRegistry` for managing multiple handlers
- Includes `HandlerLogger` utility for timestamped logging
- Supports async dispatch to prevent blocking
- Handles configuration errors and validation

**switchbot-sync.swift**: SwitchBot integration handler that:

- Implements `CameraStateHandler` protocol
- Automatically controls SwitchBot Plug devices when camera state changes
- Uses SwitchBot Cloud API v1.1 with HMAC-SHA256 authentication
- Supports auto-detection of available devices
- Includes comprehensive error handling

**camera-notifier.swift**: Main application entry point that:

- Lightweight configuration and dispatch management
- Command-line argument parsing (--help, --version)
- Environment variable configuration system
- Signal handling for graceful shutdown (SIGINT, SIGTERM)
- Registry-based handler management

## Project Structure

```
camera-notifier/
├── camera-monitor.swift          # Camera monitoring library
├── camera-state-handler.swift    # Handler protocol and registry
├── switchbot-sync.swift          # SwitchBot integration handler
├── camera-notifier.swift         # Main application entry point
├── camera-notifier               # Compiled binary (gitignored)
├── Makefile                      # Build configuration
├── README.md                     # User documentation
├── CLAUDE.md                     # This file
├── .gitignore                    # Git ignore rules
└── tmp/                          # Development files
```

## Common Commands

### Using Makefile (Recommended)

```bash
# Build the camera notifier
make build

# Build and run the notifier (requires environment variables)
make run

# Run with verbose logging
make run-verbose

# Show application help
make run-help

# Clean compiled binaries
make clean

# Format Swift code (requires swift-format)
make format

# Show Makefile help
make help
```

### Manual Building

```bash
# Compile manually
swiftc -framework CoreMediaIO -O -parse-as-library camera-monitor.swift camera-state-handler.swift switchbot-sync.swift camera-notifier.swift -o camera-notifier

# Run with environment variables
SWITCHBOT_TOKEN="your_token" SWITCHBOT_SECRET="your_secret" ./camera-notifier
```

## Environment Variables

### Application Configuration

- `CAMERA_HANDLERS`: Comma-separated list of handlers to enable (default: "switchbot")
- `VERBOSE`: Enable verbose logging ("1" to enable)

### SwitchBot Handler Configuration

- `SWITCHBOT_TOKEN`: SwitchBot API token (required)
- `SWITCHBOT_SECRET`: SwitchBot API secret (required)
- `SWITCHBOT_DEVICE_ID`: Target device ID (optional, auto-detects if not set)

## Implementation Notes

### Camera Monitoring

- Uses CoreMediaIO framework for low-level camera device access
- Polls device state every second using `kCMIODevicePropertyDeviceIsRunningSomewhere`
- Callback-based architecture for state change notifications
- Requires camera permissions in macOS System Preferences

### Handler System

- Protocol-based design allows easy extension
- Registry pattern manages multiple handlers
- Async dispatch prevents blocking on slow operations
- Configuration validation with meaningful error messages

### SwitchBot Integration

- Uses SwitchBot Cloud API v1.1 with HMAC-SHA256 authentication
- Automatically turns plug ON when camera starts
- Automatically turns plug OFF when camera stops
- Auto-detection of available devices if device ID not specified
- Comprehensive error handling and logging

### Build System

- Single binary compilation with parse-as-library flag
- Modular source file organization
- Makefile with multiple convenience targets
- Git ignore for compiled binaries

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

3. **Update Build**: Add file to `SWIFT_FILES` in Makefile

4. **Update Documentation**: Add environment variables and usage examples

## Troubleshooting

### Camera Permissions

- Grant access in System Preferences → Security & Privacy → Camera
- App needs to be in the allowed applications list

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

- Use `VERBOSE=1` for detailed logging
- Check environment variable names and values
- Verify handler names in `CAMERA_HANDLERS` are spelled correctly
- Use Ctrl+C for graceful shutdown

## Development Workflow

1. **Make Changes**: Edit source files as needed
2. **Clean Build**: `make clean && make build`
3. **Test**: Run with appropriate environment variables
4. **Format**: `make format` if swift-format is available
5. **Commit**: Git will ignore the compiled binary automatically
