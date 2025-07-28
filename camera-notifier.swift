// Camera Notifier - Lightweight entry point for camera monitoring with extensible handlers
// Manages camera monitoring and dispatches state changes to configured handlers

import CoreMediaIO
import Foundation

// Main application configuration
struct AppConfig {
  let enabledHandlers: Set<String>
  let verboseLogging: Bool

  init() {
    // Parse enabled handlers from environment variable
    let handlersEnv = ProcessInfo.processInfo.environment["CAMERA_HANDLERS"] ?? "switchbot"
    self.enabledHandlers = Set(
      handlersEnv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    )

    // Enable verbose logging if requested
    self.verboseLogging = ProcessInfo.processInfo.environment["VERBOSE"] == "1"
  }
}

// Main application class
class CameraNotifierApp {
  private let config: AppConfig
  private let handlerRegistry: CameraStateHandlerRegistry
  private var cameraMonitor: CameraMonitor?

  init() {
    self.config = AppConfig()
    self.handlerRegistry = CameraStateHandlerRegistry()

    setupSignalHandlers()
    registerAvailableHandlers()
  }

  private func setupSignalHandlers() {
    // Handle Ctrl+C gracefully
    signal(SIGINT) { _ in
      HandlerLogger.log("Received interrupt signal, shutting down...")
      exit(0)
    }

    signal(SIGTERM) { _ in
      HandlerLogger.log("Received termination signal, shutting down...")
      exit(0)
    }
  }

  private func registerAvailableHandlers() {
    // Register SwitchBot handler if enabled
    if config.enabledHandlers.contains("switchbot") {
      handlerRegistry.register(SwitchBotSyncHandler())
    }

    // Future handlers can be added here:
    // if config.enabledHandlers.contains("slack") {
    //     handlerRegistry.register(SlackNotificationHandler())
    // }
    // if config.enabledHandlers.contains("webhook") {
    //     handlerRegistry.register(WebhookTriggerHandler())
    // }
  }

  func run() {
    HandlerLogger.log("Camera Notifier starting...")

    // Display configuration
    if config.verboseLogging {
      HandlerLogger.log("Enabled handlers: \(config.enabledHandlers.joined(separator: ", "))")
      HandlerLogger.log(
        "Registered handlers: \(handlerRegistry.handlerNames.joined(separator: ", "))")
    }

    // Configure all handlers
    do {
      try handlerRegistry.configureAll()
    } catch {
      HandlerLogger.log("Handler configuration failed: \(error)")
      showConfigurationHelp()
      exit(1)
    }

    let enabledHandlers = handlerRegistry.enabledHandlerNames
    if enabledHandlers.isEmpty {
      HandlerLogger.log("No handlers are enabled and configured")
      showConfigurationHelp()
      exit(1)
    }

    HandlerLogger.log("Active handlers: \(enabledHandlers.joined(separator: ", "))")

    // Initialize camera monitor
    do {
      cameraMonitor = try CameraMonitor()
    } catch {
      HandlerLogger.log("Failed to initialize camera monitor: \(error)")
      exit(1)
    }

    HandlerLogger.log("Camera monitoring started. Press Ctrl+C to stop.")

    // Start monitoring with handler dispatch
    cameraMonitor?.startMonitoring { [weak self] change in
      self?.handlerRegistry.handleCameraStateChange(change)
    }
  }

  private func showConfigurationHelp() {
    print(
      """

      Configuration Help:

      Environment Variables:
      - CAMERA_HANDLERS: Comma-separated list of handlers to enable (default: "switchbot")
      - VERBOSE: Set to "1" for verbose logging

      SwitchBot Handler:
      - SWITCHBOT_TOKEN: Your SwitchBot API token (required)
      - SWITCHBOT_SECRET: Your SwitchBot API secret (required)  
      - SWITCHBOT_DEVICE_ID: Target device ID (optional, auto-detects if not set)

      Example:
      export CAMERA_HANDLERS="switchbot"
      export SWITCHBOT_TOKEN="your_token_here"
      export SWITCHBOT_SECRET="your_secret_here"
      ./camera-notifier

      """)
  }

  deinit {
    handlerRegistry.cleanup()
  }
}

// Application entry point
@main
struct CameraNotifierMain {
  static func main() {
    // Handle command line arguments
    let arguments = CommandLine.arguments

    if arguments.contains("--help") || arguments.contains("-h") {
      showHelp()
      exit(0)
    }

    if arguments.contains("--version") || arguments.contains("-v") {
      showVersion()
      exit(0)
    }

    // Create and run the application
    let app = CameraNotifierApp()
    app.run()
  }

  private static func showHelp() {
    print(
      """
      Camera Notifier - macOS camera monitoring with extensible handlers

      USAGE:
          camera-notifier [OPTIONS]

      OPTIONS:
          -h, --help      Show this help message
          -v, --version   Show version information

      ENVIRONMENT VARIABLES:
          CAMERA_HANDLERS     Comma-separated list of handlers (default: "switchbot")
          VERBOSE            Set to "1" for verbose logging
          
          SwitchBot Handler:
          SWITCHBOT_TOKEN    Your SwitchBot API token (required)
          SWITCHBOT_SECRET   Your SwitchBot API secret (required)
          SWITCHBOT_DEVICE_ID Target device ID (optional)

      EXAMPLES:
          # Basic usage with SwitchBot
          export SWITCHBOT_TOKEN="your_token"
          export SWITCHBOT_SECRET="your_secret"
          camera-notifier
          
          # Verbose logging
          export VERBOSE=1
          camera-notifier
          
          # Multiple handlers (when available)
          export CAMERA_HANDLERS="switchbot,slack"
          camera-notifier

      For more information, see the README.md file.
      """)
  }

  private static func showVersion() {
    print("Camera Notifier v1.0.0")
    print("macOS camera monitoring utility with extensible handlers")
  }
}
