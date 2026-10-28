import XCTest
import AppKit
@testable import Playfin

final class ImageCacheTests: XCTestCase {
    private var tempDirectory: URL!
    private var cache: ImageCache!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ImageCacheTests_\(UUID().uuidString)")
        cache = ImageCache(diskCacheURL: tempDirectory)
    }

    override func tearDown() {
        cache.clearDiskCache()
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    func testHostIndependentCacheKeyFromComponents() {
        let keyPrimary = ImageCache.cacheKey(itemId: "movie-1", kind: .primary, maxHeight: 450, maxWidth: nil)
        XCTAssertEqual(keyPrimary, "movie-1_primary_0_450_0")

        let keyBackdrop = ImageCache.cacheKey(itemId: "movie-1", kind: .backdrop, maxHeight: 1080, maxWidth: 1920)
        XCTAssertEqual(keyBackdrop, "movie-1_backdrop_0_1080_1920")

        let keyLogo = ImageCache.cacheKey(itemId: "movie-1", kind: .logo, maxHeight: 320, maxWidth: nil)
        XCTAssertEqual(keyLogo, "movie-1_logo_0_320_0")
    }

    func testHostIndependentCacheKeyFromLocalAndRemoteURLs() {
        let localURL = URL(string: "http://192.168.1.100:8096/Items/movie-42/Images/Primary?maxHeight=450&quality=90")!
        let remoteURL = URL(string: "https://remote.example.com:8443/Items/movie-42/Images/Primary?maxHeight=450&quality=90")!

        let localKey = ImageCache.cacheKey(for: localURL)
        let remoteKey = ImageCache.cacheKey(for: remoteURL)

        XCTAssertEqual(localKey, "movie-42_primary_0_450_0")
        XCTAssertEqual(remoteKey, "movie-42_primary_0_450_0")
        XCTAssertEqual(localKey, remoteKey, "Local and remote URLs for the same resource must produce identical host-independent cache keys")
    }

    func testCacheKeyIncludesImageTag() {
        XCTAssertEqual(
            ImageCache.cacheKey(itemId: "m1", kind: .primary, tag: "abc", maxHeight: 450),
            "m1_primary_abc_450_0"
        )
        let local = URL(string: "http://192.0.2.1:8096/Items/m1/Images/Primary?maxHeight=450&quality=90&tag=abc")!
        let remote = URL(string: "https://jf.example.com/Items/m1/Images/Primary?maxHeight=450&quality=90&tag=abc")!
        XCTAssertEqual(ImageCache.cacheKey(for: local), "m1_primary_abc_450_0")
        XCTAssertEqual(ImageCache.cacheKey(for: local), ImageCache.cacheKey(for: remote))
        // A poster modified on the server (new tag) does not reuse the old entry.
        let changed = URL(string: "http://192.0.2.1:8096/Items/m1/Images/Primary?maxHeight=450&quality=90&tag=def")!
        XCTAssertNotEqual(ImageCache.cacheKey(for: local), ImageCache.cacheKey(for: changed))
    }

    func testHostIndependentCacheKeyForPersonImages() {
        let localURL = URL(string: "http://10.0.0.5:8096/Items/actor-99/Images/Primary?maxHeight=240")!
        let remoteURL = URL(string: "https://jellyfin.example.com/Items/actor-99/Images/Primary?maxHeight=240")!

        let localKey = ImageCache.cacheKey(for: localURL)
        let remoteKey = ImageCache.cacheKey(for: remoteURL)

        XCTAssertEqual(localKey, "actor-99_primary_0_240_0")
        XCTAssertEqual(remoteKey, "actor-99_primary_0_240_0")
        XCTAssertEqual(localKey, remoteKey)
    }

    func testMemoryCacheStoreAndRetrieve() {
        let testImage = makeTestImage(size: NSSize(width: 40, height: 40))
        let key = "test_memory_key"

        cache.store(image: testImage, forKey: key)

        let hit = cache.memoryImage(forKey: key)
        XCTAssertNotNil(hit)
        XCTAssertEqual(hit?.size, NSSize(width: 40, height: 40))

        cache.clearMemoryCache()
        XCTAssertNil(cache.memoryImage(forKey: key))
    }

    func testDiskCacheWriteReadAndClear() {
        let testImage = makeTestImage(size: NSSize(width: 30, height: 30))
        let key = "test_disk_key"
        guard let tiff = testImage.tiffRepresentation else {
            XCTFail("Failed to get TIFF representation")
            return
        }

        cache.store(image: testImage, data: tiff, forKey: key)

        // Empty the memory to force a disk read
        cache.clearMemoryCache()
        XCTAssertNil(cache.memoryImage(forKey: key), "Memory cache should be empty after clear")

        let loadedFromDisk = cache.image(forKey: key)
        XCTAssertNotNil(loadedFromDisk, "Image should be successfully restored from disk cache")
        XCTAssertEqual(loadedFromDisk?.size, NSSize(width: 30, height: 30))

        // Check that the disk cache size is greater than 0
        XCTAssertGreaterThan(cache.diskCacheSize(), 0)

        // Disk cleanup
        cache.clearDiskCache()
        XCTAssertEqual(cache.diskCacheSize(), 0)
        XCTAssertNil(cache.image(forKey: key), "Cache should return nil after clearing disk cache")
    }

    // MARK: - Helper

    private func makeTestImage(size: NSSize) -> NSImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.blue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        image.unlockFocus()
        return image
    }
}
