// Camera Monitor Library - Real-time camera usage detection for macOS
// Uses CoreMediaIO to track camera devices and whether any of them is in use.
//
// The device list is NOT fixed at startup: a USB camera gets a new CMIOObjectID every time it is
// re-enumerated (unplug/replug, dock reconnect, sometimes after sleep), and Continuity Camera
// devices come and go. The monitor therefore combines CoreMediaIO property listeners (low latency)
// with a periodic rescan (safety net). All state is confined to a single serial dispatch queue.

import CoreMediaIO
import Foundation

// Camera state change information
public struct CameraStateChange {
  public let isRunning: Bool
  /// The device in use (ON), or the device that was in use until now (OFF)
  public let deviceName: String?

  public init(isRunning: Bool, deviceName: String?) {
    self.isRunning = isRunning
    self.deviceName = deviceName
  }
}

// Camera monitoring class with callback support
public final class CameraMonitor {
  public typealias StateChangeCallback = (CameraStateChange) -> Void

  private struct Device {
    let name: String
    let uid: String
    let runningListener: CMIOObjectPropertyListenerBlock?
  }

  private static let logTag = "CameraMonitor"
  private static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
  private static let sleepLogThresholdNanos: UInt64 = 5_000_000_000

  private let queue: DispatchQueue
  private let pollInterval: TimeInterval
  private var onStateChange: StateChangeCallback?
  private var devices: [CMIOObjectID: Device] = [:]
  private var deviceListListener: CMIOObjectPropertyListenerBlock?
  private var timer: DispatchSourceTimer?
  private var deviceListAvailable = true
  // nil until the first evaluation, so the initial state is always reported (startup sync)
  private var lastState: Bool?
  private var lastRunningDeviceName: String?
  private var lastTotalSleepNanos: UInt64?

  /// - Parameters:
  ///   - queue: Serial queue on which CoreMediaIO is queried and callbacks are delivered
  ///   - pollInterval: Interval of the periodic rescan that backs up the CoreMediaIO listeners
  public init(queue: DispatchQueue = .main, pollInterval: TimeInterval = 1) {
    self.queue = queue
    self.pollInterval = pollInterval
  }

  /// Start monitoring. The current state is reported once right away, then on every change.
  /// The callback is invoked on the monitor's queue.
  public func start(onStateChange: @escaping StateChangeCallback) {
    queue.async {
      self.onStateChange = onStateChange
      self.installDeviceListListener()
      self.refreshDevices()
      self.log(
        "Monitoring \(self.devices.count) camera device(s); rescanning every \(self.pollInterval)s"
      )
      self.evaluate()
      self.startTimer()
    }
  }

  // MARK: - Periodic rescan

  private func startTimer() {
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(
      deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(100))
    timer.setEventHandler { [weak self] in
      self?.tick()
    }
    timer.resume()
    self.timer = timer
  }

  private func tick() {
    logIfResumedFromSleep()
    refreshDevices()
    evaluate()
  }

  // CLOCK_MONOTONIC_RAW keeps counting while the system is asleep and CLOCK_UPTIME_RAW does not,
  // so their difference is the total time spent asleep since boot.
  private func logIfResumedFromSleep() {
    let uptime = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
    let monotonic = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    let totalSleep = monotonic &- uptime
    defer { lastTotalSleepNanos = totalSleep }

    guard let last = lastTotalSleepNanos, totalSleep > last,
      totalSleep - last > Self.sleepLogThresholdNanos
    else { return }
    let slept = Self.formatDuration(seconds: (totalSleep - last) / 1_000_000_000)
    log("Resumed after system sleep (slept ~\(slept)), rescanning camera devices")
  }

  // MARK: - Device tracking

