// System Power Observer - Lets the notifier act right before the Mac goes to sleep
// Uses IOKit's IORegisterForSystemPower (Technical Q&A QA1340). Every sleep message must be
// acknowledged with IOAllowPowerChange, otherwise the system waits up to 30 s before sleeping.

import Foundation
import IOKit
import IOKit.pwr_mgt

final class SystemPowerObserver {
  // IOKit/IOMessage.h defines these with the iokit_common_msg() macro, which Swift cannot import:
  // iokit_common_msg(m) = err_system(0x38) | err_sub(0) | m = 0xE0000000 | m
  private static let canSystemSleep: UInt32 = 0xE000_0270
  private static let systemWillSleep: UInt32 = 0xE000_0280
  private static let systemWillNotSleep: UInt32 = 0xE000_0290
  private static let systemHasPoweredOn: UInt32 = 0xE000_0300

  private let queue: DispatchQueue
  private let willSleep: () -> Void
  private let didWake: () -> Void
  private var rootPort: io_connect_t = 0
  private var notifier: io_object_t = 0
  private var notificationPort: IONotificationPortRef?

  /// - Parameters:
  ///   - queue: Queue on which the callbacks run
  ///   - willSleep: Called before the system sleeps; sleep waits until it returns, so keep it short
  ///   - didWake: Called after wake, or when a sleep was cancelled
  init(queue: DispatchQueue, willSleep: @escaping () -> Void, didWake: @escaping () -> Void) {
    self.queue = queue
    self.willSleep = willSleep
    self.didWake = didWake
  }

  /// Start observing. The observer must be kept alive for as long as it observes.
  func start() -> Bool {
    let refcon = Unmanaged.passUnretained(self).toOpaque()
    rootPort = IORegisterForSystemPower(
      refcon, &notificationPort,
      { refcon, _, messageType, messageArgument in
        guard let refcon else { return }
        Unmanaged<SystemPowerObserver>.fromOpaque(refcon).takeUnretainedValue()
          .handle(messageType: messageType, argument: messageArgument)
      }, &notifier)
    guard rootPort != 0, let notificationPort else { return false }
    IONotificationPortSetDispatchQueue(notificationPort, queue)
    return true
  }

  private func handle(messageType: UInt32, argument: UnsafeMutableRawPointer?) {
    switch messageType {
    case Self.canSystemSleep:
      // Idle sleep is about to start: never object to it
      IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case Self.systemWillSleep:
      willSleep()
      IOAllowPowerChange(rootPort, Int(bitPattern: argument))
    case Self.systemWillNotSleep, Self.systemHasPoweredOn:
      didWake()
    default:
      break
    }
  }
}
