// SwitchBot Sync Handler - Camera state synchronization with SwitchBot devices
// Automatically turns SwitchBot Plug devices ON/OFF based on camera state

import CryptoKit
import Foundation

// SwitchBot state synchronization handler
public class SwitchBotSyncHandler: CameraStateHandler {
  public let name = "SwitchBot"

  private static let maxAttempts = 8
  private static let maxRetryDelay: TimeInterval = 60
  // How long to wait for the last command at shutdown (launchd sends SIGKILL after 20 s)
  private static let shutdownTimeout: TimeInterval = 5

  private var client: SwitchBotClient?
  private var targetDeviceId: String?

  // Command delivery state, confined to `queue`
  private let queue = DispatchQueue(label: "camera-notifier.switchbot.delivery")
  private var desired: PlugCommand?
  private var hasPending = false
  private var inFlight = false
  private var attempt = 0
  private var retryWorkItem: DispatchWorkItem?
  private var shuttingDown = false
  private var idleWaiters: [DispatchSemaphore] = []

  public var isEnabled: Bool {
    return client != nil && targetDeviceId != nil
  }

  public init() {}

  public func configure() throws {
    // Get configuration from environment variables
    guard let token = ProcessInfo.processInfo.environment["SWITCHBOT_TOKEN"],
      token != "YOUR_TOKEN_HERE",
      !token.isEmpty
    else {
      throw HandlerConfigurationError.missingRequiredEnvironmentVariable("SWITCHBOT_TOKEN")
    }

    guard let secret = ProcessInfo.processInfo.environment["SWITCHBOT_SECRET"],
      secret != "YOUR_SECRET_HERE",
      !secret.isEmpty
    else {
      throw HandlerConfigurationError.missingRequiredEnvironmentVariable("SWITCHBOT_SECRET")
    }

    self.client = SwitchBotClient(token: token, secret: secret)

    // Device ID is optional - will auto-detect if not provided or empty
    let deviceIdEnv = ProcessInfo.processInfo.environment["SWITCHBOT_DEVICE_ID"]
    self.targetDeviceId = (deviceIdEnv?.isEmpty == false) ? deviceIdEnv : nil

    if targetDeviceId == nil {
      // Auto-detect device if not specified or empty
      HandlerLogger.log("No device ID specified, attempting auto-detection...", handler: name)
      try autoDetectDevice()
    } else {
      HandlerLogger.log("Using specified device: \(targetDeviceId!)", handler: name)
    }
  }

  private func autoDetectDevice() throws {
    guard let client = client else {
      throw HandlerConfigurationError.initializationFailed("SwitchBot client not initialized")
    }

    let semaphore = DispatchSemaphore(value: 0)
    var detectedDeviceId: String?
    var detectionError: Error?

    client.getDevices { result in
      defer { semaphore.signal() }

      switch result {
      case .success(let deviceResponse):
        let plugs = deviceResponse.body.deviceList.filter {
          $0.deviceType?.contains("Plug") == true
        }

        if plugs.isEmpty {
          detectionError = HandlerConfigurationError.invalidConfiguration("No Plug devices found")
        } else {
          detectedDeviceId = plugs.first?.deviceId
          HandlerLogger.log(
            "Auto-detected device: \(plugs.first?.deviceName ?? "Unknown") (\(detectedDeviceId!))",
            handler: self.name)
        }

      case .failure(let error):
        detectionError = HandlerConfigurationError.initializationFailed(
          "Failed to get device list: \(Self.describe(error))")
      }
    }

    semaphore.wait()

    if let error = detectionError {
      throw error
    }

    self.targetDeviceId = detectedDeviceId
  }

  public func handleCameraStateChange(_ change: CameraStateChange) {
    let command: PlugCommand = change.isRunning ? .turnOn : .turnOff
    let action = change.isRunning ? "started" : "stopped"
    let deviceName = change.deviceName ?? "Unknown device"

    HandlerLogger.log(
      "Camera \(action): \(deviceName), sending \(command.rawValue) command", handler: name)

    queue.async {
      self.request(command)
    }
  }

  public func flush(timeout: TimeInterval) {
    deliverNow(timeout: timeout, beforeExit: false)
  }

  public func cleanup() {
    deliverNow(timeout: Self.shutdownTimeout, beforeExit: true)
  }