  private func installDeviceListListener() {
    var address = Self.propertyAddress(kCMIOHardwarePropertyDevices)
    let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
      guard let self else { return }
      self.refreshDevices()
      self.evaluate()
    }
    let status = CMIOObjectAddPropertyListenerBlock(Self.systemObject, &address, queue, listener)
    if status == noErr {
      deviceListListener = listener
    } else {
      log("Could not register device list listener (OSStatus \(status)), relying on rescan only")
    }
  }

  private func refreshDevices() {
    guard let ids = Self.fetchDeviceIDs() else {
      if deviceListAvailable {
        deviceListAvailable = false
        log("Failed to get camera device list, will keep retrying")
      }
      return
    }
    if !deviceListAvailable {
      deviceListAvailable = true
      log("Camera device list is available again")
    }

    let current = Set(ids)
    for (id, device) in devices where !current.contains(id) {
      removeRunningListener(id: id, listener: device.runningListener)
      devices[id] = nil
      log("Camera device removed: \(device.name) [id=\(id)]")
    }
    for id in ids where devices[id] == nil {
      let name = Self.stringProperty(id, kCMIOObjectPropertyName) ?? "(Name not available)"
      let uid = Self.stringProperty(id, kCMIODevicePropertyDeviceUID) ?? "unknown"
      devices[id] = Device(name: name, uid: uid, runningListener: addRunningListener(id: id))
      log("Camera device added: \(name) [id=\(id) uid=\(uid)]")
    }
  }

  private func addRunningListener(id: CMIOObjectID) -> CMIOObjectPropertyListenerBlock? {
    var address = Self.propertyAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
    let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
      self?.evaluate()
    }
    let status = CMIOObjectAddPropertyListenerBlock(id, &address, queue, listener)
    return status == noErr ? listener : nil
  }

  private func removeRunningListener(id: CMIOObjectID, listener: CMIOObjectPropertyListenerBlock?) {
    guard let listener else { return }
    var address = Self.propertyAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
    // Fails harmlessly when the device object is already gone
    _ = CMIOObjectRemovePropertyListenerBlock(id, &address, queue, listener)
  }

  // MARK: - State evaluation

  private func evaluate() {
    let runningName = devices.keys.sorted()
      .first { Self.isRunningSomewhere($0) == true }
      .flatMap { devices[$0]?.name }
    let isRunning = runningName != nil
    defer {
      if let runningName { lastRunningDeviceName = runningName }
    }

    guard isRunning != lastState else { return }
    lastState = isRunning
    let deviceName = isRunning ? runningName : lastRunningDeviceName
    log("Camera state changed: \(isRunning ? "ON" : "OFF") - Device: \(deviceName ?? "unknown")")
    onStateChange?(CameraStateChange(isRunning: isRunning, deviceName: deviceName))
  }

  // MARK: - CoreMediaIO helpers

  private static func propertyAddress<T: BinaryInteger>(_ selector: T) -> CMIOObjectPropertyAddress
  {
    CMIOObjectPropertyAddress(
      mSelector: CMIOObjectPropertySelector(selector),
      mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
      mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
    )
  }

  private static func fetchDeviceIDs() -> [CMIOObjectID]? {
    var address = propertyAddress(kCMIOHardwarePropertyDevices)
    var dataSize: UInt32 = 0
    guard CMIOObjectGetPropertyDataSize(systemObject, &address, 0, nil, &dataSize) == noErr else {
      return nil
    }

    let capacity = Int(dataSize) / MemoryLayout<CMIOObjectID>.size
    guard capacity > 0 else { return [] }
    var ids = [CMIOObjectID](repeating: 0, count: capacity)
    var dataUsed: UInt32 = 0
    guard
      CMIOObjectGetPropertyData(systemObject, &address, 0, nil, dataSize, &dataUsed, &ids) == noErr
    else {
      return nil
    }
    return Array(ids.prefix(Int(dataUsed) / MemoryLayout<CMIOObjectID>.size))
  }

  private static func stringProperty<T: BinaryInteger>(_ id: CMIOObjectID, _ selector: T)
    -> String?
  {
    var address = propertyAddress(selector)
    var value: Unmanaged<CFString>?
    var dataUsed: UInt32 = 0
    let status = CMIOObjectGetPropertyData(
      id, &address, 0, nil, UInt32(MemoryLayout<Unmanaged<CFString>?>.size), &dataUsed, &value)
    guard status == noErr, let value else { return nil }
    // CMIO string properties follow the copy rule: the caller owns the returned CFString
    return value.takeRetainedValue() as String
  }

  private static func isRunningSomewhere(_ id: CMIOObjectID) -> Bool? {
    var address = propertyAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
    var value: UInt32 = 0
    var dataUsed: UInt32 = 0
    let status = CMIOObjectGetPropertyData(
      id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &dataUsed, &value)
    return status == noErr ? value != 0 : nil
  }

  private static func formatDuration(seconds: UInt64) -> String {
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    if hours > 0 { return "\(hours)h\(minutes)m" }
    if minutes > 0 { return "\(minutes)m\(seconds % 60)s" }
    return "\(seconds)s"
  }

  private func log(_ message: String) {
    HandlerLogger.log(message, handler: Self.logTag)
  }
}
