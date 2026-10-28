import XCTest
import AVFoundation
import Libmpv
@testable import Playfin

final class Playback4KTests: XCTestCase {
    
    private func generate4KTestVideoIfNeeded(url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            return
        }
        nonisolated(unsafe) let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 3840,
            AVVideoHeightKey: 2160
        ]
        nonisolated(unsafe) let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        nonisolated(unsafe) let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                kCVPixelBufferWidthKey as String: 3840,
                kCVPixelBufferHeightKey as String: 2160
            ]
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        nonisolated(unsafe) var pixelBuffer: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool {
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        }
        if pixelBuffer == nil {
            CVPixelBufferCreate(
                nil, 3840, 2160,
                kCVPixelFormatType_32ARGB,
                nil,
                &pixelBuffer
            )
        }

        let sema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var frameIndex = 0
        let totalFrames = 30
        input.requestMediaDataWhenReady(on: DispatchQueue.global(qos: .userInitiated)) {
            while input.isReadyForMoreMediaData && frameIndex < totalFrames {
                if let pb = pixelBuffer {
                    let frameTime = CMTime(value: CMTimeValue(frameIndex), timescale: 30)
                    adaptor.append(pb, withPresentationTime: frameTime)
                }
                frameIndex += 1
            }
            if frameIndex >= totalFrames {
                input.markAsFinished()
                writer.finishWriting {
                    sema.signal()
                }
            }
        }
        _ = sema.wait(timeout: .now() + 5.0)
    }

    func test4KPlaybackWithVideoToolboxHardwareDecoding() throws {
        let testVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent("jn-4k-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: testVideoURL) }
        try generate4KTestVideoIfNeeded(url: testVideoURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testVideoURL.path), "4K video file must exist")

        guard let mpv = mpv_create() else {
            XCTFail("Failed to create libmpv instance")
            return
        }
        defer { mpv_destroy(mpv) }

        // Configure videotoolbox hardware decoding
        mpv_set_option_string(mpv, "vo", "null")
        mpv_set_option_string(mpv, "hwdec", "videotoolbox-copy")
        mpv_set_option_string(mpv, "hwdec-codecs", "all")
        mpv_request_log_messages(mpv, "v")

        let initStatus = mpv_initialize(mpv)
        XCTAssertEqual(initStatus, 0, "mpv_initialize should return 0")

        var logLines: [String] = []

        // Load the 4K test file
        let args = ["loadfile", testVideoURL.path]
        let cStrings = args.map { strdup($0) }
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        pointers.append(nil)
        pointers.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            mpv_command(mpv, base)
        }
        for ptr in cStrings {
            if let ptr { free(ptr) }
        }

        let deadline = Date().addingTimeInterval(3.0)
        while Date() < deadline {
            guard let event = mpv_wait_event(mpv, 0.05) else { continue }
            if event.pointee.event_id == MPV_EVENT_LOG_MESSAGE {
                let msg = event.pointee.data.assumingMemoryBound(to: mpv_event_log_message.self)
                let prefix = String(cString: msg.pointee.prefix)
                let text = String(cString: msg.pointee.text)
                let line = "[\(prefix)] \(text)".trimmingCharacters(in: .whitespacesAndNewlines)
                logLines.append(line)
            }
            if event.pointee.event_id == MPV_EVENT_END_FILE {
                break
            }
        }

        let vdLogs = logLines.filter { $0.starts(with: "[vd]") || $0.lowercased().contains("videotoolbox") }
        print("=== Video Decoder & VideoToolbox MPV Logs (\(vdLogs.count)) ===")
        for l in vdLogs {
            print(l)
        }
        var hwdecCurrent = ""
        if let ptr = mpv_get_property_string(mpv, "hwdec-current") {
            hwdecCurrent = String(cString: ptr)
            mpv_free(ptr)
        }
        print("hwdec-current: '\(hwdecCurrent)'")
        print("================================================================")

        XCTAssertTrue(vdLogs.contains { $0.contains("videotoolbox") }, "Expected log messages referencing videotoolbox")
    }

    @MainActor
    func test4KPlaybackThroughMPVPlayerView() throws {
        // The test file is generated here: the test no longer depends on a file left in /tmp (it failed on a clean machine).
        let testVideoURL = FileManager.default.temporaryDirectory.appendingPathComponent("jn-4k-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: testVideoURL) }
        try generate4KTestVideoIfNeeded(url: testVideoURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: testVideoURL.path))

        let controller = PlayerController()
        let movie = Movie(
            id: "test-4k", name: "4K Test Video", sortName: nil, productionYear: 2026, premiereDate: nil,
            runTimeTicks: 20_000_000, container: "mp4", overview: "Test 4K", communityRating: nil,
            criticRating: nil, officialRating: nil, genres: [], dateCreated: nil,
            people: [], userData: nil, seriesName: nil, seriesId: nil, seasonId: nil,
            seasonName: nil, indexNumber: nil, parentIndexNumber: nil, itemType: "Movie",
            width: 3840, height: 2160, primaryBlurHash: nil, primaryImageAspectRatio: 1.777
        )
        let playback = Playback(
            movie: movie,
            url: testVideoURL.path,
            httpHeader: "",
            startSeconds: 0.0,
            subtitles: []
        )
        let view = MPVNSView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
        view.controller = controller
        controller.engine = view

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 360),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = view
        view.play(playback)

        // We wait until mpv has loaded the file (up to 8 s) instead of a fixed delay.
        let deadline = Date().addingTimeInterval(8)
        // The state is read off the main thread: codec, dimensions and decoder arrive at different times.
        while Date() < deadline
            && (controller.videoCodec.isEmpty || !controller.videoResolution.contains("4K") || controller.hwdecCurrent.isEmpty) {
            view.updatePlaybackState()
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }

        print("=== MPVNSView Playback Metrics ===")
        print("hwdecCurrent: '\(controller.hwdecCurrent)'")
        print("videoResolution: '\(controller.videoResolution)'")
        print("videoCodec: '\(controller.videoCodec)'")
        print("duration: \(controller.duration)")
        print("==================================")

        XCTAssertFalse(controller.videoCodec.isEmpty, "Video codec should be detected")
        XCTAssertEqual(controller.hwdecCurrent, "videotoolbox", "Hardware decoding should be videotoolbox")
        XCTAssertTrue(controller.videoResolution.contains("4K UHD"), "Resolution must be 4K UHD")

        view.destroy()
        window.contentView = nil
        window.orderOut(nil)
    }
}
