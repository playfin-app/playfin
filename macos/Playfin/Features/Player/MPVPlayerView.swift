import AppKit
import Libmpv
import OpenGL.GL3
import SwiftUI

/// SwiftUI view that embeds libmpv and stays in sync with PlayerController.
struct MPVPlayerView: NSViewRepresentable {
    let playback: Playback
    var subtitles: [ExternalSubtitle] = []
    var controller: PlayerController
    var onStart: (Double) -> Void
    var onProgress: (Double, Bool) -> Void
    var onStop: (Double) -> Void
    var onClose: () -> Void
    var onFailure: (String) -> Void = { _ in }
    var onFinished: () -> Void = {}

    func makeNSView(context: Context) -> MPVNSView {
        let view = MPVNSView()
        view.controller = controller
        controller.engine = view
        assignCallbacks(to: view)
        view.play(playback)
        if !subtitles.isEmpty {
            view.addSubtitles(subtitles)
        }
        return view
    }

    func updateNSView(_ nsView: MPVNSView, context: Context) {
        nsView.controller = controller
        controller.engine = nsView
        if nsView.currentURL != playback.url {
            // Another item (next episode): the same player loads the new file, without recreating a view.
            // The previous item's stop report goes out with the old callbacks, before they are replaced.
            nsView.finishCurrentItem()
            assignCallbacks(to: nsView)
            nsView.play(playback)
        } else {
            assignCallbacks(to: nsView)
        }
        if !subtitles.isEmpty {
            nsView.addSubtitles(subtitles)
        }
    }

    private func assignCallbacks(to view: MPVNSView) {
        view.onStart = onStart
        view.onProgress = onProgress
        view.onStop = onStop
        view.onClose = onClose
        view.onFailure = onFailure
        view.onFinished = onFinished
    }

    static func dismantleNSView(_ nsView: MPVNSView, coordinator: ()) {
        nsView.destroy()
    }
}

/// AppKit view hosting the libmpv OpenGL render layer.
final class MPVNSView: NSView {
    private let mpv: OpaquePointer
    private let mpvLayer: MPVLayer
    private var subtitles: [ExternalSubtitle] = []
    private var addedSubtitles = Set<String>()
    private var isFileLoaded = false
    private var serverProgressTimer: Timer?
    private var playbackSyncTimer: Timer?
    private var isDestroyed = false
    private var lastKnownPosition: Double = 0

    weak var controller: PlayerController?
    var onStart: ((Double) -> Void)?
    var onProgress: ((Double, Bool) -> Void)?
    var onStop: ((Double) -> Void)?
    var onClose: (() -> Void)?
    var onFailure: ((String) -> Void)?
    var onFinished: (() -> Void)?

    private final class WakeupContext {
        weak var view: MPVNSView?
        init(view: MPVNSView) { self.view = view }
    }
    private var wakeupContext: WakeupContext?

    deinit {
        destroy()
    }

    override init(frame: NSRect) {
        mpv = mpv_create()

        // vo=libmpv: direct drawing in our OpenGL layer
        mpv_set_option_string(mpv, "vo", "libmpv")
        // Disables mpv's primitive OSC and the yellow OSD bar
        mpv_set_option_string(mpv, "osc", "no")
        mpv_set_option_string(mpv, "osd-bar", "no")
        mpv_set_option_string(mpv, "input-default-bindings", "no")
        mpv_set_option_string(mpv, "keep-open", "yes")
        // Hardware decoding, network cache (chosen preset) and languages: see PlayerSettings.swift
        for option in PlayerOptions.current() {
            mpv_set_option_string(mpv, option.name, option.value)
        }
        // Fast relative jumps (arrows) on keyframes; precise frame-accurate absolute jump (seek bar),
        // so that playback resumes exactly where the user let go.
        mpv_set_option_string(mpv, "hr-seek", "absolute")
        mpv_set_option_string(mpv, "force-seekable", "yes")
        mpv_initialize(mpv)
        // With keep-open, mpv does not send "end of file": we observe `eof-reached` instead.
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)

