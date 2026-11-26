// Camera Notifier - Lightweight entry point for camera monitoring with extensible handlers
// Manages camera monitoring and dispatches state changes to configured handlers

import ArgumentParser
import Foundation

// Main application configuration
struct AppConfig {
  let enabledHandlers: Set<String>
  let verboseLogging: Bool

  init(handlers: String? = nil, verbose: Bool = false) {
    // Parse enabled handlers from parameter or environment variable
    let handlersEnv =
      handlers ?? ProcessInfo.processInfo.environment["CAMERA_HANDLERS"] ?? "switchbot"
    self.enabledHandlers = Set(
      handlersEnv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    )

    // Enable verbose logging if requested
    self.verboseLogging = verbose || ProcessInfo.processInfo.environment["VERBOSE"] == "1"
  }
}

// Main application class
class CameraNotifierApp {
  private let config: AppConfig
  private let handlerRegistry: CameraStateHandlerRegistry
  private let cameraMonitor = CameraMonitor()
  private var signalSources: [DispatchSourceSignal] = []

  init(config: AppConfig) {
    self.config = config
    self.handlerRegistry = CameraStateHandlerRegistry()

    registerAvailableHandlers()
  }

  // Handle SIGINT/SIGTERM on the main queue rather than in a C signal handler, where only
  // async-signal-safe functions may be called. Installed once startup is done; until then the
  // default action (terminate immediately) applies.
  private func setupSignalHandlers() {
    for (signalNumber, description) in [(SIGINT, "interrupt"), (SIGTERM, "termination")] {
      signal(signalNumber, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
      source.setEventHandler { [weak self] in
        HandlerLogger.log("Received \(description) signal, shutting down...")
        self?.handlerRegistry.cleanup()
        exit(0)
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func registerAvailableHandlers() {
    // Register SwitchBot handler if enabled
    if config.enabledHandlers.contains("switchbot") {
      handlerRegistry.register(SwitchBotSyncHandler())
    }

    // Log-only handler, useful to check camera detection without side effects
    if config.enabledHandlers.contains("log") {
      handlerRegistry.register(LogHandler())
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
    HandlerLogger.log("Process ID: \(ProcessInfo.processInfo.processIdentifier)")
    HandlerLogger.log("Working directory: \(FileManager.default.currentDirectoryPath)")

    // Display configuration
    HandlerLogger.log("Enabled handlers: \(config.enabledHandlers.joined(separator: ", "))")
    HandlerLogger.log("Verbose logging: \(config.verboseLogging)")
    HandlerLogger.log(
      "Registered handlers: \(handlerRegistry.handlerNames.joined(separator: ", "))")

    // Log environment variables for debugging
    if config.verboseLogging {
      HandlerLogger.log("Environment check:")
      HandlerLogger.log(
        "  SWITCHBOT_TOKEN: \(ProcessInfo.processInfo.environment["SWITCHBOT_TOKEN"] != nil ? "set" : "not set")"
      )
      HandlerLogger.log(
        "  SWITCHBOT_SECRET: \(ProcessInfo.processInfo.environment["SWITCHBOT_SECRET"] != nil ? "set" : "not set")"
      )
      HandlerLogger.log(
        "  SWITCHBOT_DEVICE_ID: \(ProcessInfo.processInfo.environment["SWITCHBOT_DEVICE_ID"] ?? "not set")"
      )
    }

    // Configure all handlers
    do {
      try handlerRegistry.configureAll()
    } catch {
      HandlerLogger.logError("Handler configuration failed: \(error)")
      showConfigurationHelp()
      exit(1)
    }

    let enabledHandlers = handlerRegistry.enabledHandlerNames
    if enabledHandlers.isEmpty {
      HandlerLogger.logError("No handlers are enabled and configured")
      showConfigurationHelp()
      exit(1)
    }

    HandlerLogger.log("Active handlers: \(enabledHandlers.joined(separator: ", "))")

    setupSignalHandlers()

    // Start monitoring with handler dispatch
    cameraMonitor.start { [handlerRegistry] change in
      handlerRegistry.handleCameraStateChange(change)
    }

    HandlerLogger.log("Camera monitoring started. Press Ctrl+C to stop.")

    // Everything from here on is event driven (CoreMediaIO listeners, timers, signals, network
    // callbacks), so the main thread must not block: run the main run loop forever.
    RunLoop.main.run()
  }

  private func showConfigurationHelp() {
    fputs(
      """

      Configuration Help:

      Environment Variables:
      - CAMERA_HANDLERS: Comma-separated list of handlers to enable (default: "switchbot")
        Available handlers: switchbot, log (log only prints camera state changes)
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

      """, stderr)
    fflush(stderr)
  }
}

// Application entry point with ArgumentParser
@main
struct CameraNotifier: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "camera-notifier",
    abstract: "macOS camera monitoring with extensible handlers",
    version: "1.1.0"
  )

  @Option(
    name: .long,
    help: "Comma-separated list of handlers to enable: switchbot, log (default: switchbot)")
  var handlers: String?

  @Flag(name: .shortAndLong, help: "Enable verbose logging")
  var verbose: Bool = false

  mutating func run() throws {
    let config = AppConfig(handlers: handlers, verbose: verbose)
    let app = CameraNotifierApp(config: config)
    app.run()
  }
}