  // Send a command that is waiting for its retry right away, then wait (at most `timeout`) until
  // nothing is in flight. Before exit, failures are not retried any more.
  private func deliverNow(timeout: TimeInterval, beforeExit: Bool) {
    let idle = DispatchSemaphore(value: 0)
    queue.async {
      if beforeExit {
        self.shuttingDown = true
      }
      if let retryWorkItem = self.retryWorkItem {
        retryWorkItem.cancel()
        self.retryWorkItem = nil
        self.hasPending = true
      }
      if !self.inFlight {
        self.sendPending()
      }
      self.idleWaiters.append(idle)
      self.signalIdleWaiters()
    }
    if idle.wait(timeout: .now() + timeout) == .timedOut {
      HandlerLogger.log(
        "Command still in flight after \(Int(timeout))s, not waiting any longer", handler: name)
    }
  }

  // MARK: - Command delivery (runs on `queue`)
  //
  // Only one request is in flight at a time, and if the camera state changes meanwhile, only the
  // latest state is sent afterwards. Failed requests are retried with exponential backoff until
  // they succeed, the attempts run out, or a newer state supersedes them. (A request that timed out
  // may still be carried out by the SwitchBot cloud later, after a newer command; that rare case is
  // corrected by the next state change.)

  private func request(_ command: PlugCommand) {
    desired = command
    hasPending = true
    attempt = 0
    retryWorkItem?.cancel()
    retryWorkItem = nil

    if !inFlight {
      sendPending()
    }
  }

  private func sendPending() {
    guard hasPending else { return }
    hasPending = false
    guard let command = desired, let client = client, let deviceId = targetDeviceId else { return }

    inFlight = true
    attempt += 1

    client.controlDevice(deviceId: deviceId, command: command) { result in
      self.queue.async {
        self.didFinish(command, result: result)
      }
    }
  }

  private func didFinish(_ command: PlugCommand, result: Result<CommandResponse, Error>) {
    inFlight = false

    switch result {
    case .success(let response):
      HandlerLogger.log(
        "Device control success: \(command.rawValue) (\(response.message))", handler: name)

    case .failure(let error):
      let reason = "\(command.rawValue): \(Self.describe(error))"
      if hasPending {
        // A newer state is waiting and supersedes this command
        HandlerLogger.log("Device control failed: \(reason)", handler: name)
      } else if shuttingDown {
        HandlerLogger.log(
          "Device control failed: \(reason), not retrying because the notifier is shutting down",
          handler: name)
      } else if Self.isRetryable(error) && attempt < Self.maxAttempts {
        let delay = min(Self.maxRetryDelay, pow(2, Double(attempt)))
        HandlerLogger.log(
          "Device control failed (attempt \(attempt)/\(Self.maxAttempts)): \(reason), "
            + "retrying in \(Int(delay))s", handler: name)
        scheduleRetry(after: delay)
      } else {
        HandlerLogger.log(
          "Device control failed: \(reason), giving up after \(attempt) attempt(s)", handler: name)
      }
    }

    if hasPending {
      sendPending()
    }
    signalIdleWaiters()
  }

  // Wake up flush/cleanup callers once nothing is in flight (a scheduled retry does not count)
  private func signalIdleWaiters() {
    guard !inFlight, !hasPending else { return }
    for waiter in idleWaiters {
      waiter.signal()
    }
    idleWaiters.removeAll()
  }

  private func scheduleRetry(after delay: TimeInterval) {
    let workItem = DispatchWorkItem {
      self.retryWorkItem = nil
      self.hasPending = true
      self.sendPending()
    }
    retryWorkItem = workItem
    queue.asyncAfter(deadline: .now() + delay, execute: workItem)
  }

  private static func isRetryable(_ error: Error) -> Bool {
    switch error {
    case SwitchBotError.httpStatus(let code):
      // 429: rate limited, 5xx: server side trouble. 401 (bad credentials or the daily limit)
      // and other client errors will not get better by retrying.
      return code == 429 || code >= 500
    case SwitchBotError.apiStatus(let code, _):
      // 161: device offline, 171: hub offline, 190: device internal error
      return [161, 171, 190].contains(code)
    case SwitchBotError.invalidURL:
      return false
    default:
      // Network errors (timeout, offline, connection lost, DNS, ...) and empty/malformed responses
      return true
    }
  }

  private static func describe(_ error: Error) -> String {
    if let urlError = error as? URLError {
      return "URLError \(urlError.code.rawValue) (\(urlError.localizedDescription))"
    }
    return "\(error)"
  }
}

// MARK: - SwitchBot API Client

private class SwitchBotClient {
  private let token: String
  private let secret: String
  private let baseURL = "https://api.switch-bot.com/v1.1"
  private let session: URLSession

  init(token: String, secret: String) {
    self.token = token
    self.secret = secret

    let configuration = URLSessionConfiguration.ephemeral
    // Right after wake the network is often not up yet: wait for it instead of failing at once
    configuration.waitsForConnectivity = true
    configuration.timeoutIntervalForRequest = 15
    configuration.timeoutIntervalForResource = 60
    self.session = URLSession(configuration: configuration)
  }

