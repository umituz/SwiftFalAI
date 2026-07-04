import Foundation

// MARK: - Fal Client

/// Async client for the Fal.ai queue API (https://queue.fal.run).
///
/// Mirrors the conventions of the other `Swift*` packages (e.g. SwiftGroq):
/// a singleton-configured, `@unchecked Sendable` client resolved via
/// `configured()`. Handles the Fal submit → poll-status → fetch-result flow,
/// honors `Task` cancellation, and validates HTTP status before decoding.
public final class FalClient: @unchecked Sendable {

  private static let lock = NSLock()
  private static var configuredInstance: FalClient?

  /// True when a configuration with a non-empty API key has been applied.
  public static var isConfigured: Bool {
    lock.lock()
    defer { lock.unlock() }
    return configuredInstance?.configuration.apiKey.isEmpty == false
  }

  /// Returns the configured client, throwing if `configure(_:)` was never called.
  public static func configured() throws -> FalClient {
    lock.lock()
    defer { lock.unlock() }
    guard let instance = configuredInstance else { throw FalError.notConfigured }
    return instance
  }

  public static func configure(_ configuration: FalConfiguration) {
    lock.lock()
    let previous = configuredInstance
    configuredInstance = FalClient(configuration: configuration)
    lock.unlock()
    previous?.session.invalidateAndCancel()
    FalLogger.shared.info("FalClient configured (baseURL: \(configuration.baseURL))")
  }

  /// Convenience configurator that resolves the key from a secure source.
  public static func configure(
    apiKeySource: FalAPIKeySource = .keychain(),
    baseURL: String = FalConfiguration.defaultBaseURL,
    timeoutInterval: TimeInterval = 120.0
  ) throws {
    guard let apiKey = apiKeySource.resolve(), !apiKey.isEmpty else {
      throw FalError.missingAPIKey
    }
    configure(
      FalConfiguration(
        apiKey: apiKey,
        baseURL: baseURL,
        timeoutInterval: timeoutInterval
      ))
  }

  public static func reset() {
    lock.lock()
    let previous = configuredInstance
    configuredInstance = nil
    lock.unlock()
    previous?.session.invalidateAndCancel()
    FalLogger.shared.info("FalClient reset")
  }

  // MARK: - Instance

  private let configuration: FalConfiguration
  private let session: URLSession
  private let decoder: JSONDecoder
  private let encoder: JSONEncoder

  private init(configuration: FalConfiguration) {
    self.configuration = configuration

    let urlConfig = URLSessionConfiguration.default
    urlConfig.timeoutIntervalForRequest = configuration.timeoutInterval
    urlConfig.timeoutIntervalForResource = configuration.timeoutInterval * 2
    urlConfig.waitsForConnectivity = true
    self.session = URLSession(configuration: urlConfig)

    self.decoder = JSONDecoder()
    self.encoder = JSONEncoder()
  }

  deinit {
    session.invalidateAndCancel()
  }

  // MARK: - High-Level