        mpvLayer = MPVLayer(mpv: mpv)
        super.init(frame: frame)
        layer = mpvLayer
        wantsLayer = true

        let ctx = WakeupContext(view: self)
        self.wakeupContext = ctx
        let ctxPtr = Unmanaged.passRetained(ctx).toOpaque()
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            let ctx = Unmanaged<WakeupContext>.fromOpaque(context).takeUnretainedValue()
            DispatchQueue.main.async { [weak ctx] in
                ctx?.view?.readEvents()
            }
        }, ctxPtr)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    /// URL of the current item (to know whether another file must be loaded in the same player).
    private(set) var currentURL: String?

    func play(_ playback: Playback) {
        currentURL = playback.url
        isFileLoaded = false
        lastKnownPosition = 0
        didReportFinished = false
        serverProgressTimer?.invalidate()
        subtitles = playback.subtitles
        addedSubtitles = Set(playback.subtitles.map(\.url))
        // Properties (not options): they replace the previous value instead of adding to it.
        mpv_set_property_string(mpv, "http-header-fields", playback.httpHeader)
        mpv_set_property_string(mpv, "start", playback.startSeconds > 0 ? String(playback.startSeconds) : "none")
        command(["loadfile", playback.url, "replace"])
    }

    /// End of the current item when moving to the next one in the same player: stop report with the position.
    func finishCurrentItem() {
        guard isFileLoaded, !isDestroyed else { return }
        onStop?(max(position, lastKnownPosition))
    }

    func addSubtitles(_ newSubtitles: [ExternalSubtitle]) {
        for subtitle in newSubtitles {
            guard !addedSubtitles.contains(subtitle.url) else { continue }
            addedSubtitles.insert(subtitle.url)
            if isFileLoaded {
                command(["sub-add", subtitle.url, "auto", subtitle.title, subtitle.language ?? ""])
                updatePlaybackState()
            } else {
                subtitles.append(subtitle)
            }
        }
    }

    func destroy() {
        guard !isDestroyed else { return }
        isDestroyed = true
        endSleepPrevention()
        serverProgressTimer?.invalidate()
        serverProgressTimer = nil
        playbackSyncTimer?.invalidate()
        playbackSyncTimer = nil
        let finalPos = max(position, lastKnownPosition)
        onStop?(finalPos)
        wakeupContext?.view = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        if let ctx = wakeupContext {
            Unmanaged.passUnretained(ctx).release()
            wakeupContext = nil
        }
        mpvLayer.destroy()
        // Waits for a possible state read in progress on the other thread, then forbids the following ones.
        handle.invalidate()
        mpv_terminate_destroy(mpv)
    }

    // MARK: - Screen sleep

    private var sleepActivity: NSObjectProtocol?

    /// Prevents the screen from turning off during playback (mpv does not do it when it draws in our layer).
    private func beginSleepPrevention() {
        guard sleepActivity == nil else { return }
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Playback in progress"
        )
    }

    private func endSleepPrevention() {
        if let activity = sleepActivity { ProcessInfo.processInfo.endActivity(activity) }
        sleepActivity = nil
    }

    // MARK: - Subtitle Position

    private var lastDispatchedSubPos: Int = 100

    /// Places the subtitles above the control bar (or all the way down), in a single move: mpv
    /// only applies the position at the next video frame, so intermediate steps gave a
    /// jerky "two-step" movement.
    func setSubtitlePosition(_ target: Double) {
        let value = max(50, min(100, Int(target.rounded())))
        guard value != lastDispatchedSubPos, !isDestroyed else { return }
        lastDispatchedSubPos = value
        command(["set", "sub-pos", String(value)])
    }

    var hostWindow: NSWindow? { window }

    // MARK: - Playback controls called by PlayerController

    func seek(relative seconds: Double) {
        command(["seek", String(seconds), "relative+keyframes"])
        updatePlaybackState()
    }

    func seek(absolute seconds: Double) {
        command(["seek", String(seconds), "absolute"])
        updatePlaybackState()
    }

    func togglePause() {
        command(["cycle", "pause"])
        updatePlaybackState()
        reportProgressNow()
    }

    /// Sends the position to the server right away (pause, end of a jump), on top of the report every 10 s.
    private func reportProgressNow() {
        guard isFileLoaded, !isDestroyed else { return }
        // Commands are asynchronous: we let mpv apply the pause / the jump, then read the state again.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.isFileLoaded, !self.isDestroyed else { return }
            self.onProgress?(max(self.position, self.lastKnownPosition), self.isPaused)
        }
    }

    func setVolume(_ volume: Double) {
        guard !isDestroyed else { return }
        command(["set", "volume", String(format: "%.1f", volume)])
    }

    func toggleMute() {
        command(["cycle", "mute"])
        updatePlaybackState()
    }

    func setSpeed(_ speed: Double) {
        command(["set", "speed", String(speed)])
        updatePlaybackState()
    }

    func selectAudio(id: Int) {
        command(["set", "aid", String(id)])
        updatePlaybackState()
    }

    func selectSubtitle(id: Int?) {
        command(["set", "sid", id.map(String.init) ?? "no"])
        updatePlaybackState()
    }

    func setProperty(_ name: String, to value: String) {
        command(["set", name, value])
    }

    func setAspectRatio(_ ratio: String) {
        command(["set", "video-aspect-override", ratio])
    }

    func setPanScan(_ value: Double) {
        command(["set", "panscan", String(value)])
    }

    func jumpToChapter(_ index: Int) {
        command(["set", "chapter", String(index)])
        updatePlaybackState()
    }

    // MARK: - Extracting tracks and chapters

    nonisolated static func readTracks(_ mpv: OpaquePointer) -> [TrackItem] {
        var count: Int64 = 0
        mpv_get_property(mpv, "track-list/count", MPV_FORMAT_INT64, &count)
        var items: [TrackItem] = []

        for i in 0..<count {
            guard let typePtr = mpv_get_property_string(mpv, "track-list/\(i)/type") else { continue }
            let type = String(cString: typePtr)
            mpv_free(typePtr)

            guard type == "audio" || type == "sub" else { continue }

            var id: Int64 = 0
            mpv_get_property(mpv, "track-list/\(i)/id", MPV_FORMAT_INT64, &id)

            var selected: Int32 = 0
            mpv_get_property(mpv, "track-list/\(i)/selected", MPV_FORMAT_FLAG, &selected)

            var title = ""
            if let titlePtr = mpv_get_property_string(mpv, "track-list/\(i)/title") {
                title = String(cString: titlePtr)
                mpv_free(titlePtr)
            }

            var lang: String? = nil
            if let langPtr = mpv_get_property_string(mpv, "track-list/\(i)/lang") {
                lang = String(cString: langPtr)
                mpv_free(langPtr)
            }

            func flag(_ name: String) -> Bool {
                var value: Int32 = 0
                mpv_get_property(mpv, "track-list/\(i)/\(name)", MPV_FORMAT_FLAG, &value)
                return value != 0
            }
            var codec: String?
            if let codecPtr = mpv_get_property_string(mpv, "track-list/\(i)/codec") {
                codec = String(cString: codecPtr)
                mpv_free(codecPtr)
            }
            var channels: Int64 = 0
            let hasChannels = mpv_get_property(mpv, "track-list/\(i)/demux-channel-count", MPV_FORMAT_INT64, &channels) >= 0

            items.append(TrackItem(
                id: Int(id),
                type: type,
                title: title,
                language: lang,
                isSelected: selected != 0,
                codec: codec,
                channels: hasChannels && channels > 0 ? Int(channels) : nil,
                isForced: flag("forced"),
                isDefault: flag("default"),
                isHearingImpaired: flag("hearing-impaired"),
                isExternal: flag("external")
            ))
        }
        return items
    }

    nonisolated static func readChapters(_ mpv: OpaquePointer) -> [ChapterItem] {
        var count: Int64 = 0
        mpv_get_property(mpv, "chapter-list/count", MPV_FORMAT_INT64, &count)
        var items: [ChapterItem] = []

        for i in 0..<count {
            var time: Double = 0
            mpv_get_property(mpv, "chapter-list/\(i)/time", MPV_FORMAT_DOUBLE, &time)

            var title = "Chapter \(i + 1)"
            if let titlePtr = mpv_get_property_string(mpv, "chapter-list/\(i)/title") {
                title = String(cString: titlePtr)
                mpv_free(titlePtr)
            }

            items.append(ChapterItem(index: Int(i), title: title, timeSeconds: time))
        }
        return items
    }

    // MARK: - State synchronisation

    /// Reads the mpv state **off the main thread** then applies it to the interface. While a network stream is
    /// opening, the mpv core is busy: a property read there sometimes waits several seconds, which
    /// blocked the whole interface at the start of playback.
    func updatePlaybackState() {
        guard controller != nil, !isDestroyed, !pollInFlight else { return }
        pollInFlight = true
        let handle = self.handle
        Self.pollQueue.async {
            let snapshot = handle.withHandle { MPVSnapshot.read($0) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pollInFlight = false
                guard let snapshot, !self.isDestroyed else { return }
                self.apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: MPVSnapshot) {
        guard let controller else { return }
        cachedPosition = snapshot.position
        cachedDuration = snapshot.duration
        cachedPaused = snapshot.paused
        if snapshot.position > 0 { lastKnownPosition = snapshot.position }
        let audios = snapshot.tracks.filter { $0.type == "audio" }
        let subs = snapshot.tracks.filter { $0.type == "sub" }
        controller.update(
            position: snapshot.position,
            duration: snapshot.duration,
            isPaused: snapshot.paused,
            volume: snapshot.volume,
            isMuted: snapshot.muted,
            speed: snapshot.speed,
            audioTracks: audios,
            subtitleTracks: subs,
            selectedAudioId: audios.first(where: \.isSelected)?.id ?? controller.selectedAudioId,
            selectedSubtitleId: subs.first(where: \.isSelected)?.id ?? controller.selectedSubtitleId,
            videoCodec: snapshot.videoCodec,
            audioCodec: snapshot.audioCodec,
            videoResolution: snapshot.resolution,
            cacheDuration: snapshot.cacheDuration,
            hwdecCurrent: snapshot.hwdec
        )
        if controller.chapters != snapshot.chapters { controller.chapters = snapshot.chapters }
    }

    // MARK: - mpv events

    private func readEvents() {
        guard !isDestroyed else { return }
        while !isDestroyed, let event = mpv_wait_event(mpv, 0)?.pointee,
              event.event_id != MPV_EVENT_NONE {
            switch event.event_id {
            case MPV_EVENT_FILE_LOADED:
                fileLoaded()
            case MPV_EVENT_PROPERTY_CHANGE:
                handlePropertyChange(event)
            case MPV_EVENT_PLAYBACK_RESTART:
                updatePlaybackState()
                reportProgressNow() // end of a jump in the video
            case MPV_EVENT_END_FILE:
                if let data = event.data {
                    let endEvent = data.bindMemory(to: mpv_event_end_file.self, capacity: 1).pointee
                    if endEvent.reason == MPV_END_FILE_REASON_ERROR {
                        // No transcoding in this version: if direct play is impossible, we say so clearly.
                        onFailure?(
                            "This file could not be played: unsupported format or unreachable server. "
                                + "This version plays files as they are, without converting them."
                        )
                        onClose?()
                    } else if endEvent.reason == MPV_END_FILE_REASON_EOF {
                        onFinished?()
                    }
                }
            default:
                break
            }
        }
    }

    private var didReportFinished = false

    private func handlePropertyChange(_ event: mpv_event) {
        guard let data = event.data else { return }
        let property = data.bindMemory(to: mpv_event_property.self, capacity: 1).pointee
        guard String(cString: property.name) == "eof-reached", property.format == MPV_FORMAT_FLAG,
              let value = property.data?.bindMemory(to: Int32.self, capacity: 1).pointee else { return }
        guard value != 0 else { didReportFinished = false; return } // jumped back: the end can be reported again
        let pos = max(position, lastKnownPosition)
        if !didReportFinished, PlaybackEnd.isGenuineEnd(eofReached: true, position: pos, duration: duration) {
            didReportFinished = true
            onFinished?()
        }
    }

    private func fileLoaded() {
        isFileLoaded = true
        didReportFinished = false
        beginSleepPrevention()
        for subtitle in subtitles {
            command(["sub-add", subtitle.url, "auto", subtitle.title, subtitle.language ?? ""])
        }
        subtitles = []

        let startPos = max(position, lastKnownPosition)
        onStart?(startPos)

        // Report to the Jellyfin server every 10 s
        serverProgressTimer?.invalidate()
        serverProgressTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDestroyed else { return }
                let currentPos = max(self.position, self.lastKnownPosition)
                self.onProgress?(currentPos, self.isPaused)
            }
        }

        // High-frequency synchronisation to SwiftUI (4 times per second)
        playbackSyncTimer?.invalidate()
        playbackSyncTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !self.isDestroyed else { return }
                self.updatePlaybackState()
            }
        }

        updatePlaybackState()
    }

    /// Last values read by `updatePlaybackState` (never a blocking read on the main thread).
    private var cachedPosition = 0.0
    private var cachedDuration = 0.0
    private var cachedPaused = false
    private var pollInFlight = false
    private static let pollQueue = DispatchQueue(label: "com.playfin.app.mpv.poll", qos: .userInitiated)
    private lazy var handle = MPVHandle(mpv: mpv)

    private var position: Double { cachedPosition }

    private var duration: Double { cachedDuration }

    private var isPaused: Bool { cachedPaused }

    private func command(_ args: [String]) {
        guard !isDestroyed else { return }
        let cStrings = args.map { strdup($0) }
        var pointers: [UnsafePointer<CChar>?] = cStrings.map { $0.map { UnsafePointer($0) } }
        pointers.append(nil)
        pointers.withUnsafeMutableBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            // Asynchronous: the command is queued without waiting for the mpv core (which may be busy
            // opening the stream); the interface never freezes.
            mpv_command_async(mpv, 0, base)
        }
        for ptr in cStrings {
            if let ptr { free(ptr) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        window?.makeFirstResponder(self)
    }

    // MARK: - Retina screen & Keyboard

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2
    }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        mpvLayer.contentsScale = window?.backingScaleFactor ?? 2
        window?.makeFirstResponder(self)
    }
}