  private func generateSignature(stringToSign: String) -> String {
    guard let secretData = secret.data(using: .utf8),
      let stringData = stringToSign.data(using: .utf8)
    else {
      return ""
    }

    let key = SymmetricKey(data: secretData)
    let signature = HMAC<SHA256>.authenticationCode(for: stringData, using: key)
    return Data(signature).base64EncodedString()
  }

  private func createHeaders() -> [String: String] {
    let nonce = UUID().uuidString
    let timestamp = Int(Date().timeIntervalSince1970 * 1000)
    let stringToSign = "\(token)\(timestamp)\(nonce)"
    let signature = generateSignature(stringToSign: stringToSign)

    return [
      "Authorization": token,
      "sign": signature,
      "nonce": nonce,
      "t": "\(timestamp)",
      "Content-Type": "application/json",
    ]
  }

  private func makeRequest(
    endpoint: String, method: String = "GET", body: Data? = nil,
    completion: @escaping (Result<Data, Error>) -> Void
  ) {
    guard let url = URL(string: "\(baseURL)/\(endpoint)") else {
      completion(.failure(SwitchBotError.invalidURL))
      return
    }

    var request = URLRequest(url: url)
    request.httpMethod = method
    request.timeoutInterval = 15
    // Headers are generated per request: the signature includes a timestamp and a nonce
    request.allHTTPHeaderFields = createHeaders()
    request.httpBody = body

    session.dataTask(with: request) { data, response, error in
      if let error = error {
        completion(.failure(error))
        return
      }

      if let httpResponse = response as? HTTPURLResponse,
        !(200..<300).contains(httpResponse.statusCode)
      {
        completion(.failure(SwitchBotError.httpStatus(httpResponse.statusCode)))
        return
      }

      guard let data = data, !data.isEmpty else {
        completion(.failure(SwitchBotError.noData))
        return
      }

      completion(.success(data))
    }.resume()
  }

  // Check the API level status code (100 means success) before decoding the whole response:
  // error responses come with an empty or differently shaped body
  private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> Result<T, Error> {
    do {
      let status = try JSONDecoder().decode(StatusEnvelope.self, from: data)
      guard status.statusCode == 100 else {
        return .failure(SwitchBotError.apiStatus(status.statusCode, status.message ?? ""))
      }
      return .success(try JSONDecoder().decode(type, from: data))
    } catch {
      return .failure(error)
    }
  }

  func getDevices(completion: @escaping (Result<DeviceListResponse, Error>) -> Void) {
    makeRequest(endpoint: "devices") { result in
      completion(result.flatMap { Self.decode(DeviceListResponse.self, from: $0) })
    }
  }

  func controlDevice(
    deviceId: String, command: PlugCommand,
    completion: @escaping (Result<CommandResponse, Error>) -> Void
  ) {
    let commandData = CommandRequest(
      command: command.rawValue, parameter: "default", commandType: "command")

    do {
      let jsonData = try JSONEncoder().encode(commandData)
      makeRequest(endpoint: "devices/\(deviceId)/commands", method: "POST", body: jsonData) {
        result in
        completion(result.flatMap { Self.decode(CommandResponse.self, from: $0) })
      }
    } catch {
      completion(.failure(error))
    }
  }
}

// MARK: - SwitchBot Models

private enum PlugCommand: String {
  case turnOn = "turnOn"
  case turnOff = "turnOff"
}

private enum SwitchBotError: Error, CustomStringConvertible {
  case invalidURL
  case noData
  case httpStatus(Int)
  case apiStatus(Int, String)

  var description: String {
    switch self {
    case .invalidURL:
      return "invalid URL"
    case .noData:
      return "empty response"
    case .httpStatus(let code):
      return "HTTP \(code)"
    case .apiStatus(let code, let message):
      return "API statusCode \(code) (\(message))"
    }
  }
}

// The fields every API response has
private struct StatusEnvelope: Decodable {
  let statusCode: Int
  let message: String?
}

private struct DeviceListResponse: Decodable {
  let statusCode: Int
  let message: String
  let body: DeviceListBody
}

private struct DeviceListBody: Decodable {
  // infraredRemoteList is not decoded: its entries have a different shape and are not used
  let deviceList: [Device]
}

private struct Device: Decodable {
  let deviceId: String
  let deviceName: String
  let deviceType: String?
  let enableCloudService: Bool?
  let hubDeviceId: String?
}

private struct CommandRequest: Encodable {
  let command: String
  let parameter: String
  let commandType: String
}

// The response body is not needed; only the status is checked
private struct CommandResponse: Decodable {
  let statusCode: Int
  let message: String
}
