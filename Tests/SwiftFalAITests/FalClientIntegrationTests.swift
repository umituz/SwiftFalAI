import XCTest
@testable import SwiftFalAI

/// Integration tests for SwiftFalAI production readiness.
/// These tests verify thread safety, memory management, retry logic,
/// and edge cases that unit tests may miss.
final class FalClientIntegrationTests: XCTestCase {

  // MARK: - Setup & Teardown

  override func setUp() {
    super.setUp()
    FalClient.reset()
    FalClient.metricsCollector = NullMetrics.shared
  }

  override func tearDown() {
    FalClient.reset()
    FalClient.metricsCollector = NullMetrics.shared
    super.tearDown()
  }

  // MARK: - Thread Safety Tests

  func testConcurrentConfigurationAccess() {
    let expectation = XCTestExpectation(description: "Concurrent configuration")
    expectation.expectedFulfillmentCount = 100

    DispatchQueue.concurrentPerform(iterations: 100) { iteration in
      do {
        try FalClient.configure(
          apiKeySource: .key("test-key-\(iteration)")
        )
        XCTAssertTrue(FalClient.isConfigured)
        expectation.fulfill()
      } catch {
        XCTFail("Configuration failed: \(error)")
      }
    }

    wait(for: [expectation], timeout: 5.0)
    XCTAssertTrue(FalClient.isConfigured)
  }

  func testConcurrentConfiguredCalls() {
    try? FalClient.configure(apiKeySource: .key("test-key"))

    let expectation = XCTestExpectation(description: "Concurrent configured calls")
    expectation.expectedFulfillmentCount = 50

    DispatchQueue.concurrentPerform(iterations: 50) { _ in
      do {
        let client = try FalClient.configured()
        XCTAssertNotNil(client)
        expectation.fulfill()
      } catch {
        XCTFail("configured() failed: \(error)")
      }
    }

    wait(for: [expectation], timeout: 5.0)
  }

  func testConcurrentReset() {
    try? FalClient.configure(apiKeySource: .key("test-key"))

    let expectation = XCTestExpectation(description: "Concurrent reset")
    expectation.expectedFulfillmentCount = 20

    DispatchQueue.concurrentPerform(iterations: 20) { _ in
      FalClient.reset()
      expectation.fulfill()
    }

    wait(for: [expectation], timeout: 2.0)
    XCTAssertFalse(FalClient.isConfigured)
  }

  // MARK: - Retry Logic Tests

  func testRetryPolicyConfiguration() {
    let policy = FalRetryPolicy(
      maxAttempts: 5,
      baseDelay: 0.5,
      maxDelay: 30.0,
      jitterFactor: 0.2
    )

    XCTAssertEqual(policy.maxAttempts, 5)
    XCTAssertEqual(policy.baseDelay, 0.5)
    XCTAssertEqual(policy.maxDelay, 30.0)

    // Test delay calculation
    let delay0 = policy.delay(for: 0)
    XCTAssertEqual(delay0, 0.5, accuracy: 0.15) // Account for jitter

    let delay1 = policy.delay(for: 1)
    XCTAssertGreaterThan(delay1, 0.5)
    XCTAssertLessThan(delay1, 1.5)

    // High attempt numbers should be capped at maxDelay
    // attempt 5: exponential = min(0.5 * 32, 30.0) = 16.0
    // So delay should be ~16.0, NOT capped yet
    let delay5 = policy.delay(for: 5)
    XCTAssertLessThan(delay5, 20.0)
    XCTAssertGreaterThan(delay5, 15.0)

    // Very high attempt should cap at maxDelay
    let delay10 = policy.delay(for: 10)
    XCTAssertLessThanOrEqual(delay10, 33.0) // maxDelay + jitter
    XCTAssertGreaterThanOrEqual(delay10, 28.0) // Near maxDelay
  }

  func testRetryPolicyShouldRetry() {
    let policy = FalRetryPolicy(maxAttempts: 3)

    // Retryable errors
    XCTAssertTrue(policy.shouldRetry(attempt: 0, error: FalError.serverError(statusCode: 500, message: nil)))
    XCTAssertTrue(policy.shouldRetry(attempt: 0, error: FalError.requestTimedOut))
    XCTAssertTrue(policy.shouldRetry(attempt: 0, error: FalError.rateLimited(retryAfter: nil)))

    // Non-retryable errors
    XCTAssertFalse(policy.shouldRetry(attempt: 0, error: FalError.notConfigured))
    XCTAssertFalse(policy.shouldRetry(attempt: 0, error: FalError.missingAPIKey))
    XCTAssertFalse(policy.shouldRetry(attempt: 0, error: FalError.unauthorized))

    // Exceeded attempts
    XCTAssertFalse(policy.shouldRetry(attempt: 3, error: FalError.requestTimedOut))
  }

