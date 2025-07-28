# Makefile for Camera Notifier
# macOS camera monitoring with extensible handler system

# Variables
SWIFT_FILES = camera-monitor.swift camera-state-handler.swift switchbot-sync.swift camera-notifier.swift
TARGET = camera-notifier
FRAMEWORK = -framework CoreMediaIO
SWIFT_FLAGS = -O -parse-as-library

# Default target
.PHONY: all
all: build

# Build the camera notifier
.PHONY: build
build: $(TARGET)

$(TARGET): $(SWIFT_FILES)
	@echo "Building camera notifier..."
	swiftc $(FRAMEWORK) $(SWIFT_FLAGS) $(SWIFT_FILES) -o $(TARGET)
	@echo "Build complete: $(TARGET)"

# Run the camera notifier (builds if necessary)
.PHONY: run
run: $(TARGET)
	@echo "Starting camera notifier (Press Ctrl+C to stop)..."
	@echo "Make sure to set required environment variables for your handlers"
	./$(TARGET)

# Run with verbose logging
.PHONY: run-verbose
run-verbose: $(TARGET)
	@echo "Starting camera notifier with verbose logging..."
	VERBOSE=1 ./$(TARGET)

# Show help
.PHONY: run-help
run-help: $(TARGET)
	./$(TARGET) --help

# Clean compiled binaries
.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -f $(TARGET)
	@echo "Clean complete"

# Format Swift code
.PHONY: format
format:
	@echo "Formatting Swift code..."
	swift format --in-place $(SWIFT_FILES)
	@echo "Format complete"

# Help target
.PHONY: help
help:
	@echo "Camera Notifier Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  build        - Compile the camera notifier"
	@echo "  run          - Build and run the camera notifier"
	@echo "  run-verbose  - Run with verbose logging"
	@echo "  run-help     - Show application help"
	@echo "  clean        - Remove compiled binaries"
	@echo "  format       - Format Swift code using swift format"
	@echo "  help         - Show this help message"
	@echo ""
	@echo "Handler Configuration:"
	@echo "  Set CAMERA_HANDLERS to enable specific handlers (default: 'switchbot')"
	@echo "  Available handlers: switchbot"
	@echo ""
	@echo "SwitchBot Handler Environment Variables:"
	@echo "  SWITCHBOT_TOKEN      - Your SwitchBot API token (required)"
	@echo "  SWITCHBOT_SECRET     - Your SwitchBot API secret (required)"
	@echo "  SWITCHBOT_DEVICE_ID  - Target device ID (optional, auto-detects if not set)"
	@echo ""
	@echo "Example usage:"
	@echo "  export SWITCHBOT_TOKEN='your_token'"
	@echo "  export SWITCHBOT_SECRET='your_secret'"
	@echo "  make run"