/// OpenGL layer in which mpv draws each frame.
final class MPVLayer: CAOpenGLLayer {
    private let mpv: OpaquePointer
    private var renderContext: OpaquePointer?
    private let pixelFormat: CGLPixelFormatObj
    private let glContext: CGLContextObj
    private let lock = NSLock()
    private var forceDraw = true

    init(mpv: OpaquePointer) {
        self.mpv = mpv

        let attributes: [CGLPixelFormatAttribute] = [
            kCGLPFAOpenGLProfile, CGLPixelFormatAttribute(kCGLOGLPVersion_3_2_Core.rawValue),
            kCGLPFADoubleBuffer, kCGLPFAAccelerated, kCGLPFAAllowOfflineRenderers,
            CGLPixelFormatAttribute(0),
        ]
        var pixelFormat: CGLPixelFormatObj?
        var count: GLint = 0
        CGLChoosePixelFormat(attributes, &pixelFormat, &count)
        guard let resolvedPixelFormat = pixelFormat else {
            fatalError("Could not choose the OpenGL pixel format")
        }
        var glContext: CGLContextObj?
        CGLCreateContext(resolvedPixelFormat, nil, &glContext)
        guard let resolvedContext = glContext else {
            fatalError("Could not create the OpenGL context")
        }
        self.pixelFormat = resolvedPixelFormat
        self.glContext = resolvedContext

        super.init()
        // Rendering driven by mpv, on a dedicated thread (like IINA): when a frame is ready, mpv notifies us and we
        // draw off the main thread. With `isAsynchronous`, Core Animation drew on the main thread at
        // every refresh, which blocked it while playback was starting.
        isAsynchronous = false
        needsDisplayOnBoundsChange = true
        isOpaque = true
        backgroundColor = NSColor.black.cgColor
        createRenderContext()
    }

