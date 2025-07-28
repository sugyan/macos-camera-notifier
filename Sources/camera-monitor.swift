// Camera Monitor Library - Real-time camera usage detection for macOS
// Uses CoreMediaIO framework to monitor camera device status changes

import CoreMediaIO
import Foundation

// Camera state change information
public struct CameraStateChange {
  public let isRunning: Bool
  public let deviceName: String?

  public init(isRunning: Bool, deviceName: String?) {
    self.isRunning = isRunning
    self.deviceName = deviceName
  }
}

// Camera monitor errors
public enum CameraMonitorError: Error {
  case failedToGetDeviceListSize
  case failedToGetDeviceList
  case initializationFailed
}

// Camera monitoring class with callback support
public class CameraMonitor {
  private let deviceIDs: [CMIOObjectID]
  private var lastState: Bool? = false

  public typealias StateChangeCallback = (CameraStateChange) -> Void

  public init() throws {
    // Get system object ID for CoreMediaIO queries
    let systemObjectID = CMIOObjectID(kCMIOObjectSystemObject)
    var dataSize: UInt32 = 0

    // Configure property address for device list retrieval
    var deviceListAddress = CMIOObjectPropertyAddress(
      mSelector: UInt32(kCMIOHardwarePropertyDevices),
      mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
      mElement: UInt32(kCMIOObjectPropertyElementMain)
    )

    // Get the size of device list data
    guard
      CMIOObjectGetPropertyDataSize(systemObjectID, &deviceListAddress, 0, nil, &dataSize) == noErr
    else {
      throw CameraMonitorError.failedToGetDeviceListSize
    }

    // Calculate number of devices and prepare array to store device IDs
    let numberOfDevices = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
    var deviceIDs = [CMIOObjectID](repeating: 0, count: numberOfDevices)
    var dataUsed: UInt32 = 0

    // Retrieve the actual device ID list
    guard
      CMIOObjectGetPropertyData(
        systemObjectID, &deviceListAddress, 0, nil, dataSize, &dataUsed, &deviceIDs
      ) == noErr
    else {
      throw CameraMonitorError.failedToGetDeviceList
    }

    self.deviceIDs = deviceIDs
  }

  // Check if any camera device is currently running
  public func checkCameraState() -> CameraStateChange {
    for deviceID in deviceIDs {
      // Get device name
      var nameAddress = CMIOObjectPropertyAddress(
        mSelector: UInt32(kCMIOObjectPropertyName),
        mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
        mElement: UInt32(kCMIOObjectPropertyElementMain)
      )
      var deviceName: Unmanaged<CFString>?
      var nameUsed: UInt32 = 0
      let nameStatus = CMIOObjectGetPropertyData(
        deviceID, &nameAddress, 0, nil, UInt32(MemoryLayout<CFString?>.size), &nameUsed, &deviceName
      )
      let nameStr =
        (nameStatus == noErr && deviceName != nil)
        ? deviceName!.takeRetainedValue() as String
        : "(Name not available)"

      // Check if device is currently running
      var isRunningAddress = CMIOObjectPropertyAddress(
        mSelector: UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: UInt32(kCMIOObjectPropertyScopeGlobal),
        mElement: UInt32(kCMIOObjectPropertyElementMain)
      )
      var isRunning: UInt32 = 0
      var isRunningUsed: UInt32 = 0
      let isRunningStatus = CMIOObjectGetPropertyData(
        deviceID, &isRunningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size), &isRunningUsed,
        &isRunning
      )

      if isRunningStatus == noErr && isRunning != 0 {
        return CameraStateChange(isRunning: true, deviceName: nameStr)
      }
    }
    return CameraStateChange(isRunning: false, deviceName: nil)
  }

  // Monitor camera state changes and call callback on changes
  public func startMonitoring(interval: UInt32 = 1, onStateChange: @escaping StateChangeCallback) {
    logMessage("Camera monitoring loop started with \(deviceIDs.count) devices")

    while true {
      let currentState = checkCameraState()

      // Only call callback on state changes
      if lastState == nil || lastState != currentState.isRunning {
        logMessage(
          "Camera state changed: \(currentState.isRunning ? "ON" : "OFF") - Device: \(currentState.deviceName ?? "unknown")"
        )
        onStateChange(currentState)
        lastState = currentState.isRunning
      }

      sleep(interval)
    }
  }

  // Helper method for logging with forced flush
  private func logMessage(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    let logMsg = "[\(timestamp)] [CameraMonitor] \(message)"

    print(logMsg)
    fflush(stdout)
  }

  // Single check without monitoring loop - useful for polling from external loop
  public func checkForStateChange() -> CameraStateChange? {
    let currentState = checkCameraState()

    if lastState == nil || lastState != currentState.isRunning {
      lastState = currentState.isRunning
      return currentState
    }

    return nil
  }
}
