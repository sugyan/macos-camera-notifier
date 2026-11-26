#!/bin/bash

# Camera Notifier - launchd Installation Helper
# This script helps set up camera-notifier as a macOS background service

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
PLIST_TEMPLATE="$PROJECT_DIR/launchd/com.sugyan.camera-notifier.plist.template"
LABEL="com.sugyan.camera-notifier"
PLIST_DIR="$HOME/Library/LaunchAgents"
PLIST_DEST="$PLIST_DIR/$LABEL.plist"
BINARY_PATH="$PROJECT_DIR/.build/release/camera-notifier"
DOMAIN="gui/$(id -u)"
SERVICE="$DOMAIN/$LABEL"
# `launchctl print` also prints the job's environment, i.e. the SwitchBot token and secret:
# only ever show these lines of it
STATUS_FILTER='^[[:space:]]*(state|pid|program|last exit code) = '

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
mkdir -p "$PLIST_DIR"

# Generate plist from template
echo "📝 Generating plist configuration..."

# Handle optional SWITCHBOT_DEVICE_ID (on one line: a sed replacement cannot contain a newline)
if [[ -n "$SWITCHBOT_DEVICE_ID" ]]; then
    DEVICE_ID_LINE="<key>SWITCHBOT_DEVICE_ID</key><string>$SWITCHBOT_DEVICE_ID</string>"
    echo "  Using specified device ID: $SWITCHBOT_DEVICE_ID"
else
    DEVICE_ID_LINE=""
    echo "  No device ID specified, will use auto-detection"
fi

# Escape a value for the replacement part of a sed s||| command
sed_escape() {
    printf '%s' "$1" | sed -e 's/[\\|&]/\\&/g'
}

# Build the new plist in private temporary files (mktemp creates them with mode 600) and replace
# the installed one only once the result is valid: a failure never leaves a broken or empty plist.
# The sed script is written with printf (a builtin), so the secrets never appear in `ps`.
SED_SCRIPT="$(mktemp)"
TMP_PLIST="$(mktemp "$PLIST_DIR/.$LABEL.XXXXXX")"
trap 'rm -f "$SED_SCRIPT" "$TMP_PLIST"' EXIT

{
    printf 's|{{BINARY_PATH}}|%s|g\n' "$(sed_escape "$BINARY_PATH")"
    printf 's|{{SWITCHBOT_TOKEN}}|%s|g\n' "$(sed_escape "$SWITCHBOT_TOKEN")"
    printf 's|{{SWITCHBOT_SECRET}}|%s|g\n' "$(sed_escape "$SWITCHBOT_SECRET")"
    printf 's|{{SWITCHBOT_DEVICE_ID_LINE}}|%s|g\n' "$(sed_escape "$DEVICE_ID_LINE")"
} > "$SED_SCRIPT"
sed -f "$SED_SCRIPT" "$PLIST_TEMPLATE" > "$TMP_PLIST"

if ! plutil -lint -s "$TMP_PLIST"; then
    echo "❌ Error: the generated plist is invalid; $PLIST_DEST was left unchanged"
    exit 1
fi
mv -f "$TMP_PLIST" "$PLIST_DEST"

echo "✅ Created plist at $PLIST_DEST"

# Unload the existing service and wait until launchd has removed it: bootstrap fails while the
# old instance is still being torn down
if launchctl print "$SERVICE" > /dev/null 2>&1; then
    echo "🔄 Unloading existing service..."
    bootout_output=$(launchctl bootout "$SERVICE" 2>&1) || true
    for ((i = 0; i < 30; i++)); do
        launchctl print "$SERVICE" > /dev/null 2>&1 || break
        sleep 0.5
    done
    if launchctl print "$SERVICE" > /dev/null 2>&1; then
        echo "❌ Error: the existing service is still loaded after 15s${bootout_output:+ ($bootout_output)}"
        echo "   The new plist is installed; run this script again in a moment, or unload the"
        echo "   service with 'launchctl bootout $SERVICE' first"
        exit 1
    fi
fi

# Load the service (retry briefly in case launchd is still busy with the old instance)
echo "🚀 Loading service..."
loaded=false
for _ in 1 2 3 4 5; do
    if bootstrap_output=$(launchctl bootstrap "$DOMAIN" "$PLIST_DEST" 2>&1); then
        loaded=true
        break
    fi
    sleep 1
done

if [[ "$loaded" != true ]]; then
    echo "❌ Failed to load service: ${bootstrap_output:-unknown error}"
    if launchctl print-disabled "$DOMAIN" 2>/dev/null | grep -qE "\"$LABEL\" => (true|disabled)"; then
        echo "   The service is disabled. Enable it with: launchctl enable $SERVICE"
    else
        echo "   Check that camera-notifier is allowed in System Settings → General → Login Items & Extensions"
    fi
    echo "   Then run: launchctl bootstrap $DOMAIN $PLIST_DEST"
    exit 1
fi

# Verify service is running
sleep 2
status=$(launchctl print "$SERVICE" 2>/dev/null | grep -E "$STATUS_FILTER" || true)
if [[ -z "$status" ]]; then
    echo "❌ The service was loaded but is no longer registered"
    echo "Check the error log: /tmp/camera-notifier-error.log"
    exit 1
fi

echo "✅ Service loaded successfully!"
echo ""
echo "📊 Service Status:"
echo "$status"
if ! grep -qE 'state = running' <<< "$status"; then
    echo "⚠️  The service is not running; check /tmp/camera-notifier-error.log"
fi
echo ""
echo "📁 Log Files:"
echo "   Output: /tmp/camera-notifier.log"
echo "   Errors: /tmp/camera-notifier-error.log"
echo ""
echo "🎯 Commands:"
echo "   Status:  launchctl print $SERVICE | grep -E '$STATUS_FILTER'"
echo "            (plain 'launchctl print' also shows the SwitchBot token and secret)"
echo "   Restart: launchctl kickstart -k $SERVICE"
echo "   Stop:    launchctl bootout $SERVICE"
echo "   Start:   launchctl bootstrap $DOMAIN $PLIST_DEST"
echo "   Logs:    tail -f /tmp/camera-notifier.log"