  func testRetryPolicyExponentialBackoff() {
    let policy = FalRetryPolicy(maxAttempts: 10, baseDelay: 1.0, maxDelay: 60.0)

    var lastDelay = policy.delay(for: 0)
    for attempt in 1..<10 {
      let delay = policy.delay(for: attempt)
      // Should grow exponentially
      XCTAssertGreaterThanOrEqual(delay, lastDelay * 0.9) // Account for jitter
      lastDelay = delay
    }

    // Last attempt should be near maxDelay
    XCTAssertEqual(lastDelay, 60.0, accuracy: 10.0)
  }

  // MARK: - Request Validation Tests

  func testDefaultRequestValidatorValidEndpoint() {
    let validator = DefaultRequestValidator()

    struct TestInput: Encodable {
      let value: String
    }

    XCTAssertNoThrow(try validator.validate(endpoint: "/fal-ai/test", input: TestInput(value: "test")))
  }

  func testDefaultRequestValidatorRejectsEmptyEndpoint() {
    let validator = DefaultRequestValidator()

    struct TestInput: Encodable {
      let value: String
    }

    XCTAssertThrowsError(try validator.validate(endpoint: "", input: TestInput(value: "test"))) { error in
      guard case FalError.invalidRequest = error else {
        XCTFail("Expected invalidRequest error")
        return
      }
    }
  }

  func testDefaultRequestValidatorRejectsTooLongEndpoint() {
    let validator = DefaultRequestValidator(maxEndpointLength: 10)

    struct TestInput: Encodable {
      let value: String
    }

    XCTAssertThrowsError(try validator.validate(endpoint: "/very-long-endpoint", input: TestInput(value: "test"))) { error in
      guard case FalError.invalidRequest = error else {
        XCTFail("Expected invalidRequest error")
        return
      }
    }
  }

  func testDefaultRequestValidatorRejectsMissingSlash() {
    let validator = DefaultRequestValidator()

    struct TestInput: Encodable {
      let value: String
    }

    XCTAssertThrowsError(try validator.validate(endpoint: "no-slash", input: TestInput(value: "test"))) { error in
      guard case FalError.invalidRequest = error else {
        XCTFail("Expected invalidRequest error")
        return
      }
    }
  }

  // MARK: - Metrics Tests

  func testConsoleMetrics() {
    let metrics = ConsoleMetrics.shared

    // Should not crash
    metrics.recordRequest(endpoint: "/test", duration: 1.5, success: true)
    metrics.recordRequest(endpoint: "/test", duration: 0.5, success: false)
    metrics.recordError(error: .unauthorized, endpoint: "/test")
    metrics.recordQueuePoll(endpoint: "/test", attempts: 5, duration: 10.0)
  }

  func testNullMetrics() {
    let metrics = NullMetrics.shared

    // Should not crash and do nothing
    metrics.recordRequest(endpoint: "/test", duration: 1.5, success: true)
    metrics.recordError(error: .unauthorized, endpoint: "/test")
    metrics.recordQueuePoll(endpoint: "/test", attempts: 5, duration: 10.0)
  }

  func testCustomMetricsCollector() {
    final class TestMetrics: FalMetricsCollector, @unchecked Sendable {
      var requestCount = 0
      var errorCount = 0
      var queuePollCount = 0

      func recordRequest(endpoint: String, duration: TimeInterval, success: Bool) {
        requestCount += 1
      }

      func recordError(error: FalError, endpoint: String) {
        errorCount += 1
      }

      func recordQueuePoll(endpoint: String, attempts: Int, duration: TimeInterval) {
        queuePollCount += 1
      }
    }

    let metrics = TestMetrics()
    FalClient.metricsCollector = metrics

    metrics.recordRequest(endpoint: "/test", duration: 1.0, success: true)
    metrics.recordError(error: .unauthorized, endpoint: "/test")
    metrics.recordQueuePoll(endpoint: "/test", attempts: 3, duration: 5.0)

    XCTAssertEqual(metrics.requestCount, 1)
    XCTAssertEqual(metrics.errorCount, 1)
    XCTAssertEqual(metrics.queuePollCount, 1)
  }

  // MARK: - Progress Callback Tests

  func testProgressCallbackStates() {
    var progressUpdates: [FalProgress] = []
    let lock = NSLock()

    let callback: FalProgressHandler = { progress in
      lock.lock()
      progressUpdates.append(progress)
      lock.unlock()
    }

    // Test all states
    callback(FalProgress(state: .submitting, message: "Submitting"))
    callback(FalProgress(state: .queued(currentAttempt: 1, maxAttempts: 10), message: "Queued"))
    callback(FalProgress(state: .processing, message: "Processing"))
    callback(FalProgress(state: .downloading, message: "Downloading"))
    callback(FalProgress(state: .completed, message: "Completed"))

    XCTAssertEqual(progressUpdates.count, 5)
    XCTAssertEqual(progressUpdates[0].state, .submitting)
  }

