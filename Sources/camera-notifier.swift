// Camera Notifier - Lightweight entry point for camera monitoring with extensible handlers
// Manages camera monitoring and dispatches state changes to configured handlers

import ArgumentParser
import Foundation

// Main application configuration
struct AppConfig {
  static let defaultOffDelay: TimeInterval = 5

  let enabledHandlers: Set<String>
  let verboseLogging: Bool
  let offDelay: TimeInterval

  init(handlers: String? = nil, verbose: Bool = false, offDelay: TimeInterval? = nil) {
    // Parse enabled handlers from parameter or environment variable
    let handlersEnv =
      handlers ?? ProcessInfo.processInfo.environment["CAMERA_HANDLERS"] ?? "switchbot"
    self.enabledHandlers = Set(
      handlersEnv.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    )

    // Enable verbose logging if requested
    self.verboseLogging = verbose || ProcessInfo.processInfo.environment["VERBOSE"] == "1"

    // Seconds without camera use before OFF is reported; invalid values fall back to the default
    let offDelayEnv = ProcessInfo.processInfo.environment["CAMERA_OFF_DELAY"].flatMap(Double.init)
    let requestedOffDelay = offDelay ?? offDelayEnv ?? Self.defaultOffDelay
    self.offDelay =
      requestedOffDelay.isFinite && requestedOffDelay >= 0
      ? requestedOffDelay : Self.defaultOffDelay
  }
}

// Main application class
class CameraNotifierApp {
  private let config: AppConfig
  private let handlerRegistry: CameraStateHandlerRegistry
  private let cameraMonitor: CameraMonitor
  private var signalSources: [DispatchSourceSignal] = []
  private var powerObserver: SystemPowerObserver?

  init(config: AppConfig) {
    self.config = config
    self.handlerRegistry = CameraStateHandlerRegistry()
    // The monitor runs on its own queue: the main thread only handles signals, so Ctrl+C and
    // SIGTERM keep working even if a CoreMediaIO call hangs
    self.cameraMonitor = CameraMonitor(offDelay: config.offDelay)

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
        self?.shutdown()
      }
      source.resume()
      signalSources.append(source)
    }
  }

  private func shutdown() {
    // An OFF still waiting for the off delay would otherwise be lost (e.g. at logout); the
    // handlers then get a few seconds to deliver it
    cameraMonitor.flushPendingOff()
    handlerRegistry.cleanup()
    exit(0)
  }

  // Right before the system sleeps, send an OFF that is still waiting for the off delay: the
  // process is suspended during sleep. Sleep waits for this, so it is bounded to a few seconds.
  private func startPowerObserver() {
    let observer = SystemPowerObserver(
      queue: DispatchQueue(label: "camera-notifier.power"),
      willSleep: { [cameraMonitor, handlerRegistry] in
        cameraMonitor.systemWillSleep()
        handlerRegistry.flush(timeout: 3)
      },
      didWake: { [cameraMonitor] in
        cameraMonitor.systemDidWake()
      })
    if observer.start() {
      powerObserver = observer
    } else {
      HandlerLogger.log(
        "Could not register for sleep notifications; an OFF right before sleep may be sent after wake"
      )
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
    HandlerLogger.log("Off delay: \(config.offDelay)s")
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
    startPowerObserver()

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
      - CAMERA_OFF_DELAY: Seconds without camera use before OFF is reported (default: 5)

      SwitchBot Handler:
      - SWITCHBOT_TOKEN: Your SwitchBot API token (required)
      - SWITCHBOT_SECRET: Your SwitchBot API secret (required)
      - SWITCHBOT_DEVICE_ID: Target device ID (optional, auto-detects if not set)

      Example:
      export CAMERA_HANDLERS="switchbot"
      export SWITCHBOT_TOKEN="your_token_here"
      export SWITCHBOT_SECRET="your_secret_here"
      ./.build/release/camera-notifier

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

  @Option(
    name: .long,
    help: "Seconds without camera use before OFF is reported (default: 5, env: CAMERA_OFF_DELAY)")
  var offDelay: Double?

  mutating func validate() throws {
    if let offDelay, !(offDelay.isFinite && offDelay >= 0) {
      throw ValidationError("--off-delay must be a non-negative number of seconds")
    }
  }

  mutating func run() throws {
    let config = AppConfig(handlers: handlers, verbose: verbose, offDelay: offDelay)
    let app = CameraNotifierApp(config: config)
    app.run()
  }
}
