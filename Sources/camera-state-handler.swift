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
  private var handlers: [CameraStateHandler] = []

  public init() {}

  /// Register a new handler
  public func register(_ handler: CameraStateHandler) {
    handlers.append(handler)
  }

  /// Get all enabled handlers
  public var enabledHandlers: [CameraStateHandler] {
    return handlers.filter { $0.isEnabled }
  }

  /// Configure all registered handlers
  public func configureAll() throws {
    var configurationErrors: [Error] = []

    for handler in handlers {
      do {
        try handler.configure()
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
  public func handleCameraStateChange(_ change: CameraStateChange) {
    for handler in enabledHandlers {
      // Handle each handler asynchronously to prevent blocking
      DispatchQueue.global(qos: .utility).async {
        handler.handleCameraStateChange(change)
      }
    }
  }

  /// Cleanup all handlers
  public func cleanup() {
    for handler in handlers {
      handler.cleanup()
    }
    handlers.removeAll()
  }

  /// Get handler names for logging/debugging
  public var handlerNames: [String] {
    return handlers.map { $0.name }
  }

  /// Get enabled handler names for logging/debugging
  public var enabledHandlerNames: [String] {
    return enabledHandlers.map { $0.name }
  }
}

// Utility for logging with timestamps
public class HandlerLogger {
  public static func log(_ message: String, handler: String? = nil) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
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
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
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
