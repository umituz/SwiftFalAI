import Foundation
import OSLog

/// Lightweight OSLog logger. Mirrors the `SwiftGroq` logger surface.
public final class FalLogger: @unchecked Sendable {
  public static let shared = FalLogger()

  private let logger = Logger(subsystem: "com.umituz.swiftfalai", category: "FalClient")

  private init() {}

  public func debug(_ message: String) { logger.debug("\(message, privacy: .public)") }
  public func info(_ message: String) { logger.info("\(message, privacy: .public)") }
  public func warning(_ message: String) { logger.warning("\(message, privacy: .public)") }
  public func error(_ message: String) { logger.error("\(message, privacy: .public)") }
}
