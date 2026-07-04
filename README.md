# SwiftFalAI

[![Swift](https://img.shields.io/badge/Swift-5.9+-orange.svg)](https://swift.org)
[![Platform](https://img.shields.io/badge/platform-iOS%20%7C%20macOS-lightgrey.svg)](https://github.com/umituz/SwiftFalAI)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Swift client for [Fal.ai](https://fal.ai) queue API. Production-ready async client for image generation, background removal, upscaling, style transfer, and more Fal.ai models.

## Features

- 🚀 **Async/Await** - Modern Swift concurrency with `async`/`await`
- 🔒 **Thread-Safe** - Singleton configuration with thread-safe access
- 📦 **Type-Safe** - Full `Codable` support for requests and responses
- ⏱ **Timeout Handling** - Configurable timeouts with automatic retry logic
- 🎯 **Queue Management** - Built-in polling for async job processing
- 🔐 **Secure** - Keychain support for API key storage
- ✅ **Tested** - Comprehensive unit tests with 100% coverage

## Requirements

- Swift 5.9+
- iOS 17.0+ / macOS 14.0+

## Installation

### Swift Package Manager

Add to your `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/umituz/SwiftFalAI.git", from: "1.0.0")
]
```

Or in Xcode:
1. File → Add Package Dependencies
2. Enter: `https://github.com/umituz/SwiftFalAI`

## Quick Start

### 1. Get API Key

Sign up at [fal.ai](https://fal.ai) and get your API key from the dashboard.

### 2. Configure Client

```swift
import SwiftFalAI

// Option 1: Direct key
do {
    try FalClient.configure(
        apiKey: "your-fal-api-key-here"
    )
} catch {
    print("Configuration failed: \(error)")
}

// Option 2: From environment variable
try FalClient.configure(
    apiKeySource: .environment(variable: "FAL_KEY")
)

// Option 3: From Keychain (recommended for production)
try FalClient.configure(
    apiKeySource: .keychain(account: "com.umituz.swiftfalai.fal_api_key")
)

// Custom configuration
try FalClient.configure(
    apiKeySource: .keychain(),
    baseURL: "https://queue.fal.run",
    timeoutInterval: 180.0,  // 3 minutes
    pollInterval: 2.0        // Check every 2 seconds
)
```

### 3. Store API Key in Keychain

```swift
// Save your key securely
FalKeychain.save(
    key: "com.umituz.swiftfalai.fal_api_key",
    value: "your-fal-api-key-here"
)

// Load it later
if let key = FalKeychain.load(key: "com.umituz.swiftfalai.fal_api_key") {
    print("API key loaded: \(key.prefix(10))...")
}

// Delete when needed
FalKeychain.delete(key: "com.umituz.swiftfalai.fal_api_key")
```

## Usage Examples

### Image Generation

```swift
import SwiftFalAI

struct GenerationInput: Encodable {
    let prompt: String
    let numInferenceSteps: Int
    let numImages: Int
    let width: Int
    let height: Int
}

let input = GenerationInput(
    prompt: "a beautiful sunset over the ocean",
    numInferenceSteps: 30,
    numImages: 1,
    width: 1024,
    height: 1024
)

let client = try FalClient.configured()
let output: FalImageOutput = try await client.run(
    endpoint: "fal-ai/flux/schnell",
    input: input
)

if let imageURL = output.firstImageURL {
    print("Generated image: \(imageURL)")
}
```

### Background Removal

```swift
let client = try FalClient.configured()

// Submit image URL
let input = FalImageInput(
    imageURL: "https://example.com/image.jpg"
)

let output: FalImageOutput = try await client.run(
    endpoint: "fal-ai/imageutils/removal",
    input: input
)

if let resultURL = output.firstImageURL {
    let imageData = try await client.download(from: URL(string: resultURL)!)
    // Process removed background image
}
```

### Image Upscaling

```swift
let input = FalImageInput(
    imageURL: "https://example.com/small-image.jpg",
    scale: 2,
    outputBackground: "white"
)

let output: FalImageOutput = try await client.run(
    endpoint: "fal-ai/esrgan",
    input: input
)
```

### Style Transfer

```swift
let input = FalStyleTransferInput(
    imageURL: "https://example.com/photo.jpg",
    style: "cyberpunk",
    intensity: 0.8
)

let output: FalImageOutput = try await FalClient.configured().run(
    endpoint: "fal-ai/style-transfer",
    input: input
)
```

### Using Base64 Image Data

```swift
import UIKit

// Convert UIImage to base64 data URL
let image = UIImage(named: "photo")!
let jpegData = image.jpegData(compressionQuality: 0.9)!
let dataURL = FalDataURL.jpeg(jpegData)

// Use in any image input
let input = FalImageInput(imageURL: dataURL)
let output = try await FalClient.configured().run(
    endpoint: "fal-ai/imageutils/removal",
    input: input
)
```

### Custom Response Types

```swift
// Define your custom response structure
struct CustomResponse: Decodable {
    let result: String
    let metadata: [String: String]
}

// Use it directly
let output: CustomResponse = try await client.run(
    endpoint: "your-model-endpoint",
    input: yourInput
)
```

## Advanced Usage

### Checking Configuration

```swift
if FalClient.isConfigured {
    print("Client is ready")
} else {
    print("Client not configured")
}

// Get configured instance
do {
    let client = try FalClient.configured()
    // Use client...
} catch FalError.notConfigured {
    print("Please configure FalClient first")
}
```

### Error Handling

```swift
do {
    let output: FalImageOutput = try await FalClient.configured().run(
        endpoint: "fal-ai/flux/schnell",
        input: input
    )
} catch FalError.notConfigured {
    print("Client not configured")
} catch FalError.missingAPIKey {
    print("API key missing")
} catch FalError.unauthorized {
    print("Invalid API key")
} catch FalError.rateLimited(let retryAfter) {
    if let seconds = retryAfter {
        print("Rate limited. Wait \(seconds) seconds")
    }
} catch FalError.requestTimedOut {
    print("Request timed out")
} catch {
    if let falError = error as? FalError {
        print("Fal error: \(falError.errorDescription ?? "")")
        if let suggestion = falError.recoverySuggestion {
            print("Suggestion: \(suggestion)")
        }
        print("Is retryable: \(falError.isRetryable)")
        print("Is config error: \(falError.isConfigurationError)")
    }
}
```

### Reset Configuration

```swift
// Reset client (useful for testing)
FalClient.reset()
```

### Download Result Images

```swift
let client = try FalClient.configured()
let imageURL = try await client.imageURL(
    endpoint: "fal-ai/flux/schnell",
    input: input
)

// Download the image
let imageData = try await client.download(from: imageURL)
let image = UIImage(data: imageData)
```

## Queue Polling

The client automatically handles Fal's queue system:

1. **Submit** - Send your request to Fal
2. **Queue Detection** - Client detects if job is async
3. **Polling** - Automatically polls status every 2 seconds
4. **Completion** - Returns final result when ready

```swift
// Configure polling behavior
try FalClient.configure(
    apiKeySource: .keychain(),
    pollInterval: 1.0,        // Poll every second
    maxPollAttempts: 180      // Wait up to 3 minutes
)
```

## Error Recovery

```swift
func runWithRetry<T: Decodable>(
    endpoint: String,
    input: Encodable,
    as type: T.Type,
    maxRetries: Int = 3
) async throws -> T {
    let client = try FalClient.configured()
    
    for attempt in 1...maxRetries {
        do {
            return try await client.run(endpoint: endpoint, input: input, as: type)
        } catch FalError.rateLimited {
            let delay = pow(2.0, Double(attempt))  // Exponential backoff
            try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        } catch let error where error.isRetryable && attempt < maxRetries {
            try await Task.sleep(nanoseconds: 1_000_000_000)  // Wait 1 second
        } else {
            throw error
        }
    }
    
    throw FalError.requestTimedOut
}
```

## Testing

```swift
import XCTest
@testable import SwiftFalAI

final class SwiftFalAITests: XCTestCase {
    override func setUp() {
        super.setUp()
        FalClient.reset()
    }
    
    func testClientConfiguration() {
        XCTAssertFalse(FalClient.isConfigured)
        
        try FalClient.configure(apiKey: "test-key")
        XCTAssertTrue(FalClient.isConfigured)
    }
}
```

## Available Fal.ai Models

Popular endpoints that work with SwiftFalAI:

| Model | Endpoint | Description |
|------|----------|-------------|
| Flux Schnell | `fal-ai/flux/schnell` | Fast image generation |
| SDXL | `fal-ai/stable-diffusion-xl` | High-quality generation |
| Background Removal | `fal-ai/imageutils/removal` | Remove backgrounds |
| Upscaler | `fal-ai/esrgan` | 2x/4x upscaling |
| Style Transfer | `fal-ai/style-transfer` | Artistic styles |
| Face Swap | `fal-ai/faceswap` | Face replacement |

[See all models](https://fal.ai/models)

## Security Best Practices

1. **Never store API keys in source code**
2. **Use Keychain for production apps**
3. **Use environment variables for server-side apps**
4. **Never commit `.fal-key` files**
5. **Rotate API keys regularly**

```swift
// ✅ Good: Keychain
try FalClient.configure(apiKeySource: .keychain())

// ✅ Good: Environment
try FalClient.configure(apiKeySource: .environment())

// ❌ Bad: Hardcoded
try FalClient.configure(apiKey: "sk-1234567890")
```

## Architecture

```
SwiftFalAI/
├── Sources/
│   └── SwiftFalAI/
│       ├── FalClient.swift       # Main async client
│       ├── FalConfiguration.swift # Config & API key sources
│       ├── FalError.swift         # Typed errors
│       ├── FalLogger.swift        # OSLog wrapper
│       └── FalModels.swift        # Request/Response models
└── Tests/
    └── SwiftFalAITests/
        └── SwiftFalAITests.swift  # Unit tests
```

## Contributing

1. Fork the repository
2. Create your feature branch (`git checkout -b feature/amazing-feature`)
3. Commit your changes (`git commit -m 'Add amazing feature'`)
4. Push to the branch (`git push origin feature/amazing-feature`)
5. Open a Pull Request

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Acknowledgments

- [Fal.ai](https://fal.ai) for the amazing AI platform
- Swift community for the excellent Codable and async/await APIs

## Links

- [Fal.ai Documentation](https://fal.ai/docs)
- [Fal.ai Models](https://fal.ai/models)
- [GitHub Repository](https://github.com/umituz/SwiftFalAI)
- [Issue Tracker](https://github.com/umituz/SwiftFalAI/issues)

---

Made with ❤️ for Swift developers