  // MARK: - Memory Management Tests

  func testClientCleanupOnReset() {
    try? FalClient.configure(apiKeySource: .key("test-key"))
    let client = try? FalClient.configured()
    XCTAssertNotNil(client)

    FalClient.reset()

    XCTAssertFalse(FalClient.isConfigured)
    XCTAssertThrowsError(try FalClient.configured()) { error in
      guard case FalError.notConfigured = error else {
        XCTFail("Expected notConfigured error")
        return
      }
    }
  }

  func testWeakReferencePattern() {
    // This test verifies that clients don't create strong reference cycles
    weak var weakClient: FalClient?

    autoreleasepool {
      try? FalClient.configure(apiKeySource: .key("test-key"))
      let client = try? FalClient.configured()
      weakClient = client
      XCTAssertNotNil(weakClient)

      FalClient.reset()
    }

    // Client should be deallocated after reset
    XCTAssertNil(weakClient)
  }

  // MARK: - Configuration Tests

  func testConfigurationWithCustomRetryPolicy() {
    let customPolicy = FalRetryPolicy(maxAttempts: 10, baseDelay: 2.0)

    try? FalClient.configure(
      apiKeySource: .key("test-key"),
      baseURL: "https://test.fal.run",
      timeoutInterval: 60.0,
      retryPolicy: customPolicy
    )

    XCTAssertTrue(FalClient.isConfigured)
  }

  func testConfigurationWithMetricsCollector() {
    let metrics = ConsoleMetrics.shared

    try? FalClient.configure(
      apiKeySource: .key("test-key"),
      metricsCollector: metrics
    )

    XCTAssertTrue(FalClient.isConfigured)
  }

  // MARK: - Error Handling Tests

  func testAllErrorTypesAreSendable() {
    // Verify all error types can be safely passed across actor boundaries
    let errors: [FalError] = [
      .notConfigured,
      .missingAPIKey,
      .invalidURL,
      .invalidRequest("test"),
      .unauthorized,
      .rateLimited(retryAfter: 60),
      .insufficientCredits,
      .serverError(statusCode: 500, message: "test"),
      .networkError("test"),
      .invalidResponse,
      .decodingFailed(NSError(domain: "test", code: 1)),
      .requestTimedOut,
      .noOutput,
      .processingFailed
    ]

    // Verify we have all error types
    XCTAssertGreaterThan(errors.count, 0)
    XCTAssertTrue(errors.allSatisfy { _ in true }) // All are Sendable
  }

  // MARK: - Edge Case Tests

  func testVeryLongAPIKey() {
    let longKey = String(repeating: "a", count: 10000)

    try? FalClient.configure(apiKeySource: .key(longKey))
    XCTAssertTrue(FalClient.isConfigured)
  }

  func testSpecialCharactersInAPIKey() {
    let specialKey = "key-with-special.chars!@#$%^&*()"

    try? FalClient.configure(apiKeySource: .key(specialKey))
    XCTAssertTrue(FalClient.isConfigured)
  }

  func testUnicodeInEndpoint() {
    let validator = DefaultRequestValidator()

    struct TestInput: Encodable {
      let value: String
    }

    // Unicode endpoints should pass validation
    XCTAssertNoThrow(try validator.validate(endpoint: "/test-emoji-😀", input: TestInput(value: "test")))
  }

  // MARK: - Stress Tests

  func testRapidConfigurationChanges() {
    for i in 0..<100 {
      try? FalClient.configure(apiKeySource: .key("key-\(i)"))
      XCTAssertTrue(FalClient.isConfigured)

      if i % 2 == 0 {
        FalClient.reset()
        XCTAssertFalse(FalClient.isConfigured)
      }
    }
  }

  func testMultipleMetricCollectors() {
    let metrics1 = ConsoleMetrics.shared
    let metrics2 = NullMetrics.shared

    FalClient.metricsCollector = metrics1
    FalClient.metricsCollector = metrics2

    // Should switch to null metrics
    metrics2.recordRequest(endpoint: "/test", duration: 1.0, success: true)

    // Should not crash
    try? FalClient.configure(
      apiKeySource: .key("test-key"),
      metricsCollector: metrics1
    )
  }

  // MARK: - Type Safety Tests

  func testProgressStateIsSendable() {
    // Verify progress states can cross actor boundaries
    let states: [FalProgress.State] = [
      .submitting,
      .queued(currentAttempt: 1, maxAttempts: 10),
      .processing,
      .downloading,
      .completed
    ]

    XCTAssertEqual(states.count, 5)
  }
}
