// SwitchBot Sync Handler - Camera state synchronization with SwitchBot devices
// Automatically turns SwitchBot Plug devices ON/OFF based on camera state

import CryptoKit
import Foundation

// SwitchBot state synchronization handler
public class SwitchBotSyncHandler: CameraStateHandler {
  public let name = "SwitchBot"

  private var client: SwitchBotClient?
  private var targetDeviceId: String?
  private var token: String?
  private var secret: String?

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

    self.token = token
    self.secret = secret
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
        let plugs = deviceResponse.body.deviceList.filter { $0.deviceType.contains("Plug") }

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
          "Failed to get device list: \(error)")
      }
    }

    semaphore.wait()

    if let error = detectionError {
      throw error
    }

    self.targetDeviceId = detectedDeviceId
  }

  public func handleCameraStateChange(_ change: CameraStateChange) {
    guard let client = client, let deviceId = targetDeviceId else {
      HandlerLogger.log("Handler not properly configured", handler: name)
      return
    }

    let command: PlugCommand = change.isRunning ? .turnOn : .turnOff
    let action = change.isRunning ? "started" : "stopped"
    let deviceName = change.deviceName ?? "Unknown device"

    HandlerLogger.log(
      "Camera \(action): \(deviceName), sending \(command.rawValue) command", handler: name)

    client.controlDevice(deviceId: deviceId, command: command) { [weak self] result in
      switch result {
      case .success(let response):
        HandlerLogger.log(
          "Device control success: \(response.message)", handler: self?.name ?? "SwitchBot")
      case .failure(let error):
        HandlerLogger.log("Device control failed: \(error)", handler: self?.name ?? "SwitchBot")
      }
    }
  }
}

// MARK: - SwitchBot API Client

private class SwitchBotClient {
  private let token: String
  private let secret: String
  private let baseURL = "https://api.switch-bot.com/v1.1"

  init(token: String, secret: String) {
    self.token = token
    self.secret = secret
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
    request.allHTTPHeaderFields = createHeaders()

    if let body = body {
      request.httpBody = body
    }

    URLSession.shared.dataTask(with: request) { data, response, error in
      if let error = error {
        completion(.failure(error))
        return
      }

      guard let data = data else {
        completion(.failure(SwitchBotError.noData))
        return
      }

      completion(.success(data))
    }.resume()
  }

  func getDevices(completion: @escaping (Result<DeviceListResponse, Error>) -> Void) {
    makeRequest(endpoint: "devices") { result in
      switch result {
      case .success(let data):
        do {
          let response = try JSONDecoder().decode(DeviceListResponse.self, from: data)
          completion(.success(response))
        } catch {
          completion(.failure(error))
        }
      case .failure(let error):
        completion(.failure(error))
      }
    }
  }

  func controlDevice(
    deviceId: String, command: PlugCommand,
    completion: @escaping (Result<CommandResponse, Error>) -> Void
  ) {
    let commandData = CommandRequest(command: command.rawValue, parameter: "default")

    do {
      let jsonData = try JSONEncoder().encode(commandData)
      makeRequest(endpoint: "devices/\(deviceId)/commands", method: "POST", body: jsonData) {
        result in
        switch result {
        case .success(let data):
          do {
            let response = try JSONDecoder().decode(CommandResponse.self, from: data)
            completion(.success(response))
          } catch {
            completion(.failure(error))
          }
        case .failure(let error):
          completion(.failure(error))
        }
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

private enum SwitchBotError: Error {
  case invalidURL
  case noData
  case invalidResponse
}

private struct DeviceListResponse: Codable {
  let statusCode: Int
  let message: String
  let body: DeviceListBody
}

private struct DeviceListBody: Codable {
  let deviceList: [Device]
  let infraredRemoteList: [Device]
}

private struct Device: Codable {
  let deviceId: String
  let deviceName: String
  let deviceType: String
  let enableCloudService: Bool?
  let hubDeviceId: String?
}

private struct CommandRequest: Codable {
  let command: String
  let parameter: String
}

private struct CommandResponse: Codable {
  let statusCode: Int
  let message: String
  let body: [String: String]
}
