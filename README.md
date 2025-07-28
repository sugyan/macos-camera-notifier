# Camera Notifier

macOS camera monitoring tool that automatically controls SwitchBot devices when camera starts/stops.

## Overview

Automatically turns SwitchBot plugs ON when camera starts and OFF when camera stops. Perfect for automating lighting, fans, or other devices during video calls and recordings.

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

## Build Commands

```bash
make build      # Build
make run        # Run
make clean      # Clean up
make help       # Show help
```

## License

MIT License
