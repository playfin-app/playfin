import XCTest
import AppKit
@testable import Playfin

final class BlurHashTests: XCTestCase {
    func testRenderValidBlurHash() {
        // Classic test BlurHash: sky and hills
        let blurHash = "LEHLh[WB2yk8pyoJadR*.7kCMdnj"
        let rendered = renderBlurHash(blurHash: blurHash, width: 32, height: 32)

        XCTAssertNotNil(rendered, "Valid BlurHash should render a non-nil NSImage")
        XCTAssertEqual(rendered?.size, NSSize(width: 32, height: 32))
    }

    func testRenderInvalidBlurHashReturnsNil() {
        XCTAssertNil(renderBlurHash(blurHash: "", width: 32, height: 32), "Empty string should return nil")
        XCTAssertNil(renderBlurHash(blurHash: "abc", width: 32, height: 32), "Short string (< 6 chars) should return nil")
        XCTAssertNil(renderBlurHash(blurHash: "invalid_character_!!!@@@", width: 32, height: 32), "Invalid characters should return nil")
        XCTAssertNil(renderBlurHash(blurHash: "LEHLh[WB2yk8pyoJadR*.7kCMdnj", width: 0, height: 32), "Zero width should return nil")
        XCTAssertNil(renderBlurHash(blurHash: "LEHLh[WB2yk8pyoJadR*.7kCMdnj", width: 32, height: 0), "Zero height should return nil")
    }

    func testBlurHashMemoryCaching() {
        let blurHash = "LEHLh[WB2yk8pyoJadR*.7kCMdnj"
        let image1 = renderBlurHash(blurHash: blurHash, width: 24, height: 24)
        let image2 = renderBlurHash(blurHash: blurHash, width: 24, height: 24)

        XCTAssertNotNil(image1)
        XCTAssertNotNil(image2)
        XCTAssertTrue(image1 === image2, "Repeated calls with identical parameters should return the cached instance")
    }

    func testImageFromRGBA() {
        // 2x2 image = 4 pixels * 4 octets = 16 octets RGBA
        let bytes: [UInt8] = [
            255, 0, 0, 255,     // Pixel 0,0: Rouge
            0, 255, 0, 255,     // Pixel 1,0: Vert
            0, 0, 255, 255,     // Pixel 0,1: Bleu
            255, 255, 0, 255    // Pixel 1,1: Jaune
        ]

        let image = imageFromRGBA(bytes: bytes, width: 2, height: 2)
        XCTAssertNotNil(image, "Valid RGBA byte buffer should produce an NSImage")
        XCTAssertEqual(image?.size, NSSize(width: 2, height: 2))

        // Invalid byte size
        let invalidBytes: [UInt8] = [255, 0, 0]
        XCTAssertNil(imageFromRGBA(bytes: invalidBytes, width: 2, height: 2))
    }
}