    override init(layer: Any) {
        guard let other = layer as? MPVLayer else {
            fatalError("MPVLayer expected for the layer initialisation")
        }
        mpv = other.mpv
        pixelFormat = other.pixelFormat
        glContext = other.glContext
        CGLRetainPixelFormat(pixelFormat)
        CGLRetainContext(glContext)
        super.init(layer: layer)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var bounds: CGRect {
        didSet {
            lock.withLock { forceDraw = true }
            scheduleRender()
        }
    }

    override var contentsScale: CGFloat {
        didSet { lock.withLock { forceDraw = true } }
    }

    private func createRenderContext() {
        CGLSetCurrentContext(glContext)

        var glInit = mpv_opengl_init_params(
            get_proc_address: { _, name in
                let symbol = CFStringCreateWithCString(nil, name, CFStringBuiltInEncodings.ASCII.rawValue)
                let bundle = CFBundleGetBundleWithIdentifier("com.apple.opengl" as CFString)
                return CFBundleGetFunctionPointerForName(bundle, symbol)
            },
            get_proc_address_ctx: nil)

        "opengl".withCString { apiType in
            withUnsafeMutablePointer(to: &glInit) { glInitPtr in
                var params = [
                    mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE,
                                     data: UnsafeMutableRawPointer(mutating: apiType)),
                    mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_INIT_PARAMS, data: glInitPtr),
                    mpv_render_param(),
                ]
                mpv_render_context_create(&renderContext, mpv, &params)
            }
        }
        if let renderContext {
            mpv_render_context_set_update_callback(renderContext, { context in
                guard let context else { return }
                Unmanaged<MPVLayer>.fromOpaque(context).takeUnretainedValue().scheduleRender()
            }, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private static let renderQueue = DispatchQueue(label: "com.playfin.app.mpv.render", qos: .userInteractive)

    /// A frame is ready (or the size changed): we draw on the render thread.
    func scheduleRender() {
        Self.renderQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.renderContext != nil }) else { return }
            self.display()
        }
    }

    override func display() {
        super.display()
        // Off the main thread, the Core Animation transaction must be pushed ourselves.
        if !Thread.isMainThread { CATransaction.flush() }
    }

    deinit {
        destroy()
        CGLReleasePixelFormat(pixelFormat)
        CGLReleaseContext(glContext)
    }

    func destroy() {
        lock.withLock {
            guard let renderContext else { return }
            // No more calls from mpv to this layer, then wait for a render possibly in progress.
            mpv_render_context_set_update_callback(renderContext, nil, nil)
        }
        Self.renderQueue.sync {}
        lock.withLock {
            guard let renderContext else { return }
            CGLSetCurrentContext(glContext)
            mpv_render_context_free(renderContext)
            self.renderContext = nil
        }
    }

    override func copyCGLPixelFormat(forDisplayMask mask: UInt32) -> CGLPixelFormatObj {
        CGLRetainPixelFormat(pixelFormat)
        return pixelFormat
    }

    override func copyCGLContext(forPixelFormat pf: CGLPixelFormatObj) -> CGLContextObj {
        CGLRetainContext(glContext)
        return glContext
    }

    override func canDraw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                          forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) -> Bool {
        lock.withLock {
            guard let renderContext else { return false }
            let newFrame = mpv_render_context_update(renderContext) & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0
            return newFrame || forceDraw
        }
    }

    override func draw(inCGLContext ctx: CGLContextObj, pixelFormat pf: CGLPixelFormatObj,
                       forLayerTime t: CFTimeInterval, displayTime ts: UnsafePointer<CVTimeStamp>?) {
        lock.withLock {
            guard let renderContext else { return }
            forceDraw = false

            var framebuffer: GLint = 0
            glGetIntegerv(GLenum(GL_DRAW_FRAMEBUFFER_BINDING), &framebuffer)
            var viewport: [GLint] = [0, 0, 0, 0]
            glGetIntegerv(GLenum(GL_VIEWPORT), &viewport)

            var fbo = mpv_opengl_fbo(fbo: Int32(framebuffer), w: viewport[2], h: viewport[3], internal_format: 0)
            var flipY: CInt = 1
            withUnsafeMutablePointer(to: &fbo) { fboPtr in
                withUnsafeMutablePointer(to: &flipY) { flipPtr in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_OPENGL_FBO, data: fboPtr),
                        mpv_render_param(type: MPV_RENDER_PARAM_FLIP_Y, data: flipPtr),
                        mpv_render_param(),
                    ]
                    mpv_render_context_render(renderContext, &params)
                }
            }
            glFlush()
            mpv_render_context_report_swap(renderContext)
        }
    }
}

