import XCTest
@testable import SwiftFalAI

final class SwiftFalAITests: XCTestCase {

    // MARK: - Configuration

    func testIsConfiguredIsFalseBeforeConfigure() {
        FalClient.reset()
        XCTAssertFalse(FalClient.isConfigured)
    }

    func testConfigureWithEmptyKeyThrows() {
        FalClient.reset()
        XCTAssertThrowsError(try FalClient.configure(apiKeySource: .key(""))) { error in
            guard let falError = error as? FalError, case .missingAPIKey = falError else {
                XCTFail("Expected missingAPIKey, got \(error)")
                return
            }
        }
    }

    func testConfigureWithKeySucceeds() {
        FalClient.reset()
        XCTAssertNoThrow(try FalClient.configure(apiKeySource: .key("test-key")))
        XCTAssertTrue(FalClient.isConfigured)
        FalClient.reset()
    }

    func testConfiguredThrowsBeforeConfigure() {
        FalClient.reset()
        XCTAssertThrowsError(try FalClient.configured()) { error in
            guard let falError = error as? FalError, case .notConfigured = falError else {
                XCTFail("Expected notConfigured, got \(error)")
                return
            }
        }
    }

    // MARK: - Models

    func testFalQueueResponseIsQueuedWhenRequestIDAndStatusPresent() throws {
        let json = #"{"request_id":"abc","status_url":"https://queue.fal.run/x/status","response_url":"https://queue.fal.run/x"}"#
        let response = try JSONDecoder().decode(FalQueueResponse.self, from: json.data(using: .utf8)!)
        XCTAssertTrue(response.isQueued)
        XCTAssertEqual(response.requestId, "abc")
    }

    func testFalQueueResponseIsNotQueuedWhenMissingRequestID() throws {
        let json = #"{"image":{"url":"https://cdn.fal.run/a.png"}}"#
        let response = try JSONDecoder().decode(FalQueueResponse.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(response.isQueued)
    }

    func testFalStatusMapsKnownValues() throws {
        func decode(_ raw: String) throws -> FalStatus {
            let json = #"{"status":"\#(raw)"}"#
            return try JSONDecoder().decode(FalStatusResponse.self, from: json.data(using: .utf8)!).state
        }
        XCTAssertEqual(try decode("COMPLETED"), .completed)
        XCTAssertEqual(try decode("IN_PROGRESS"), .inProgress)
        XCTAssertEqual(try decode("IN_QUEUE"), .inQueue)
        XCTAssertEqual(try decode("FAILED"), .failed)
        XCTAssertEqual(try decode("GARBAGE"), .unknown)
    }

    func testFalImageOutputPicksFirstAvailableURL() throws {
        let json = #"{"image":{"url":"https://cdn.fal.run/a.png"}}"#
        let out = try JSONDecoder().decode(FalImageOutput.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(out.firstImageURL, "https://cdn.fal.run/a.png")

        let jsonImages = #"{"images":[{"url":"https://cdn.fal.run/b.png"}]}"#
        let outImages = try JSONDecoder().decode(FalImageOutput.self, from: jsonImages.data(using: .utf8)!)
        XCTAssertEqual(outImages.firstImageURL, "https://cdn.fal.run/b.png")
    }

    func testFalDataURLFormatsBase64() {
        let data = Data([0xFF, 0xD8, 0xFF])
        XCTAssertTrue(FalDataURL.jpeg(data).hasPrefix("data:image/jpeg;base64,"))
        XCTAssertTrue(FalDataURL.png(data).hasPrefix("data:image/png;base64,"))
    }

    // MARK: - Error

    func testErrorIsRetryableClassification() {
        XCTAssertTrue(FalError.serverError(statusCode: 500, message: nil).isRetryable)
        XCTAssertTrue(FalError.requestTimedOut.isRetryable)
        XCTAssertFalse(FalError.unauthorized.isRetryable)
        XCTAssertFalse(FalError.missingAPIKey.isRetryable)
    }

    func testErrorIsConfigurationErrorClassification() {
        XCTAssertTrue(FalError.unauthorized.isConfigurationError)
        XCTAssertTrue(FalError.insufficientCredits.isConfigurationError)
        XCTAssertFalse(FalError.serverError(statusCode: 500, message: nil).isConfigurationError)
    }
}
