import Foundation
import AppKit

/// Host-independent image cache manager (Host-Independent Image Cache).
///
/// Design:
/// "The image cache key must not include the host, so cached images survive
/// a switch between local and remote addresses."
///
/// Ce cache combine :
/// 1. A fast memory cache (`NSCache<NSString, NSImage>`) with cost and item limits.
/// 2. A persistent disk cache in `~/Library/Caches/<bundle identifier>/images-v2/`.
/// 3. De-duplication of in-flight network requests to avoid downloading the same resource several times.
public final class ImageCache: @unchecked Sendable {
    public static let shared = ImageCache()

    // MARK: - Properties

    private let memoryCache = NSCache<NSString, NSImage>()
    public let diskCacheURL: URL
    private let fileManager = FileManager.default
    private let lock = NSLock()
    /// `waiters`: number of callers still waiting for this image. The download is only cancelled
    /// when all of them have given up (a card scrolling off screen must not deprive the others).
    private struct InFlight {
        let id: UUID
        let task: Task<NSImage?, Error>
        var waiters: Int
    }
    private var inFlightTasks: [String: InFlight] = [:]
    /// Dedicated session without URL cache: images already have their own disk cache, no need to store them twice.
    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: config)
    }()

    // MARK: - Initialisation

    public init(diskCacheURL: URL? = nil, countLimit: Int = 500, totalCostLimitBytes: Int = 150 * 1024 * 1024, diskLimitBytes: Int = 1024 * 1024 * 1024) {
        if let diskCacheURL {
            self.diskCacheURL = diskCacheURL
        } else {
            let root = AppPaths.cachesDirectory
            // Old folder (keys without a tag, shared with URLCache): purged, it is no longer used.
            try? FileManager.default.removeItem(at: root.appendingPathComponent("images", isDirectory: true))
            self.diskCacheURL = root.appendingPathComponent("images-v2", isDirectory: true)
        }

        memoryCache.countLimit = countLimit
        memoryCache.totalCostLimit = totalCostLimitBytes

        // Creation of the disk cache directory if it does not exist
        try? fileManager.createDirectory(at: self.diskCacheURL, withIntermediateDirectories: true)

        // The disk cache does not grow without limit: the oldest files beyond the ceiling are deleted.
        let directory = self.diskCacheURL
        let limit = diskLimitBytes
        DispatchQueue.global(qos: .utility).async { Self.trimDiskCache(at: directory, maxBytes: limit) }
    }

    /// Deletes the least recently modified files until the size is back under `maxBytes`.
    static func trimDiskCache(at directory: URL, maxBytes: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: .skipsHiddenFiles
        ) else { return }
        var entries: [(url: URL, size: Int, date: Date)] = files.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), let size = values.fileSize else { return nil }
            return (url, size, values.contentModificationDate ?? .distantPast)
        }
        var total = entries.reduce(0) { $0 + $1.size }
        guard total > maxBytes else { return }
        entries.sort { $0.date < $1.date }
        for entry in entries where total > maxBytes {
            if (try? FileManager.default.removeItem(at: entry.url)) != nil { total -= entry.size }
        }
    }

    // MARK: - Generation of host-independent cache keys

    /// Generates a normalised cache key from the identifier, image type, tag and dimensions.
    /// Format: `"<itemId>_<kind>_<tag>_<maxHeight>_<maxWidth>"` (the tag changes when the image changes on the server).
    public static func cacheKey(
        itemId: String,
        kind: ImageKind,
        tag: String? = nil,
        maxHeight: UInt32? = nil,
        maxWidth: UInt32? = nil
    ) -> String {
        let kindStr: String
        switch kind {
        case .primary: kindStr = "primary"
        case .backdrop: kindStr = "backdrop"
        case .logo: kindStr = "logo"
        }
        return cacheKey(itemId: itemId, kind: kindStr, tag: tag, maxHeight: maxHeight, maxWidth: maxWidth)
    }

    /// Generates a cache key from a textual type.
    public static func cacheKey(
        itemId: String,
        kind: String,
        tag: String? = nil,
        maxHeight: UInt32? = nil,
        maxWidth: UInt32? = nil
    ) -> String {
        let h = maxHeight.map { String($0) } ?? "0"
        let w = maxWidth.map { String($0) } ?? "0"
        let t = tag.flatMap { $0.isEmpty ? nil : $0 } ?? "0"
        return "\(itemId)_\(kind.lowercased())_\(t)_\(h)_\(w)"
    }

    /// Generates a host-independent cache key from a Jellyfin URL.
    ///
    /// Whether the URL comes from a local address (`http://192.0.2.10:8096/...`) or a remote one (`https://jellyfin.example.com/...`),
    /// the resulting key is strictly identical.
    public static func cacheKey(for url: URL) -> String {
        let pathComponents = url.pathComponents
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)

        // Structure standard Jellyfin : /Items/{itemId}/Images/{kind}
        if let itemsIdx = pathComponents.firstIndex(of: "Items"),
           itemsIdx + 3 < pathComponents.count,
           pathComponents[itemsIdx + 2].caseInsensitiveCompare("images") == .orderedSame {
            let itemId = pathComponents[itemsIdx + 1]
            let kind = pathComponents[itemsIdx + 3].lowercased()
            let maxHeight = components?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("maxHeight") == .orderedSame })?.value.flatMap { UInt32($0) }
            let maxWidth = components?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("maxWidth") == .orderedSame })?.value.flatMap { UInt32($0) }
            let tag = components?.queryItems?.first(where: { $0.name.caseInsensitiveCompare("tag") == .orderedSame })?.value
            return cacheKey(itemId: itemId, kind: kind, tag: tag, maxHeight: maxHeight, maxWidth: maxWidth)
        }

        // Structure for avatars or other Jellyfin resources
        let path = url.path
        let query = components?.percentEncodedQuery ?? ""
        let relative = query.isEmpty ? path : "\(path)?\(query)"

        // Sanitised key based on the relative path
        let sanitized = relative.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return sanitized.isEmpty ? "unknown_image" : sanitized
    }

    public func cacheKey(itemId: String, kind: ImageKind, tag: String? = nil, maxHeight: UInt32? = nil, maxWidth: UInt32? = nil) -> String {
        Self.cacheKey(itemId: itemId, kind: kind, tag: tag, maxHeight: maxHeight, maxWidth: maxWidth)
    }

    public func cacheKey(for url: URL) -> String {
        Self.cacheKey(for: url)
    }

    // MARK: - Cache access

    /// Looks for an image in memory first, then on disk.
    /// If the image is found on disk, it is loaded back into memory.
    public func image(forKey key: String) -> NSImage? {
        // 1. Memory
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // 2. Disque
        let file = fileURL(forKey: key)
        guard fileManager.fileExists(atPath: file.path),
              let data = try? Data(contentsOf: file),
              let decoded = Self.decode(data) else {
            return nil
        }

        // Store in memory for later accesses
        let cost = calculateCost(for: decoded)
        memoryCache.setObject(decoded, forKey: key as NSString, cost: cost)
        return decoded
    }

    /// Purely synchronous memory lookup (avoids any blocking I/O on the main thread).
    public func memoryImage(forKey key: String) -> NSImage? {
        memoryCache.object(forKey: key as NSString)
    }

    /// Saves an image and its raw bytes in memory and on disk.
    public func store(image: NSImage, data: Data, forKey key: String) {
        let cost = calculateCost(for: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        let file = fileURL(forKey: key)
        try? data.write(to: file, options: .atomic)
    }

    /// Saves an image in memory and compresses it to PNG for the disk write.
    public func store(image: NSImage, forKey key: String) {
        let cost = calculateCost(for: image)
        memoryCache.setObject(image, forKey: key as NSString, cost: cost)

        if let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            let file = fileURL(forKey: key)
            try? png.write(to: file, options: .atomic)
        }
    }

    /// Loads an image asynchronously (Memory -> Disk -> Network).
    /// Decodes the image off the main thread and shares concurrent requests.
    public func loadImage(forKey key: String, from url: URL?) async throws -> NSImage? {
        // 1. Memory (instant)
        if let cached = memoryCache.object(forKey: key as NSString) {
            return cached
        }

        // 2. Atomic de-duplication: join the running task or create one
        let (task, taskId): (Task<NSImage?, Error>, UUID) = lock.withLock {
            if var existing = inFlightTasks[key] {
                existing.waiters += 1
                inFlightTasks[key] = existing
                return (existing.task, existing.id)
            }

            let id = UUID()
            let newTask = Task<NSImage?, Error>.detached(priority: .userInitiated) { [weak self] () -> NSImage? in
                guard let self else { return nil }
                // The task removes itself from the table when done: the caller that started it may have given up.
                defer {
                    self.lock.withLock {
                        if self.inFlightTasks[key]?.id == id { self.inFlightTasks.removeValue(forKey: key) }
                    }
                }

                // Disk check off the main thread
                let file = self.fileURL(forKey: key)
                if self.fileManager.fileExists(atPath: file.path),
                   let data = try? Data(contentsOf: file),
                   let diskImage = Self.decode(data) {
                    self.memoryCache.setObject(diskImage, forKey: key as NSString, cost: self.calculateCost(for: diskImage))
                    return diskImage
                }

                // Network download if a URL is provided
                guard let url else { return nil }
                let (data, response) = try await self.session.data(from: url)
                guard let httpResponse = response as? HTTPURLResponse else { return nil }
                // Server overloaded or busy: worth trying again (see `ImageRetry`). Any other refusal
                // (404: no image of this kind) is final.
                if ImageRetry.isTransient(status: httpResponse.statusCode) {
                    throw ImageRetry.TransientError(status: httpResponse.statusCode)
                }
                guard (200...299).contains(httpResponse.statusCode) else { return nil }
                try Task.checkCancellation()

                guard let downloadedImage = Self.decode(data) else { return nil }
                self.store(image: downloadedImage, data: data, forKey: key)
                return downloadedImage
            }

            inFlightTasks[key] = InFlight(id: id, task: newTask, waiters: 1)
            return (newTask, id)
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            lock.withLock {
                guard var entry = inFlightTasks[key], entry.id == taskId else { return }
                entry.waiters -= 1
                if entry.waiters <= 0 {
                    inFlightTasks.removeValue(forKey: key)
                    entry.task.cancel()
                } else {
                    inFlightTasks[key] = entry
                }
            }
        }
    }

    /// Decodes the image at its useful size (at most 2000 px) right now, hence off the main thread,
    /// instead of letting SwiftUI do it at display time.
    static func decode(_ data: Data, maxPixelSize: Int = 2000) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        // Keeps the point size of the original image (a 60 px "@2x" image is 30 pt), like `NSImage(data:)`.
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let dpi = (properties?[kCGImagePropertyDPIWidth] as? Double) ?? 72
        let scale = dpi > 0 ? dpi / 72.0 : 1.0
        return NSImage(cgImage: cgImage, size: NSSize(width: Double(cgImage.width) / scale, height: Double(cgImage.height) / scale))
    }

    // MARK: - Cleanup and metrics

    /// Empties the memory cache.
    public func clearMemoryCache() {
        memoryCache.removeAllObjects()
    }

    /// Empties the disk cache as well as the memory cache.
    public func clearDiskCache() {
        clearMemoryCache()
        try? fileManager.removeItem(at: diskCacheURL)
        try? fileManager.createDirectory(at: diskCacheURL, withIntermediateDirectories: true)
    }

    /// Applies the disk cache ceiling ("Storage" setting): deletes the oldest files beyond it.
    public func applyDiskLimit(megabytes: Int) {
        let directory = diskCacheURL
        let limit = megabytes * 1024 * 1024
        DispatchQueue.global(qos: .utility).async { Self.trimDiskCache(at: directory, maxBytes: limit) }
    }

    /// Total size occupied on disk by the images, in bytes.
    public func diskCacheSize() -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: diskCacheURL,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    // MARK: - Utilitaires internes

    private func fileURL(forKey key: String) -> URL {
        let sanitized = key.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" ? String($0) : "_" }.joined()
        return diskCacheURL.appendingPathComponent("\(sanitized).img")
    }

    /// Decoded size in bytes, from the pixels: `image.size` is in points, smaller than the pixels for an
    /// image above 72 dpi (the memory ceiling was then exceeded without the cache seeing it).
    private func calculateCost(for image: NSImage) -> Int {
        if let rep = image.representations.first, rep.pixelsWide > 0, rep.pixelsHigh > 0 {
            return rep.pixelsWide * rep.pixelsHigh * 4
        }
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 1024 }
        return Int(size.width * size.height * 4)
    }
}

/// When a failed image is tried again: only after a passing problem (slow or lost network, busy server),
/// never after a cancellation (card scrolled away) or a missing image.
enum ImageRetry {
    /// Waits before the 2nd and 3rd attempts.
    static let delays: [Duration] = [.seconds(1), .seconds(3)]

    struct TransientError: Error { let status: Int }

    static func isTransient(status: Int) -> Bool {
        status == 408 || status == 429 || (500...599).contains(status)
    }

    static func shouldRetry(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if error is TransientError { return true }
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .resourceUnavailable, .badServerResponse:
            return true
        default:
            return false
        }
    }
}
