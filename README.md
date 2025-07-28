# Camera Notifier

macOS camera monitoring tool that automatically controls SwitchBot devices when camera starts/stops. Supports background service mode with automatic startup.

## Overview

Automatically turns SwitchBot plugs ON when camera starts and OFF when camera stops. Perfect for automating lighting, fans, or other devices during video calls and recordings.

### Features

- 🎥 **Real-time camera monitoring** using CoreMediaIO framework
- 🔌 **SwitchBot device control** with automatic device detection
- 🚀 **macOS auto-start support** via launchd background service
- 📊 **Comprehensive logging** with separate error tracking
- ⚙️ **Extensible handler system** for future integrations

## Use Cases

- **Video call lighting control**: Camera ON → Lights ON, Camera OFF → Lights OFF
- **Fan/air purifier control**: Pause noisy devices during meetings
- **Recording environment control**: Activate specific devices only when camera is in use

## Setup

### 1. Get SwitchBot API Credentials

1. Open SwitchBot mobile app
2. Go to Settings → App Version (tap 10 times to enable Developer Mode)
3. Get your Token and Secret

### 2. Set Environment Variables

```bash
export SWITCHBOT_TOKEN="your_token_here"
export SWITCHBOT_SECRET="your_secret_here"
```

### 3. Run

```bash
# Build and run
make build
make run

# Or run directly
SWITCHBOT_TOKEN="your_token" SWITCHBOT_SECRET="your_secret" ./camera-notifier
```

## Auto-Start Setup (Optional)

To run camera-notifier automatically at startup as a background service:

### Quick Setup (Recommended)

```bash
# 1. Set environment variables
export SWITCHBOT_TOKEN="your_token_here"
export SWITCHBOT_SECRET="your_secret_here"

# 2. Run installation script
./scripts/install-launchd.sh
```

### Manual Setup

```bash
# 1. Build the project
make build

# 2. Copy and edit plist template
cp launchd/com.sugyan.camera-notifier.plist.template ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist

# 3. Edit the plist file and replace placeholders:
#    {{BINARY_PATH}} - Full path to binary
#    {{SWITCHBOT_TOKEN}} - Your API token
#    {{SWITCHBOT_SECRET}} - Your API secret

# 4. Load the service
launchctl load ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist
```

### Service Management

```bash
# Check service status
launchctl list | grep camera-notifier

# View logs
tail -f /tmp/camera-notifier.log

# Stop service
launchctl stop com.sugyan.camera-notifier

# Disable auto-start
launchctl unload ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist
```

## Examples

```bash
# Basic usage
export SWITCHBOT_TOKEN="your_actual_token"
export SWITCHBOT_SECRET="your_actual_secret"
make run

# Verbose logging
export VERBOSE=1
make run

# Show help
./camera-notifier --help
```

## Sample Output

```
[2024-01-15 10:30:45] Camera Notifier starting...
[2024-01-15 10:30:45] Active handlers: SwitchBot
[2024-01-15 10:30:46] [SwitchBot] Auto-detected device: Living Room Plug (ABC123DEF456)
[2024-01-15 10:30:46] Camera monitoring started. Press Ctrl+C to stop.
[2024-01-15 10:31:12] [SwitchBot] Camera started: FaceTime HD Camera, sending turnOn command
[2024-01-15 10:31:13] [SwitchBot] Device control success: success
[2024-01-15 10:35:20] [SwitchBot] Camera stopped: FaceTime HD Camera, sending turnOff command
[2024-01-15 10:35:21] [SwitchBot] Device control success: success
```

## Configuration

| Environment Variable  | Description                                | Required |
| --------------------- | ------------------------------------------ | -------- |
| `SWITCHBOT_TOKEN`     | SwitchBot API token                        | Yes      |
| `SWITCHBOT_SECRET`    | SwitchBot API secret                       | Yes      |
| `SWITCHBOT_DEVICE_ID` | Target device ID (auto-detects if not set) | No       |
| `VERBOSE`             | Enable verbose logging (set to `1`)        | No       |

## Troubleshooting

### Camera Permission Required

Grant camera access in: **System Preferences → Security & Privacy → Camera**

### SwitchBot Device Not Found

- Verify device is connected in SwitchBot app
- Check token/secret are correct
- Ensure internet connectivity

### Service Issues

Check log files for detailed information:

```bash
# View normal operation logs
tail -f /tmp/camera-notifier.log

# View error logs
tail -f /tmp/camera-notifier-error.log

# Check service status
launchctl list | grep camera-notifier
```

### Common Issues

- **Service not starting**: Check environment variables in plist file
- **Camera not detected**: Verify camera permissions in System Preferences
- **API errors**: Validate SwitchBot token/secret in mobile app

## Build Commands

```bash
make build      # Build
make run        # Run
make clean      # Clean up
make help       # Show help
```

## License

MIT License
