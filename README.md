# Camera Notifier

macOS camera monitoring tool that automatically controls SwitchBot devices when camera starts/stops. Supports background service mode with automatic startup.

## Overview

Automatically turns SwitchBot plugs ON when camera starts and OFF when camera stops. Perfect for automating lighting, fans, or other devices during video calls and recordings.

### Features

- 🎥 **Real-time camera monitoring** using CoreMediaIO property listeners, backed by a periodic rescan
- 🔁 **Hot-plug aware**: cameras connected after startup (USB replug, dock reconnect, Continuity Camera) and cameras re-enumerated after sleep are picked up automatically
- 🔌 **SwitchBot device control** with automatic device detection, in-order delivery (only the latest state is sent) and retries on failure
- 🚀 **macOS auto-start support** via launchd background service
- 📊 **Comprehensive logging** of camera state, device add/remove and wake from sleep
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
SWITCHBOT_TOKEN="your_token" SWITCHBOT_SECRET="your_secret" ./.build/release/camera-notifier

# Check camera detection only, without controlling any device
./.build/release/camera-notifier --handlers log
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

The script builds the binary, generates the plist (readable only by you, since it contains the token), and (re)loads the service.
The plist stores the absolute path of the binary, so run it again after moving the repository.

### Manual Setup

```bash
# 1. Build the project
make build

# 2. Copy and edit plist template
cp launchd/com.sugyan.camera-notifier.plist.template ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist
chmod 600 ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist

# 3. Edit the plist file and replace placeholders:
#    {{BINARY_PATH}} - Full path to binary
#    {{SWITCHBOT_TOKEN}} - Your API token
#    {{SWITCHBOT_SECRET}} - Your API secret
#    {{SWITCHBOT_DEVICE_ID_LINE}} - Remove, or replace with a SWITCHBOT_DEVICE_ID key/string pair

# 4. Load the service
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.sugyan.camera-notifier.plist
```

### Service Management

```bash
# Check service status
launchctl print gui/$(id -u)/com.sugyan.camera-notifier

# View logs
tail -f /tmp/camera-notifier.log

# Restart service (e.g. after rebuilding)
launchctl kickstart -k gui/$(id -u)/com.sugyan.camera-notifier

# Stop service (until next login or bootstrap)
launchctl bootout gui/$(id -u)/com.sugyan.camera-notifier
```

To disable auto-start permanently, run `bootout` and remove `~/Library/LaunchAgents/com.sugyan.camera-notifier.plist`.

## Examples

```bash
# Basic usage
export SWITCHBOT_TOKEN="your_actual_token"
export SWITCHBOT_SECRET="your_actual_secret"
make run

# Verbose logging
export VERBOSE=1
make run

# Log camera state changes only (no SwitchBot)
./.build/release/camera-notifier --handlers log

# Show help
./.build/release/camera-notifier --help
```

## Sample Output

```
[2026-01-15 10:30:45] Camera Notifier starting...
[2026-01-15 10:30:46] [SwitchBot] Auto-detected device: Living Room Plug (ABC123DEF456)
[2026-01-15 10:30:46] Active handlers: SwitchBot
[2026-01-15 10:30:46] Camera monitoring started. Press Ctrl+C to stop.
[2026-01-15 10:30:46] [CameraMonitor] Camera device added: FaceTime HD Camera [id=34 uid=...]
[2026-01-15 10:30:46] [CameraMonitor] Monitoring 1 camera device(s); rescanning every 1.0s
[2026-01-15 10:30:46] [CameraMonitor] Camera state changed: OFF - Device: unknown
[2026-01-15 10:30:46] [SwitchBot] Camera stopped: Unknown device, sending turnOff command
[2026-01-15 10:30:47] [SwitchBot] Device control success: turnOff (success)
[2026-01-15 10:31:12] [CameraMonitor] Camera state changed: ON - Device: FaceTime HD Camera
[2026-01-15 10:31:12] [SwitchBot] Camera started: FaceTime HD Camera, sending turnOn command
[2026-01-15 10:31:13] [SwitchBot] Device control success: turnOn (success)
[2026-01-15 12:02:40] [CameraMonitor] Resumed after system sleep (slept ~1h25m), rescanning camera devices
[2026-01-15 12:02:41] [CameraMonitor] Camera device removed: USB Camera [id=44]
[2026-01-15 12:02:42] [CameraMonitor] Camera device added: USB Camera [id=52 uid=...]
```

## Configuration

| Environment Variable  | Description                                | Required |
| --------------------- | ------------------------------------------ | -------- |
| `SWITCHBOT_TOKEN`     | SwitchBot API token                        | Yes      |
| `SWITCHBOT_SECRET`    | SwitchBot API secret                       | Yes      |
| `SWITCHBOT_DEVICE_ID` | Target device ID (auto-detects if not set) | No       |
| `CAMERA_HANDLERS`     | Handlers to enable: `switchbot`, `log` (default: `switchbot`) | No |
| `VERBOSE`             | Enable verbose logging (set to `1`)        | No       |

## Troubleshooting

### Camera Not Detected

Run `./.build/release/camera-notifier --handlers log` and check that your camera shows up in a `Camera device added` line, and that `Camera state changed: ON` appears when an app starts using it.
If no devices are listed, check **System Settings → Privacy & Security → Camera**.

### SwitchBot Device Not Found

- Verify device is connected in SwitchBot app
- Check token/secret are correct
- Ensure internet connectivity
- Set `SWITCHBOT_DEVICE_ID` to skip auto-detection (the auto-detected ID is printed in the log)

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
- **Service runs an old binary**: The plist stores the absolute binary path; re-run `./scripts/install-launchd.sh` after moving the repository
- **Plug not switching**: Look for `Device control failed` lines; failed commands are retried with backoff (up to 8 attempts)
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