  /// Submits a job and waits for its result, decoding the final output as `T`.
  /// Handles both synchronous endpoints (output returned on submit) and
  /// queued endpoints (submit → poll status → fetch result).
  public func run<T: Decodable>(
    endpoint: String,
    input: Encodable,
    as type: T.Type = T.self
  ) async throws -> T {
    let (data, response) = try await submit(endpoint: endpoint, input: input)
    try validate(response, data: data)

    // Queued? Fal returns request_id + status_url for async work.
    if let queue = try? decoder.decode(FalQueueResponse.self, from: data), queue.isQueued {
      return try await wait(T.self, queue: queue)
    }

    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw FalError.decodingFailed(error)
    }
  }

  /// Convenience for image-producing endpoints: returns the first image URL
  /// from the result, then the caller downloads it (or use `download`).
  public func imageURL(endpoint: String, input: Encodable) async throws -> URL {
    let output: FalImageOutput = try await run(endpoint: endpoint, input: input)
    guard let urlString = output.firstImageURL, let url = URL(string: urlString) else {
      throw FalError.noOutput
    }
    return url
  }

  /// Downloads raw bytes from a URL, rejecting non-2xx instead of handing
  /// error/HTML payloads to the caller.
  public func download(from url: URL) async throws -> Data {
    try Task.checkCancellation()
    let (data, response) = try await session.data(from: url)
    try validate(response, data: data)
    return data
  }

  // MARK: - Queue Internals

  private func wait<T: Decodable>(_ type: T.Type, queue: FalQueueResponse) async throws -> T {
    guard let statusString = queue.statusURL, let statusURL = URL(string: statusString) else {
      throw FalError.invalidResponse
    }
    let resultURL = queue.responseURL.flatMap(URL.init(string:))

    for _ in 0..<configuration.maxPollAttempts {
      try Task.checkCancellation()
      try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))

      switch try await fetchStatus(statusURL).state {
      case .completed:
        guard let resultURL else { throw FalError.invalidResponse }
        return try await fetchResult(type, resultURL)
      case .failed:
        throw FalError.processingFailed
      case .inQueue, .inProgress, .unknown:
        continue
      }
    }

    FalLogger.shared.warning("Polling exhausted after \(configuration.maxPollAttempts) attempts")
    throw FalError.requestTimedOut
  }

  private func fetchStatus(_ url: URL) async throws -> FalStatusResponse {
    let request = try authenticatedRequest(url: url, method: "GET")
    let (data, response) = try await session.data(for: request)
    try validate(response, data: data)
    do {
      return try decoder.decode(FalStatusResponse.self, from: data)
    } catch {
      throw FalError.decodingFailed(error)
    }
  }

  private func fetchResult<T: Decodable>(_ type: T.Type, _ url: URL) async throws -> T {
    let request = try authenticatedRequest(url: url, method: "GET")
    let (data, response) = try await session.data(for: request)
    try validate(response, data: data)
    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw FalError.decodingFailed(error)
    }
  }

  // MARK: - HTTP

  private func submit(endpoint: String, input: Encodable) async throws -> (Data, URLResponse) {
    let url = try resolvedURL(endpoint: endpoint)
    var request = try authenticatedRequest(url: url, method: "POST")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    do {
      request.httpBody = try encoder.encode(AnyEncodable(input))
    } catch {
      throw FalError.invalidRequest("Failed to encode input: \(error.localizedDescription)")
    }
    do {
      return try await session.data(for: request)
    } catch {
      if let urlError = error as? URLError, urlError.code == .timedOut {
        throw FalError.requestTimedOut
      }
      throw FalError.networkError(error.localizedDescription)
    }
  }

  private func resolvedURL(endpoint: String) throws -> URL {
    let trimmed = endpoint.hasPrefix("/") ? endpoint : "/" + endpoint
    guard let url = URL(string: configuration.baseURL + trimmed) else {
      throw FalError.invalidURL
    }
    return url
  }

  private func authenticatedRequest(url: URL, method: String) throws -> URLRequest {
    guard !configuration.apiKey.isEmpty else { throw FalError.missingAPIKey }
    var request = URLRequest(url: url)
    request.httpMethod = method
    request.setValue("Key \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = configuration.timeoutInterval
    return request
  }

  private func validate(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { throw FalError.invalidResponse }
    switch http.statusCode {
    case 200...299:
      return
    case 401:
      throw FalError.unauthorized
    case 402:
      throw FalError.insufficientCredits
    case 429:
      let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Int($0) }
      throw FalError.rateLimited(retryAfter: retryAfter)
    default:
      let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])
        .flatMap { $0["detail"] as? String ?? ($0["message"] as? String) }
      throw FalError.serverError(statusCode: http.statusCode, message: message)
    }
  }
}

// MARK: - Type-Erased Encodable

/// Wraps any `Encodable` so a single parameter type can encode heterogeneous
/// input payloads. The encoded JSON mirrors the wrapped value's `CodingKeys`.
private struct AnyEncodable: Encodable {
  private let encode: (Encoder) throws -> Void

  init(_ wrapped: Encodable) {
    self.encode = wrapped.encode
  }

  func encode(to encoder: Encoder) throws {
    try encode(encoder)
  }
}
