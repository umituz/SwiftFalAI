import Foundation

// MARK: - Fal Error

/// Typed errors for the Fal client. Mirrors the `SwiftGroq` error surface
/// (LocalizedError + Sendable, with `errorDescription`, `recoverySuggestion`,
/// `isRetryable`, and `isConfigurationError`).
public enum FalError: LocalizedError, Sendable {
  case notConfigured
  case missingAPIKey
  case invalidURL
  case invalidRequest(String)
  case unauthorized
  case rateLimited(retryAfter: Int?)
  case insufficientCredits
  case serverError(statusCode: Int, message: String?)
  case networkError(String)
  case invalidResponse
  case decodingFailed(Error)
  case requestTimedOut
  case noOutput
  case processingFailed

  public var errorDescription: String? {
    switch self {
    case .notConfigured:
      return "FalClient has not been configured."
    case .missingAPIKey:
      return "Fal API key is not configured."
    case .invalidURL:
      return "Invalid Fal API URL."
    case .invalidRequest(let reason):
      return "Invalid request: \(reason)"
    case .unauthorized:
      return "Invalid Fal API key. Check your key at fal.ai/dashboard."
    case .rateLimited:
      return "Rate limit reached. Please try again in a moment."
    case .insufficientCredits:
      return "Fal credits exhausted. Check your balance at fal.ai/dashboard."
    case .serverError(let code, let message):
      if let message {
        return "Fal server error (HTTP \(code)): \(message)"
      }
      return "Fal server error (HTTP \(code)). The service may be temporarily unavailable."
    case .networkError(let description):
      return "Network error: \(description)"
    case .invalidResponse:
      return "Invalid response from Fal."
    case .decodingFailed(let error):
      return "Failed to decode Fal response: \(error.localizedDescription)"
    case .requestTimedOut:
      return "Fal request timed out before completion."
    case .noOutput:
      return "Fal returned no image/video output."
    case .processingFailed:
      return "Fal failed to process the request."
    }
  }

  public var recoverySuggestion: String? {
    switch self {
    case .notConfigured:
      return "Call FalClient.configure() before making requests."
    case .missingAPIKey:
      return "Provision the Fal key in the Keychain and configure FalClient before making requests."
    case .unauthorized, .insufficientCredits:
      return "Verify your key and balance at fal.ai/dashboard."
    case .rateLimited(let retryAfter):
      if let seconds = retryAfter {
        return "Wait \(seconds) seconds before retrying."
      }
      return "Wait a moment before retrying."
    case .serverError, .processingFailed:
      return "This is a server-side issue. Try again later."
    case .networkError, .requestTimedOut:
      return "Check your internet connection and try again."
    case .invalidResponse, .decodingFailed:
      return "The Fal response format was unexpected. Try again."
    case .invalidURL, .invalidRequest, .noOutput:
      return nil
    }
  }

  public var isRetryable: Bool {
    switch self {
    case .rateLimited, .serverError, .networkError, .requestTimedOut, .processingFailed:
      return true
    case .notConfigured, .missingAPIKey, .invalidURL, .invalidRequest,
      .unauthorized, .insufficientCredits, .invalidResponse,
      .decodingFailed, .noOutput:
      return false
    }
  }

  public var isConfigurationError: Bool {
    switch self {
    case .notConfigured, .missingAPIKey, .unauthorized, .insufficientCredits:
      return true
    default:
      return false
    }
  }
}
