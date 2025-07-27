# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

This is a macOS camera usage monitoring utility. The main implementation is `camera-monitor.swift` which continuously monitors camera device status and reports state changes in real-time.

## Core Implementation

**camera-monitor.swift**: Real-time camera monitoring daemon that:
- Enumerates all CoreMediaIO devices on the system
- Continuously polls device status using `kCMIODevicePropertyDeviceIsRunningSomewhere`
- Reports state changes (camera started/stopped) with device names
- Runs indefinitely with 1-second polling interval

## Common Commands

### Using Makefile (Recommended)
```bash
# Build the camera monitor
make build

# Build and run the monitor
make run

# Clean compiled binaries
make clean

# Install system-wide (optional)
make install

# Show all available targets
make help
```

### Manual Building
```bash
# Compile manually
swiftc -framework CoreMediaIO camera-monitor.swift -o camera-monitor

# Run the monitor
./camera-monitor
```

## Implementation Notes

- Uses CoreMediaIO framework for low-level camera device access
- Polls device state every second to detect changes
- Outputs English messages for camera state transitions
- Requires camera permissions in macOS System Preferences
- Use Ctrl+C to stop the monitoring process