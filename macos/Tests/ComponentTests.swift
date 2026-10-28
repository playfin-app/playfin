import SwiftUI
import Network
import os
import XCTest
@testable import Playfin

/// Shared UI components: shelf scroller and image cache.
final class ComponentTests: AppTestCase {
    @MainActor
    func testShelfScrollerMovesByPageAndTracksEnds() async throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 100))
        let scroller = ShelfScroller()
        scroller.attach(scrollView)

        XCTAssertFalse(scroller.canScrollBack)
        XCTAssertTrue(scroller.canScrollForward)

        scroller.scroll(by: 1)
        await settle(scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 320, accuracy: 1, "80% of the visible width")
        XCTAssertTrue(scroller.canScrollBack)

        // All the way: we do not go past the end, and the right arrow gets disabled.
        scroller.scroll(by: 1)
        scroller.scroll(by: 1)
        await settle(scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 600, accuracy: 1)
        XCTAssertFalse(scroller.canScrollForward)

        scroller.scroll(by: -1)
        scroller.scroll(by: -1)
        scroller.scroll(by: -1)
        scroller.scroll(by: -1)
        await settle(scrollView)
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, 0, accuracy: 1)
        XCTAssertFalse(scroller.canScrollBack)
    }

    @MainActor
    func testShelfScrollerStopsAtTheLeftInsetUnderTheSidebar() async throws {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 120, bottom: 0, right: 0)
        scrollView.documentView = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 100))
        scrollView.contentView.scroll(to: NSPoint(x: -120, y: 0))
        let scroller = ShelfScroller()
        scroller.attach(scrollView)
        XCTAssertFalse(scroller.canScrollBack, "at rest we are already at the left edge, with the sidebar margin")

        scroller.scroll(by: 1)
        await settle(scrollView)
        XCTAssertTrue(scroller.canScrollBack)

        scroller.scroll(by: -1)
        scroller.scroll(by: -1)
        await settle(scrollView)
        // Exact return to the left edge: the first poster is not hidden under the sidebar.
        XCTAssertEqual(scrollView.contentView.bounds.origin.x, -120, accuracy: 1)
        XCTAssertFalse(scroller.canScrollBack)
    }

    func testImageDecodeDownscalesLargeImagesOffTheMainThread() throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 3000, pixelsHigh: 1500, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let decoded = try XCTUnwrap(ImageCache.decode(png, maxPixelSize: 600))
        XCTAssertEqual(decoded.size.width, 600, accuracy: 1)
        XCTAssertEqual(decoded.size.height, 300, accuracy: 1)
        XCTAssertNil(ImageCache.decode(Data("not an image".utf8)))

        // A small image is never enlarged (otherwise it would needlessly take up memory).
        let small = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 300, pixelsHigh: 300, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let smallPng = try XCTUnwrap(small.representation(using: .png, properties: [:]))
        let smallDecoded = try XCTUnwrap(ImageCache.decode(smallPng, maxPixelSize: 2000))
        XCTAssertEqual(smallDecoded.size.width, 300, accuracy: 1)
    }

    func testConcurrentImageRequestsShareOneDownloadAndCancelledOnesAreCleaned() async throws {
        let requests = OSAllocatedUnfairLock(initialState: 0)
        let server = try await MockHttpServer.start(handler: { _ in
            requests.withLock { $0 += 1 }
            Thread.sleep(forTimeInterval: 0.5)
            return (404, "")
        })
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-img-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ImageCache(diskCacheURL: dir)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/Items/item-1/Images/Primary"))

        // Two simultaneous callers: a single request.
        async let first = cache.loadImage(forKey: "k1", from: url)
        async let second = cache.loadImage(forKey: "k1", from: url)
        _ = try await (first, second)
        XCTAssertEqual(requests.withLock { $0 }, 1)

        // A lone caller that gives up: the download is cancelled and cleaned up, the next one starts from zero.
        let abandoned = Task { try await cache.loadImage(forKey: "k2", from: url) }
        try await Task.sleep(nanoseconds: 100_000_000)
        abandoned.cancel()
        _ = await abandoned.result
        let again = try await cache.loadImage(forKey: "k2", from: url)
        XCTAssertNil(again)
        XCTAssertEqual(requests.withLock { $0 }, 3, "k2 was requested again after the abandonment")
    }

    func testDiskCacheTrimRemovesOldestFilesFirst() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-trim-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let blob = Data(count: 1000)
        for (index, name) in ["old", "mid", "new"].enumerated() {
            let url = dir.appendingPathComponent(name)
            try blob.write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index) * 100)], ofItemAtPath: url.path)
        }
        ImageCache.trimDiskCache(at: dir, maxBytes: 2000)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        XCTAssertEqual(left, ["mid", "new"])
    }

    func testOnlyPassingImageFailuresAreTriedAgain() {
        XCTAssertTrue(ImageRetry.shouldRetry(URLError(.timedOut)))
        XCTAssertTrue(ImageRetry.shouldRetry(URLError(.networkConnectionLost)))
        XCTAssertTrue(ImageRetry.shouldRetry(ImageRetry.TransientError(status: 503)))
        XCTAssertFalse(ImageRetry.shouldRetry(URLError(.cancelled)), "card scrolled away")
        XCTAssertFalse(ImageRetry.shouldRetry(CancellationError()))
        XCTAssertFalse(ImageRetry.shouldRetry(URLError(.badURL)))
        XCTAssertTrue(ImageRetry.isTransient(status: 503))
        XCTAssertTrue(ImageRetry.isTransient(status: 429))
        XCTAssertFalse(ImageRetry.isTransient(status: 404), "no image of this kind: final")
    }

    func testABusyServerIsReportedAsPassingAndAMissingImageIsNot() async throws {
        let status = OSAllocatedUnfairLock(initialState: 503)
        let server = try await MockHttpServer.start(handler: { _ in (status.withLock { $0 }, "") })
        defer { server.stop() }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("jn-retry-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let cache = ImageCache(diskCacheURL: dir)
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/Items/item-1/Images/Primary"))

        do {
            _ = try await cache.loadImage(forKey: "busy", from: url)
            XCTFail("a 503 must throw, so that the card tries again")
        } catch {
            XCTAssertTrue(ImageRetry.shouldRetry(error))
        }
        status.withLock { $0 = 404 }
        let missing = try await cache.loadImage(forKey: "missing", from: url)
        XCTAssertNil(missing, "404: no error, the placeholder simply stays")
    }
}
