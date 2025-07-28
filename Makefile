# Makefile for Camera Notifier
# macOS camera monitoring with extensible handler system

# Default target
.PHONY: all
all: build

# Build the camera notifier using Swift Package Manager
.PHONY: build
build:
	swift build -c release

# Run the camera notifier (builds if necessary)
.PHONY: run
run: build
	@echo "Starting camera notifier (Press Ctrl+C to stop)..."
	@echo "Make sure to set required environment variables for your handlers"
	./.build/release/camera-notifier

# Clean compiled binaries
.PHONY: clean
clean:
	swift package clean

# Format Swift code
.PHONY: format
format:
	swift format --in-place Sources/*.swift

# Help target
.PHONY: help
help:
	@echo "Camera Notifier Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  build   - Compile with Swift Package Manager"
	@echo "  run     - Build and run the camera notifier"
	@echo "  clean   - Remove compiled binaries"
	@echo "  format  - Format Swift code"
	@echo "  help    - Show this help message"
	@echo ""
	@echo "Direct usage:"
	@echo "  ./.build/release/camera-notifier --help    # Show app help"
	@echo "  ./.build/release/camera-notifier --verbose # Run with verbose logging"