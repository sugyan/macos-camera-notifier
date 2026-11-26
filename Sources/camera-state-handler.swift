// Camera State Handler Protocol - Common interface for camera state integrations
// Supports various types of actions: notifications, state sync, triggers, etc.

import Foundation

// Protocol for handling camera state changes
public protocol CameraStateHandler {
  /// Human-readable name for this handler
  var name: String { get }

  /// Whether this handler is currently enabled and configured
  var isEnabled: Bool { get }

  /// Configure the handler with environment variables or other settings
  /// Throws an error if configuration is invalid or required settings are missing
  func configure() throws

  /// Handle a camera state change event
  /// Called on a serial queue dedicated to this handler, in the order the changes happened.
  /// This method should be non-blocking and handle errors gracefully
  func handleCameraStateChange(_ change: CameraStateChange)

  /// Optional cleanup when the handler is no longer needed
  func cleanup()
}

// Default implementations for optional methods
extension CameraStateHandler {
  public func cleanup() {
    // Default: no cleanup needed
  }
}

// Configuration errors
public enum HandlerConfigurationError: Error, LocalizedError {
  case missingRequiredEnvironmentVariable(String)
  case invalidConfiguration(String)
  case initializationFailed(String)

  public var errorDescription: String? {
    switch self {
    case .missingRequiredEnvironmentVariable(let variable):
      return "Missing required environment variable: \(variable)"
    case .invalidConfiguration(let message):
      return "Invalid configuration: \(message)"
    case .initializationFailed(let message):
      return "Initialization failed: \(message)"
    }
  }
}

// Registry for managing multiple camera state handlers
public class CameraStateHandlerRegistry {
  private struct Entry {
    let handler: CameraStateHandler
    let queue: DispatchQueue
  }

  private var entries: [Entry] = []

  public init() {}

  /// Register a new handler
  public func register(_ handler: CameraStateHandler) {
    let queue = DispatchQueue(label: "camera-notifier.handler.\(handler.name.lowercased())")
    entries.append(Entry(handler: handler, queue: queue))
  }

  /// Get all enabled handlers
  public var enabledHandlers: [CameraStateHandler] {
    return entries.map(\.handler).filter { $0.isEnabled }
  }

  /// Configure all registered handlers
  public func configureAll() throws {
    var configurationErrors: [Error] = []

    for entry in entries {
      do {
        try entry.handler.configure()
      } catch {
        configurationErrors.append(error)
      }
    }

    if !configurationErrors.isEmpty {
      // For now, just throw the first error
      // In the future, we could create a composite error
      throw configurationErrors.first!
    }
  }

  /// Dispatch camera state change to all enabled handlers
  /// Each handler has its own serial queue: a slow handler never blocks camera monitoring,
  /// and every handler receives the changes in the order they happened.
  public func handleCameraStateChange(_ change: CameraStateChange) {
    for entry in entries where entry.handler.isEnabled {
      entry.queue.async {
        entry.handler.handleCameraStateChange(change)
      }
    }
  }

  /// Cleanup all handlers
  public func cleanup() {
    for entry in entries {
      entry.handler.cleanup()
    }
    entries.removeAll()
  }

  /// Get handler names for logging/debugging
  public var handlerNames: [String] {
    return entries.map { $0.handler.name }
  }

  /// Get enabled handler names for logging/debugging
  public var enabledHandlerNames: [String] {
    return enabledHandlers.map { $0.name }
  }
}

// Utility for logging with timestamps
public class HandlerLogger {
  // DateFormatter is thread-safe for formatting; create it once instead of per message
  private static let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return formatter
  }()

  public static func log(_ message: String, handler: String? = nil) {
    let timestamp = formatter.string(from: Date())

    let logMessage: String
    if let handler = handler {
      logMessage = "[\(timestamp)] [\(handler)] \(message)"
    } else {
      logMessage = "[\(timestamp)] \(message)"
    }

    // Force output to stdout and flush immediately for launchd compatibility
    print(logMessage)
    fflush(stdout)
  }

  // Error logging to stderr
  public static func logError(_ message: String, handler: String? = nil) {
    let timestamp = formatter.string(from: Date())

    let logMessage: String
    if let handler = handler {
      logMessage = "[\(timestamp)] [ERROR] [\(handler)] \(message)"
    } else {
      logMessage = "[\(timestamp)] [ERROR] \(message)"
    }

    // Output to stderr for error messages
    fputs(logMessage + "\n", stderr)
    fflush(stderr)
  }
}
