#!/bin/bash

# Camera Notifier - launchd Installation Helper
# This script helps set up camera-notifier as a macOS background service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PLIST_TEMPLATE="$PROJECT_DIR/launchd/com.sugyan.camera-notifier.plist.template"
LABEL="com.sugyan.camera-notifier"
PLIST_DEST="$HOME/Library/LaunchAgents/$LABEL.plist"
BINARY_PATH="$PROJECT_DIR/.build/release/camera-notifier"
DOMAIN="gui/$(id -u)"

echo "🔧 Camera Notifier - launchd Setup"
echo "=================================="

# Check if template exists
if [[ ! -f "$PLIST_TEMPLATE" ]]; then
    echo "❌ Error: plist template not found at $PLIST_TEMPLATE"
    exit 1
fi

# Check environment variables
echo "📋 Checking environment variables..."
missing_vars=()

if [[ -z "$SWITCHBOT_TOKEN" ]]; then
    missing_vars+=("SWITCHBOT_TOKEN")
fi

if [[ -z "$SWITCHBOT_SECRET" ]]; then
    missing_vars+=("SWITCHBOT_SECRET")
fi

if [[ ${#missing_vars[@]} -gt 0 ]]; then
    echo "❌ Missing required environment variables:"
    for var in "${missing_vars[@]}"; do
        echo "   - $var"
    done
    echo ""
    echo "Please set these variables and run again:"
    echo "   export SWITCHBOT_TOKEN=\"your_token_here\""
    echo "   export SWITCHBOT_SECRET=\"your_secret_here\""
    echo "   export SWITCHBOT_DEVICE_ID=\"device_id\" # optional"
    exit 1
fi

echo "✅ Environment variables OK"

# Always build (incremental) so the service runs the current sources
echo "🔨 Building camera-notifier binary..."
(cd "$PROJECT_DIR" && make build)

if [[ ! -f "$BINARY_PATH" ]]; then
    echo "❌ Error: Failed to build binary at $BINARY_PATH"
    exit 1
fi

echo "✅ Binary found at $BINARY_PATH"

# Create LaunchAgents directory if it doesn't exist
mkdir -p "$HOME/Library/LaunchAgents"

# Generate plist from template
echo "📝 Generating plist configuration..."

# Handle optional SWITCHBOT_DEVICE_ID
if [[ -n "$SWITCHBOT_DEVICE_ID" && "$SWITCHBOT_DEVICE_ID" != "" ]]; then
    DEVICE_ID_LINE="<key>SWITCHBOT_DEVICE_ID</key>
		<string>$SWITCHBOT_DEVICE_ID</string>"
    echo "  Using specified device ID: $SWITCHBOT_DEVICE_ID"
else
    DEVICE_ID_LINE=""
    echo "  No device ID specified, will use auto-detection"
fi

sed "s|{{BINARY_PATH}}|$BINARY_PATH|g; \
     s|{{SWITCHBOT_TOKEN}}|${SWITCHBOT_TOKEN}|g; \
     s|{{SWITCHBOT_SECRET}}|${SWITCHBOT_SECRET}|g; \
     s|{{SWITCHBOT_DEVICE_ID_LINE}}|${DEVICE_ID_LINE}|g" \
    "$PLIST_TEMPLATE" > "$PLIST_DEST"

# The plist contains the API token and secret: keep it private
chmod 600 "$PLIST_DEST"

echo "✅ Created plist at $PLIST_DEST"

# Unload existing service if it exists
if launchctl print "$DOMAIN/$LABEL" > /dev/null 2>&1; then
    echo "🔄 Unloading existing service..."
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
fi

# Load the service (retry briefly: bootstrap can fail while the old instance is still exiting)
echo "🚀 Loading service..."
for _ in 1 2 3 4 5; do
    if launchctl bootstrap "$DOMAIN" "$PLIST_DEST" 2>/dev/null; then
        break
    fi
    sleep 1
done

# Verify service is running
sleep 2
if launchctl print "$DOMAIN/$LABEL" > /dev/null 2>&1; then
    echo "✅ Service loaded successfully!"
    echo ""
    echo "📊 Service Status:"
    launchctl print "$DOMAIN/$LABEL" | grep -E "^\s*(state|pid|program|last exit code) =" || true
    echo ""
    echo "📁 Log Files:"
    echo "   Output: /tmp/camera-notifier.log"
    echo "   Errors: /tmp/camera-notifier-error.log"
    echo ""
    echo "🎯 Commands:"
    echo "   Status:  launchctl print $DOMAIN/$LABEL"
    echo "   Restart: launchctl kickstart -k $DOMAIN/$LABEL"
    echo "   Stop:    launchctl bootout $DOMAIN/$LABEL"
    echo "   Start:   launchctl bootstrap $DOMAIN $PLIST_DEST"
    echo "   Logs:    tail -f /tmp/camera-notifier.log"
else
    echo "❌ Failed to load service"
    echo "Check the error log: /tmp/camera-notifier-error.log"
    exit 1
fi