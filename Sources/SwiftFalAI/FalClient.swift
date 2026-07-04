import Foundation

// MARK: - Retry Policy

/// Defines retry behavior for transient failures.
public struct FalRetryPolicy {
  public let maxAttempts: Int
  public let baseDelay: TimeInterval
  public let maxDelay: TimeInterval
  public let jitterFactor: Double

  public init(
    maxAttempts: Int = 3,
    baseDelay: TimeInterval = 1.0,
    maxDelay: TimeInterval = 60.0,
    jitterFactor: Double = 0.1
  ) {
    precondition(maxAttempts > 0, "maxAttempts must be positive")
    precondition(baseDelay > 0, "baseDelay must be positive")
    precondition(maxDelay >= baseDelay, "maxDelay must be >= baseDelay")
    precondition((0...1).contains(jitterFactor), "jitterFactor must be between 0 and 1")

    self.maxAttempts = maxAttempts
    self.baseDelay = baseDelay
    self.maxDelay = maxDelay
    self.jitterFactor = jitterFactor
  }

  func shouldRetry(attempt: Int, error: Error) -> Bool {
    guard attempt < maxAttempts else { return false }
    guard let falError = error as? FalError else { return false }
    return falError.isRetryable
  }

  func delay(for attempt: Int) -> TimeInterval {
    let exponential = min(baseDelay * pow(2.0, Double(attempt)), maxDelay)
    let jitter = Double.random(in: 0...(exponential * jitterFactor))
    return exponential + jitter
  }
}

// MARK: - Metrics Collector

/// Protocol for collecting metrics about Fal.ai API calls.
public protocol FalMetricsCollector: Sendable {
  func recordRequest(endpoint: String, duration: TimeInterval, success: Bool)
  func recordError(error: FalError, endpoint: String)
  func recordQueuePoll(endpoint: String, attempts: Int, duration: TimeInterval)
}

/// Console-based metrics collector for debugging.
public final class ConsoleMetrics: FalMetricsCollector, @unchecked Sendable {
  public static let shared = ConsoleMetrics()

  private init() {}

  public func recordRequest(endpoint: String, duration: TimeInterval, success: Bool) {
    let status = success ? "✅" : "❌"
    FalLogger.shared.debug("[Metrics] \(status) \(endpoint) - \(String(format: "%.2fs", duration))")
  }

  public func recordError(error: FalError, endpoint: String) {
    FalLogger.shared.error("[Metrics] Error on \(endpoint): \(error.localizedDescription)")
  }

  public func recordQueuePoll(endpoint: String, attempts: Int, duration: TimeInterval) {
    FalLogger.shared.debug("[Metrics] Queue \(endpoint) - \(attempts) polls in \(String(format: "%.2fs", duration))")
  }
}

/// Null metrics collector for production when metrics are not needed.
public final class NullMetrics: FalMetricsCollector, Sendable {
  public static let shared = NullMetrics()

  private init() {}

  public func recordRequest(endpoint: String, duration: TimeInterval, success: Bool) {}
  public func recordError(error: FalError, endpoint: String) {}
  public func recordQueuePoll(endpoint: String, attempts: Int, duration: TimeInterval) {}
}

// MARK: - Progress Handler

/// Progress updates for long-running operations.
public struct FalProgress {
  public enum State: Equatable {
    case submitting
    case queued(currentAttempt: Int, maxAttempts: Int)
    case processing
    case downloading
    case completed

    public static func == (lhs: State, rhs: State) -> Bool {
      switch (lhs, rhs) {
      case (.submitting, .submitting),
           (.processing, .processing),
           (.downloading, .downloading),
           (.completed, .completed):
        return true
      case let (.queued(lAttempt, lMax), .queued(rAttempt, rMax)):
        return lAttempt == rAttempt && lMax == rMax
      default:
        return false
      }
    }
  }

  public let state: State
  public let message: String

  public init(state: State, message: String = "") {
    self.state = state
    self.message = message
  }
}

/// Callback type for progress updates.
public typealias FalProgressHandler = @Sendable (FalProgress) -> Void

// MARK: - Request Validator

/// Validates requests before sending to API.
public protocol FalRequestValidator: Sendable {
  func validate(endpoint: String, input: Encodable) throws
}

/// Default validator with sensible limits.
public final class DefaultRequestValidator: FalRequestValidator, Sendable {
  public static let shared = DefaultRequestValidator()

  private let maxEndpointLength: Int
  private let maxPayloadSize: Int

  public init(
    maxEndpointLength: Int = 256,
    maxPayloadSize: Int = 10_000_000
  ) {
    self.maxEndpointLength = maxEndpointLength
    self.maxPayloadSize = maxPayloadSize
  }

  public func validate(endpoint: String, input: Encodable) throws {
    guard !endpoint.isEmpty else {
      throw FalError.invalidRequest("Endpoint cannot be empty")
    }
    guard endpoint.count <= maxEndpointLength else {
      throw FalError.invalidRequest("Endpoint too long (max \(maxEndpointLength) characters)")
    }
    guard endpoint.hasPrefix("/") else {
      throw FalError.invalidRequest("Endpoint must start with '/'")
    }
  }
}