extension MPVNSView: PlayerEngine {}

/// Access to the mpv player from another thread: a lock prevents reading it while it is being destroyed.
final class MPVHandle: @unchecked Sendable {
    private let mpv: OpaquePointer
    private let lock = NSLock()
    private var valid = true

    init(mpv: OpaquePointer) { self.mpv = mpv }

    func withHandle<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock()
        defer { lock.unlock() }
        return valid ? body(mpv) : nil
    }

    func invalidate() {
        lock.lock()
        valid = false
        lock.unlock()
    }
}

/// mpv state read in one go (on a background thread).
struct MPVSnapshot: Sendable {
    var position = 0.0
    var duration = 0.0
    var paused = false
    var volume = 100.0
    var muted = false
    var speed = 1.0
    var cacheDuration = 0.0
    var videoCodec = ""
    var audioCodec = ""
    var resolution = ""
    var hwdec = ""
    var tracks: [TrackItem] = []
    var chapters: [ChapterItem] = []

    static func read(_ mpv: OpaquePointer) -> MPVSnapshot {
        var s = MPVSnapshot()
        func double(_ name: String) -> Double {
            var value = 0.0
            mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value)
            return value
        }
        func flag(_ name: String) -> Bool {
            var value: Int32 = 0
            mpv_get_property(mpv, name, MPV_FORMAT_FLAG, &value)
            return value != 0
        }
        func string(_ name: String) -> String {
            guard let pointer = mpv_get_property_string(mpv, name) else { return "" }
            defer { mpv_free(pointer) }
            return String(cString: pointer)
        }
        s.position = double("time-pos")
        s.duration = double("duration")
        s.paused = flag("pause")
        var volume = 100.0
        mpv_get_property(mpv, "volume", MPV_FORMAT_DOUBLE, &volume)
        s.volume = volume
        s.muted = flag("mute")
        var speed = 1.0
        mpv_get_property(mpv, "speed", MPV_FORMAT_DOUBLE, &speed)
        s.speed = speed
        s.cacheDuration = double("demuxer-cache-duration")
        s.videoCodec = string("video-codec").uppercased()
        s.audioCodec = string("audio-codec").uppercased()
        var width: Int64 = 0
        var height: Int64 = 0
        mpv_get_property(mpv, "dwidth", MPV_FORMAT_INT64, &width)
        mpv_get_property(mpv, "dheight", MPV_FORMAT_INT64, &height)
        if width > 0, height > 0 {
            let tier = formatResolutionTier(width: Int(width), height: Int(height))
            s.resolution = tier.map { "\(width) × \(height) (\($0))" } ?? "\(width) × \(height)"
        }
        s.hwdec = string("hwdec-current")
        s.tracks = MPVNSView.readTracks(mpv)
        s.chapters = MPVNSView.readChapters(mpv)
        return s
    }
}
