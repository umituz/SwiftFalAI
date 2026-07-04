import Foundation
import Security

// MARK: - Fal Configuration

/// Configuration for `FalClient`. Mirrors the conventions used across the
/// `Swift*` packages (e.g. SwiftGroq): a `Sendable` value carrying the API
/// key, base URL, and timing parameters.
public struct FalConfiguration: Sendable {

  /// Fal.ai queue base URL. Submit, status, and result URLs are derived
  /// from this plus the model endpoint.
  public static let defaultBaseURL = "https://queue.fal.run"

  public let apiKey: String
  public let baseURL: String
  public let timeoutInterval: TimeInterval
  public let pollInterval: TimeInterval
  public let maxPollAttempts: Int

  public init(
    apiKey: String,
    baseURL: String = FalConfiguration.defaultBaseURL,
    timeoutInterval: TimeInterval = 120.0,
    pollInterval: TimeInterval = 2.0,
    maxPollAttempts: Int = 90
  ) {
    self.apiKey = apiKey
    self.baseURL = baseURL
    self.timeoutInterval = timeoutInterval
    self.pollInterval = pollInterval
    self.maxPollAttempts = maxPollAttempts
  }
}

// MARK: - API Key Source

/// Resolves the Fal API key from one of several secure sources. The bundle
/// (`Info.plist`) source is intentionally **not** offered as a safe default —
/// a Fal key is a server-side billing secret and must never ship in the app
/// binary. Prefer `.keychain`.
public enum FalAPIKeySource {
  case key(String)
  case environment(variable: String = "FAL_KEY")
  case keychain(account: String = "com.umituz.swiftfalai.fal_api_key")

  public func resolve() -> String? {
    switch self {
    case .key(let value):
      return value.isEmpty ? nil : value
    case .environment(let variable):
      return ProcessInfo.processInfo.environment[variable]
    case .keychain(let account):
      return FalKeychain.load(key: account)
    }
  }
}

// MARK: - Keychain Helper

/// Minimal Keychain wrapper for storing the Fal key on-device.
public enum FalKeychain {
  private static let serviceIdentifier = "com.umituz.swiftfalai"

  @discardableResult
  public static func save(key: String, value: String) -> Bool {
    guard let data = value.data(using: .utf8) else { return false }

    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceIdentifier,
      kSecAttrAccount as String: key,
    ]
    SecItemDelete(query as CFDictionary)

    let attributes: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceIdentifier,
      kSecAttrAccount as String: key,
      kSecValueData as String: data,
      kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
    ]
    return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
  }

  public static func load(key: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceIdentifier,
      kSecAttrAccount as String: key,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]

    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  @discardableResult
  public static func delete(key: String) -> Bool {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: serviceIdentifier,
      kSecAttrAccount as String: key,
    ]
    let status = SecItemDelete(query as CFDictionary)
    return status == errSecSuccess || status == errSecItemNotFound
  }
}
