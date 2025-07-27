# Makefile for Camera Monitor
# macOS camera usage monitoring utility

# Variables
SWIFT_FILES = camera-monitor.swift
TARGET = camera-monitor
FRAMEWORK = -framework CoreMediaIO
SWIFT_FLAGS = -O

# Default target
.PHONY: all
all: build

# Build the camera monitor
.PHONY: build
build: $(TARGET)

$(TARGET): $(SWIFT_FILES)
	@echo "Building camera monitor..."
	swiftc $(FRAMEWORK) $(SWIFT_FLAGS) $(SWIFT_FILES) -o $(TARGET)
	@echo "Build complete: $(TARGET)"

# Run the camera monitor (builds if necessary)
.PHONY: run
run: $(TARGET)
	@echo "Starting camera monitor (Press Ctrl+C to stop)..."
	./$(TARGET)

# Clean compiled binaries
.PHONY: clean
clean:
	@echo "Cleaning up..."
	rm -f $(TARGET)
	@echo "Clean complete"

# Install to /usr/local/bin (optional)
.PHONY: install
install: $(TARGET)
	@echo "Installing camera-monitor to /usr/local/bin..."
	sudo cp $(TARGET) /usr/local/bin/
	sudo chmod +x /usr/local/bin/$(TARGET)
	@echo "Installation complete"

# Uninstall from /usr/local/bin
.PHONY: uninstall
uninstall:
	@echo "Removing camera-monitor from /usr/local/bin..."
	sudo rm -f /usr/local/bin/$(TARGET)
	@echo "Uninstall complete"

# Help target
.PHONY: help
help:
	@echo "Camera Monitor Makefile"
	@echo ""
	@echo "Available targets:"
	@echo "  build     - Compile the camera monitor"
	@echo "  run       - Build and run the camera monitor"
	@echo "  clean     - Remove compiled binaries"
	@echo "  install   - Install to /usr/local/bin (requires sudo)"
	@echo "  uninstall - Remove from /usr/local/bin (requires sudo)"
	@echo "  help      - Show this help message"