// MARK: - Fal Client

/// Async client for the Fal.ai queue API (https://queue.fal.run).
///
/// Production-ready client with:
/// - Thread-safe singleton configuration
/// - Retry logic with exponential backoff
/// - Request validation
/// - Metrics collection
/// - Progress callbacks
/// - Memory leak prevention
public final class FalClient: @unchecked Sendable {

  // MARK: - Static Configuration

  private static let lock = NSLock()
  private static var configuredInstance: FalClient?

  /// Metrics collector (defaults to NullMetrics).
  public static var metricsCollector: FalMetricsCollector = NullMetrics.shared {
    didSet {
      lock.lock()
      let instance = configuredInstance
      lock.unlock()
      instance?.updateMetricsCollector(metricsCollector)
    }
  }

  /// True when a configuration with a non-empty API key has been applied.
  public static var isConfigured: Bool {
    lock.lock()
    let instance = configuredInstance
    lock.unlock()
    return instance?.isConfigured ?? false
  }

  /// Returns the configured client, throwing if `configure(_:)` was never called.
  public static func configured() throws -> FalClient {
    lock.lock()
    let instance = configuredInstance
    lock.unlock()
    guard let instance = instance else { throw FalError.notConfigured }
    return instance
  }

  public static func configure(_ configuration: FalConfiguration) {
    lock.lock()
    let previous = configuredInstance
    configuredInstance = FalClient(
      configuration: configuration,
      retryPolicy: FalRetryPolicy(),
      validator: DefaultRequestValidator.shared,
      metricsCollector: metricsCollector
    )
    lock.unlock()
    previous?.cleanup()
    FalLogger.shared.info("FalClient configured (baseURL: \(configuration.baseURL))")
  }

  /// Convenience configurator that resolves the key from a secure source.
  public static func configure(
    apiKeySource: FalAPIKeySource = .keychain(),
    baseURL: String = FalConfiguration.defaultBaseURL,
    timeoutInterval: TimeInterval = 120.0,
    retryPolicy: FalRetryPolicy = FalRetryPolicy(),
    metricsCollector: FalMetricsCollector? = nil
  ) throws {
    guard let apiKey = apiKeySource.resolve(), !apiKey.isEmpty else {
      throw FalError.missingAPIKey
    }
    let config = FalConfiguration(
      apiKey: apiKey,
      baseURL: baseURL,
      timeoutInterval: timeoutInterval
    )
    if let metricsCollector = metricsCollector {
      self.metricsCollector = metricsCollector
    }
    configure(config)
    lock.lock()
    configuredInstance?.updateRetryPolicy(retryPolicy)
    lock.unlock()
  }

  public static func reset() {
    lock.lock()
    let previous = configuredInstance
    configuredInstance = nil
    lock.unlock()
    previous?.cleanup()
    FalLogger.shared.info("FalClient reset")
  }

  // MARK: - Instance Properties

  private let configuration: FalConfiguration
  private let encoder: JSONEncoder
  private let decoder: JSONDecoder
  private var retryPolicy: FalRetryPolicy
  private let validator: FalRequestValidator
  private var metricsCollector: FalMetricsCollector

  // MARK: - URLSession (Lazy to prevent retain cycles)

  private lazy var session: URLSession = {
    let config = URLSessionConfiguration.default
    config.timeoutIntervalForRequest = configuration.timeoutInterval
    config.timeoutIntervalForResource = configuration.timeoutInterval * 2
    config.waitsForConnectivity = true
    config.requestCachePolicy = .reloadIgnoringLocalCacheData
    return URLSession(configuration: config, delegate: nil, delegateQueue: nil)
  }()

  private var isConfigured: Bool {
    !configuration.apiKey.isEmpty
  }

  // MARK: - Initialization

  private init(
    configuration: FalConfiguration,
    retryPolicy: FalRetryPolicy,
    validator: FalRequestValidator,
    metricsCollector: FalMetricsCollector
  ) {
    self.configuration = configuration
    self.retryPolicy = retryPolicy
    self.validator = validator
    self.metricsCollector = metricsCollector
    self.encoder = JSONEncoder()
    self.decoder = JSONDecoder()
  }

  private func cleanup() {
    session.invalidateAndCancel()
  }

  deinit {
    cleanup()
  }

  // MARK: - Internal Updates (called from static with lock held)

  private func updateRetryPolicy(_ policy: FalRetryPolicy) {
    retryPolicy = policy
  }

  private func updateMetricsCollector(_ collector: FalMetricsCollector) {
    metricsCollector = collector
  }

  // MARK: - High-Level API

