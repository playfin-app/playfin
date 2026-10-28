import XCTest
import SwiftUI
import AppKit
@testable import Playfin

@MainActor
final class AsyncArtworkTests: XCTestCase {
    private let url = URL(string: "http://192.168.1.100:8096/Items/item-art/Images/Primary?maxHeight=450&tag=t1")!

    func testBlurHashSizesAreKept() {
        let poster = AsyncArtwork(url: url, blurHash: "LEHLh[WB2yk8pyoJadR*.7kCMdnj", targetBlurHashSize: CGSize(width: 32, height: 48), contentMode: .fill)
        XCTAssertEqual(poster.targetBlurHashSize, CGSize(width: 32, height: 48))
        let backdrop = AsyncArtwork(url: url, blurHash: nil, targetBlurHashSize: CGSize(width: 64, height: 36), contentMode: .fill)
        XCTAssertEqual(backdrop.targetBlurHashSize, CGSize(width: 64, height: 36))
    }

    func testAlignmentDefaultsToCenterAndCanBeChanged() {
        let artwork = AsyncArtwork(url: nil, blurHash: nil, contentMode: .fit) { Color.red }
        XCTAssertEqual(artwork.alignment, .center)
        XCTAssertEqual(artwork.artworkAlignment(.leading).alignment, .leading, "a logo aligns left with the text")
        XCTAssertEqual(artwork.alignment, .center, "the original is not modified")
    }

    func testAnImageAlreadyInMemoryIsUsedWithoutPlaceholder() {
        // The memory cache is queried with the host-independent key (tag included).
        let key = ImageCache.shared.cacheKey(for: url)
        let image = NSImage(size: NSSize(width: 4, height: 4))
        ImageCache.shared.store(image: image, forKey: key)
        XCTAssertNotNil(ImageCache.shared.memoryImage(forKey: key))
        let other = URL(string: "https://remote.example.com/Items/item-art/Images/Primary?maxHeight=450&tag=t1")!
        XCTAssertEqual(ImageCache.shared.cacheKey(for: other), key, "same image, other server address: same entry")
        let changed = URL(string: "http://192.168.1.100:8096/Items/item-art/Images/Primary?maxHeight=450&tag=t2")!
        XCTAssertNil(ImageCache.shared.memoryImage(forKey: ImageCache.shared.cacheKey(for: changed)), "new tag: no old image")
    }
}
