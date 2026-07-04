import Foundation

// MARK: - Fal Queue Models

/// Response from submitting a job to Fal's queue. When `requestId` and
/// `statusURL` are present the job is asynchronous and must be polled;
/// otherwise the endpoint returned its output synchronously.
public struct FalQueueResponse: Decodable, Sendable {
  public let requestId: String?
  public let statusURL: String?
  public let responseURL: String?

  enum CodingKeys: String, CodingKey {
    case requestId = "request_id"
    case statusURL = "status_url"
    case responseURL = "response_url"
  }

  public var isQueued: Bool {
    guard let id = requestId, !id.isEmpty, let status = statusURL, !status.isEmpty else {
      return false
    }
    return true
  }
}

/// Status of a queued Fal job.
public struct FalStatusResponse: Decodable, Sendable {
  public let status: String

  public var state: FalStatus {
    switch status.uppercased() {
    case "COMPLETED": return .completed
    case "FAILED": return .failed
    case "IN_PROGRESS": return .inProgress
    case "IN_QUEUE": return .inQueue
    default: return .unknown
    }
  }
}

public enum FalStatus: Sendable {
  case inQueue
  case inProgress
  case completed
  case failed
  case unknown
}

// MARK: - Image Output

/// A Fal model output that may surface its image(s) under `image`, `images`,
/// or a bare `url`. Used by the common image endpoints (bg removal, upscale,
/// style transfer, object removal, img2img).
public struct FalImageOutput: Decodable, Sendable {
  public let image: FalAsset?
  public let images: [FalAsset]?
  public let url: String?

  /// First available image URL across the known shapes.
  public var firstImageURL: String? {
    image?.url ?? images?.first?.url ?? url
  }
}

public struct FalAsset: Decodable, Sendable {
  public let url: String
}

// MARK: - Common Input Payloads

/// Input for image-in / image-out endpoints that take a single source image
/// (remove-background, upscaler, img2img, object-removal).
public struct FalImageInput: Encodable, Sendable {
  public let imageURL: String
  public let outputBackground: String?
  public let scale: Int?
  public let prompt: String?
  public let strength: Double?
  public let maskPrompt: String?
  public let numImages: Int?

  public init(
    imageURL: String,
    outputBackground: String? = nil,
    scale: Int? = nil,
    prompt: String? = nil,
    strength: Double? = nil,
    maskPrompt: String? = nil,
    numImages: Int? = nil
  ) {
    self.imageURL = imageURL
    self.outputBackground = outputBackground
    self.scale = scale
    self.prompt = prompt
    self.strength = strength
    self.maskPrompt = maskPrompt
    self.numImages = numImages
  }

  enum CodingKeys: String, CodingKey {
    case imageURL = "image_url"
    case outputBackground = "output_background"
    case scale
    case prompt
    case strength
    case maskPrompt = "mask_prompt"
    case numImages = "num_images"
  }
}

/// Input for style transfer.
public struct FalStyleTransferInput: Encodable, Sendable {
  public let imageURL: String
  public let style: String
  public let intensity: Double

  public init(imageURL: String, style: String, intensity: Double = 0.75) {
    self.imageURL = imageURL
    self.style = style
    self.intensity = intensity
  }

  enum CodingKeys: String, CodingKey {
    case imageURL = "image_url"
    case style, intensity
  }
}

// MARK: - Image Data URL Helper

/// Builds Fal-compatible `data:` URLs for submitting an image inline without
/// a separate upload. Keep image-side concerns (UIImage) in the host app;
/// this only formats raw JPEG/PNG `Data`.
public enum FalDataURL {
  public static func jpeg(_ data: Data) -> String {
    "data:image/jpeg;base64," + data.base64EncodedString()
  }

  public static func png(_ data: Data) -> String {
    "data:image/png;base64," + data.base64EncodedString()
  }
}