  /// Submits a job and waits for its result, decoding the final output as `T`.
  /// Handles both synchronous endpoints (output returned on submit) and
  /// queued endpoints (submit → poll status → fetch result).
  ///
  /// - Parameters:
  ///   - endpoint: The Fal.ai endpoint (e.g., "/fal-ai/flux/schnell")
  ///   - input: Encodable input payload
  ///   - type: The type to decode the response as
  ///   - progress: Optional progress callback for long-running operations
  /// - Returns: The decoded response of type `T`
  public func run<T: Decodable>(
    endpoint: String,
    input: some Encodable,
    as type: T.Type = T.self,
    progress: FalProgressHandler? = nil
  ) async throws -> T {
    let startTime = Date()
    var lastError: Error?

    // Validate request
    try validator.validate(endpoint: endpoint, input: input)

    for attempt in 0..<retryPolicy.maxAttempts {
      do {
        if attempt > 0 {
          let delay = retryPolicy.delay(for: attempt)
          FalLogger.shared.debug("Retry attempt \(attempt + 1) after \(String(format: "%.2fs", delay)) delay")
          try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        let result = try await attemptRun(endpoint: endpoint, input: input, as: type, progress: progress)

        let duration = Date().timeIntervalSince(startTime)
        metricsCollector.recordRequest(endpoint: endpoint, duration: duration, success: true)

        return result

      } catch {
        lastError = error

        if !retryPolicy.shouldRetry(attempt: attempt, error: error) {
          metricsCollector.recordError(error: error as? FalError ?? .invalidResponse, endpoint: endpoint)
          throw error
        }
      }
    }

    let duration = Date().timeIntervalSince(startTime)
    metricsCollector.recordRequest(endpoint: endpoint, duration: duration, success: false)

    throw lastError ?? FalError.requestTimedOut
  }

  private func attemptRun<T: Decodable>(
    endpoint: String,
    input: some Encodable,
    as type: T.Type,
    progress: FalProgressHandler?
  ) async throws -> T {
    progress?(FalProgress(state: .submitting, message: "Submitting request to \(endpoint)"))

    let (data, response) = try await submit(endpoint: endpoint, input: input)
    try validate(response, data: data)

    // Queued? Fal returns request_id + status_url for async work.
    if let queue = try? decoder.decode(FalQueueResponse.self, from: data), queue.isQueued {
      return try await wait(T.self, queue: queue, progress: progress)
    }

    do {
      return try decoder.decode(T.self, from: data)
    } catch {
      throw FalError.decodingFailed(error)
    }
  }

  /// Convenience for image-producing endpoints: returns the first image URL.
  public func imageURL(
    endpoint: String,
    input: some Encodable,
    progress: FalProgressHandler? = nil
  ) async throws -> URL {
    let output: FalImageOutput = try await run(endpoint: endpoint, input: input, progress: progress)
    guard let urlString = output.firstImageURL, let url = URL(string: urlString) else {
      throw FalError.noOutput
    }
    return url
  }

  /// Downloads raw bytes from a URL.
  public func download(from url: URL, progress: FalProgressHandler? = nil) async throws -> Data {
    try Task.checkCancellation()
    progress?(FalProgress(state: .downloading, message: "Downloading from \(url.lastPathComponent)"))

    let (data, response) = try await session.data(from: url)
    try validate(response, data: data)
    return data
  }

  // MARK: - Queue Polling

  private func wait<T: Decodable>(
    _ type: T.Type,
    queue: FalQueueResponse,
    progress: FalProgressHandler?
  ) async throws -> T {
    guard let statusString = queue.statusURL, let statusURL = URL(string: statusString) else {
      throw FalError.invalidResponse
    }
    let resultURL = queue.responseURL.flatMap(URL.init(string:))

    let startTime = Date()
    var lastAttempt = 0

    for attempt in 0..<configuration.maxPollAttempts {
      lastAttempt = attempt
      try Task.checkCancellation()

      if attempt > 0 {
        try await Task.sleep(nanoseconds: UInt64(configuration.pollInterval * 1_000_000_000))
      }

      progress?(FalProgress(
        state: .queued(currentAttempt: attempt + 1, maxAttempts: configuration.maxPollAttempts),
        message: "Waiting for processing... (attempt \(attempt + 1)/\(configuration.maxPollAttempts))"
      ))

      switch try await fetchStatus(statusURL).state {
      case .completed:
        guard let resultURL else { throw FalError.invalidResponse }
        progress?(FalProgress(state: .downloading, message: "Fetching result"))

        let duration = Date().timeIntervalSince(startTime)
        metricsCollector.recordQueuePoll(endpoint: resultURL.absoluteString, attempts: attempt + 1, duration: duration)

        return try await fetchResult(type, resultURL)

      case .failed:
        throw FalError.processingFailed

      case .inProgress:
        progress?(FalProgress(state: .processing, message: "Processing your request..."))

      case .inQueue, .unknown:
        continue
      }
    }

    let duration = Date().timeIntervalSince(startTime)
    metricsCollector.recordQueuePoll(endpoint: statusString, attempts: lastAttempt + 1, duration: duration)

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

  private func submit(endpoint: String, input: some Encodable) async throws -> (Data, URLResponse) {
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

private struct AnyEncodable: Encodable {
  private let encode: (Encoder) throws -> Void

  init(_ wrapped: some Encodable) {
    self.encode = wrapped.encode
  }

  func encode(to encoder: Encoder) throws {
    try encode(encoder)
  }
}
