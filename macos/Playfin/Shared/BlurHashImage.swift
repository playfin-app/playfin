import Foundation
import AppKit
import CoreGraphics

/// Rendering of blurry BlurHash thumbnails (BlurHash Placeholder Rendering).
///
/// Decodes a Jellyfin BlurHash string into an `NSImage` via CoreGraphics
/// (`CGColorSpaceCreateDeviceRGB` and `CGDataProvider`).
/// The decoding itself is done by the Rust core; here we only do the display and the memory caching.

nonisolated(unsafe) private let blurHashCache: NSCache<NSString, NSImage> = {
    let cache = NSCache<NSString, NSImage>()
    cache.countLimit = 2500
    return cache
}()

/// Converts an array of raw RGBA bytes (32 bits) into an `NSImage`.
public func imageFromRGBA(bytes: [UInt8], width: Int, height: Int) -> NSImage? {
    guard width > 0, height > 0, bytes.count == width * height * 4 else {
        return nil
    }

    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    let cfData = Data(bytes) as CFData

    guard let provider = CGDataProvider(data: cfData) else {
        return nil
    }

    guard let cgImage = CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: bitmapInfo,
        provider: provider,
        decode: nil,
        shouldInterpolate: true,
        intent: .defaultIntent
    ) else {
        return nil
    }

    return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
}

/// Renders a BlurHash string into an `NSImage` of `width` × `height` dimensions.
///
/// The ideal dimensions for a BlurHash placeholder are between 16×16 and 48×48,
/// smooth resizing being handled by SwiftUI / CoreGraphics.
public func renderBlurHash(blurHash: String, width: Int = 32, height: Int = 32) -> NSImage? {
    guard !blurHash.isEmpty, width > 0, height > 0 else {
        return nil
    }

    // 1. Memory cache check
    let cacheKey = "\(blurHash)_\(width)_\(height)" as NSString
    if let cached = blurHashCache.object(forKey: cacheKey) {
        return cached
    }

    // 2. Decoding to RGBA bytes by the Rust core (the project's only decoder)
    guard let data = try? decodeBlurhash(blurHash: blurHash, width: UInt32(width), height: UInt32(height)),
          data.count == width * height * 4
    else {
        return nil
    }
    let rgbaBytes = [UInt8](data)

    // 3. Image creation
    guard let image = imageFromRGBA(bytes: rgbaBytes, width: width, height: height) else {
        return nil
    }

    // 4. Caching
    blurHashCache.setObject(image, forKey: cacheKey)
    return image
}

/// Namespace for BlurHash.
public enum BlurHashImage {
    public static func render(blurHash: String, width: Int = 32, height: Int = 32) -> NSImage? {
        renderBlurHash(blurHash: blurHash, width: width, height: height)
    }

    public static func image(fromRGBA bytes: [UInt8], width: Int, height: Int) -> NSImage? {
        imageFromRGBA(bytes: bytes, width: width, height: height)
    }
}
