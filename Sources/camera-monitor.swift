// Camera Monitor Library - Real-time camera usage detection for macOS
// Uses CoreMediaIO to track camera devices and whether any of them is in use.
//
// The device list is NOT fixed at startup: a USB camera gets a new CMIOObjectID every time it is
// re-enumerated (unplug/replug, dock reconnect, sometimes after sleep), and Continuity Camera
// devices come and go. The monitor therefore combines CoreMediaIO property listeners (low latency)
// with a periodic rescan (safety net). All state is confined to a single serial dispatch queue.
//
// ON is reported as soon as a camera is in use. OFF is reported only once no camera has been in use
// for `offDelay`: apps often stop capturing for a moment (a meeting app going from its preview to
// the call, switching cameras), and that must not turn the light off and on again.

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

  private static let logTag = "CameraMonitor"
  private static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)
  private static let sleepLogThresholdNanos: UInt64 = 5_000_000_000

  private let queue: DispatchQueue
  private let pollInterval: TimeInterval
  private let offDelay: TimeInterval
  private var onStateChange: StateChangeCallback?
  // Device names by object ID
  private var devices: [CMIOObjectID: String] = [:]
  // Devices that have a running-state listener. Listeners are never removed: Swift bridges the
  // closure to a new block on every call, so CMIOObjectRemovePropertyListenerBlock cannot find the
  // registered one anyway. Object IDs are not reused (they keep increasing), so the listener of a
  // vanished device never fires again, and a device that drops out of the list and comes back
  // keeps its one listener.
  private var listenedDeviceIDs: Set<CMIOObjectID> = []
  private var timer: DispatchSourceTimer?
  private var deviceListAvailable = true
  // Nothing is reported before the device list has been read once: an unreadable list is not OFF
  private var hasDeviceList = false
  // nil until the first report, so the initial state is always reported (startup sync)
  private var lastState: Bool?
  private var lastRunningDeviceName: String?
  private var pendingOff: DispatchWorkItem?
  // Between "system will sleep" and wake, OFF is reported at once: the process may be suspended
  // before offDelay elapses
  private var sleepImminent = false
  private var lastTotalSleepNanos: UInt64?

  /// - Parameters:
  ///   - queue: Serial queue on which CoreMediaIO is queried and callbacks are delivered
  ///   - pollInterval: Interval of the periodic rescan that backs up the CoreMediaIO listeners
  ///   - offDelay: How long no camera must be in use before OFF is reported
  public init(
    queue: DispatchQueue = DispatchQueue(label: "camera-notifier.monitor"),
    pollInterval: TimeInterval = 1, offDelay: TimeInterval = 5
  ) {
    self.queue = queue
    self.pollInterval = pollInterval
    self.offDelay = offDelay
  }

  /// Start monitoring. The current state is reported once the device list has been read, then on
  /// every change. The callback is invoked on the monitor's queue.
  public func start(onStateChange: @escaping StateChangeCallback) {
    queue.async {
      self.onStateChange = onStateChange
      self.installDeviceListListener()
      self.refreshDevices()
      self.log(
        "Monitoring \(self.devices.count) camera device(s); rescanning every \(self.pollInterval)s, "
          + "reporting OFF after \(self.offDelay)s without camera use")
      self.evaluate()
      self.startTimer()
    }
  }

  /// Report an OFF that is still waiting for `offDelay` right away, e.g. before the process exits.
  /// Waits at most `timeout`. Must not be called on the monitor's queue.
  public func flushPendingOff(timeout: TimeInterval = 1) {
    runAndWait(timeout: timeout) {
      if self.pendingOff != nil {
        self.evaluate(offDelayElapsed: true)
      }
    }
  }

  /// The system is about to sleep: report a pending OFF now, and until `systemDidWake()` report
  /// OFF without waiting for `offDelay`. Waits at most `timeout`. Must not be called on the
  /// monitor's queue.
  public func systemWillSleep(timeout: TimeInterval = 1) {
    runAndWait(timeout: timeout) {
      self.sleepImminent = true
      if self.lastState == true {
        self.log("System is going to sleep")
      }
      self.evaluate()
    }
  }

  /// The system woke up, or the sleep was cancelled: OFF is reported after `offDelay` again.
  public func systemDidWake() {
    queue.async {
      self.sleepImminent = false
    }
  }

  private func runAndWait(timeout: TimeInterval, _ work: @escaping () -> Void) {
    dispatchPrecondition(condition: .notOnQueue(queue))
    let done = DispatchSemaphore(value: 0)
    queue.async {
      work()
      done.signal()
    }
    _ = done.wait(timeout: .now() + timeout)
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
    let status = CMIOObjectAddPropertyListenerBlock(Self.systemObject, &address, queue) {
      [weak self] _, _ in
      guard let self else { return }
      self.refreshDevices()
      self.evaluate()
    }
    if status != noErr {
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
    hasDeviceList = true

    let current = Set(ids)
    for (id, name) in devices where !current.contains(id) {
      devices[id] = nil
      log("Camera device removed: \(name) [id=\(id)]")
    }
    for id in ids where devices[id] == nil {
      let name = Self.stringProperty(id, kCMIOObjectPropertyName) ?? "(Name not available)"
      let uid = Self.stringProperty(id, kCMIODevicePropertyDeviceUID) ?? "unknown"
      devices[id] = name
      if !listenedDeviceIDs.contains(id), addRunningListener(id: id) {
        listenedDeviceIDs.insert(id)
      }
      log("Camera device added: \(name) [id=\(id) uid=\(uid)]")
    }
  }

  private func addRunningListener(id: CMIOObjectID) -> Bool {
    var address = Self.propertyAddress(kCMIODevicePropertyDeviceIsRunningSomewhere)
    let status = CMIOObjectAddPropertyListenerBlock(id, &address, queue) { [weak self] _, _ in
      self?.evaluate()
    }
    return status == noErr
  }

  // MARK: - State evaluation

  private func evaluate(offDelayElapsed: Bool = false) {
    guard hasDeviceList else { return }

    if let runningName = runningDeviceName() {
      lastRunningDeviceName = runningName
      cancelPendingOff()
      report(isRunning: true, deviceName: runningName)
    } else if offDelayElapsed || sleepImminent {
      cancelPendingOff()
      report(isRunning: false, deviceName: lastRunningDeviceName)
    } else if lastState != false {
      // Possibly just a short pause (an app restarting capture, a failed read): report OFF only if
      // it lasts. The initial state goes through this too, so a restart never flashes the light.
      scheduleOff()
    }
  }

  // A failed read counts as "not in use"; offDelay absorbs a transient failure
  private func runningDeviceName() -> String? {
    devices.keys.sorted()
      .first { Self.isRunningSomewhere($0) == true }
      .flatMap { devices[$0] }
  }

  private func report(isRunning: Bool, deviceName: String?) {
    guard isRunning != lastState else { return }
    lastState = isRunning
    log("Camera state changed: \(isRunning ? "ON" : "OFF") - Device: \(deviceName ?? "unknown")")
    onStateChange?(CameraStateChange(isRunning: isRunning, deviceName: deviceName))
  }

  private func scheduleOff() {
    guard pendingOff == nil else { return }
    let workItem = DispatchWorkItem { [weak self] in
      guard let self else { return }
      self.pendingOff = nil
      self.evaluate(offDelayElapsed: true)
    }
    pendingOff = workItem
    queue.asyncAfter(deadline: .now() + offDelay, execute: workItem)
  }

  private func cancelPendingOff() {
    pendingOff?.cancel()
    pendingOff = nil
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
