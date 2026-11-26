// Log Handler - Logs camera state changes without any side effects
// Useful to check camera detection without touching any device: --handlers log

import Foundation

public class LogHandler: CameraStateHandler {
  public let name = "Log"

  public var isEnabled: Bool { true }

  public init() {}

  public func configure() throws {
    // Nothing to configure
  }

  public func handleCameraStateChange(_ change: CameraStateChange) {
    HandlerLogger.log(
      "Camera \(change.isRunning ? "ON" : "OFF"): \(change.deviceName ?? "unknown device")",
      handler: name)
  }
}
