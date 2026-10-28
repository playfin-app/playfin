import SwiftUI
import AppKit

/// Universal asynchronous image component for Playfin.
///
/// Advantageously replaces SwiftUI's `AsyncImage` thanks to:
/// 1. Host-independent cache key (survives local / remote switches).
/// 2. Two-level cache (`NSCache` memory and persistent disk).
/// 3. BlurHash placeholder shown immediately while loading.
/// 4. Asynchronous image decoding off the main thread (zero interface stutter).
/// 5. Task cancellation when scrolling off screen (`onDisappear`).
/// 6. Two new attempts after a passing failure (`ImageRetry`).
/// 7. Smooth cross-fade (fade-in transition) when the image appears.
public struct AsyncArtwork<Content: View, Placeholder: View>: View {
    let url: URL?
    let blurHash: String?
    let targetBlurHashSize: CGSize
    let content: (Image) -> Content
    let placeholder: () -> Placeholder
    /// Alignment of the image in its frame (a logo must be left-aligned with the text, not centred).
    var alignment: Alignment = .center

    @State private var loadedImage: NSImage?
    @State private var blurHashImage: NSImage?
    @State private var loadedURL: URL?
    @State private var loadTask: Task<Void, Never>?
    @State private var isLoaded: Bool = false

    // MARK: - Main initialiser with custom builders

    public init(
        url: URL?,
        blurHash: String? = nil,
        targetBlurHashSize: CGSize = CGSize(width: 32, height: 48),
        @ViewBuilder content: @escaping (Image) -> Content,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.url = url
        self.blurHash = blurHash
        self.targetBlurHashSize = targetBlurHashSize
        self.content = content
        self.placeholder = placeholder

        let w = max(1, Int(targetBlurHashSize.width))
        let h = max(1, Int(targetBlurHashSize.height))

        // Immediate synchronous pre-fill if the image is already in memory
        if let url {
            let key = ImageCache.shared.cacheKey(for: url)
            if let cached = ImageCache.shared.memoryImage(forKey: key) {
                _loadedImage = State(initialValue: cached)
                _isLoaded = State(initialValue: true)
                _loadedURL = State(initialValue: url)
            } else if let blurHash {
                _blurHashImage = State(initialValue: renderBlurHash(blurHash: blurHash, width: w, height: h))
            }
        } else if let blurHash {
            _blurHashImage = State(initialValue: renderBlurHash(blurHash: blurHash, width: w, height: h))
        }
    }

    // MARK: - View body

    public var body: some View {
        ZStack {
            // Placeholder under the image (BlurHash or fallback view): fades out cleanly when the image is loaded
            Group {
                if let blurHashImage {
                    content(Image(nsImage: blurHashImage))
                } else {
                    placeholder()
                }
            }
            .opacity(isLoaded ? 0.0 : 1.0)

            // Final image loaded: soft opacity fade without changing the grid dimensions
            if let loadedImage {
                content(Image(nsImage: loadedImage))
                    .opacity(isLoaded ? 1.0 : 0.0)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: alignment)
        .clipped()
        // Fade from the BlurHash to the image (no effect if the image was already in memory at creation)
        .animation(Theme.Motion.fade, value: isLoaded)
        .task(id: url) {
            await startLoading()
        }
        .onDisappear {
            loadTask?.cancel()
            loadTask = nil
        }
    }

    // MARK: - Loading logic

    @MainActor
    private func startLoading() async {
        guard let url else {
            loadedImage = nil
            isLoaded = false
            loadedURL = nil
            return
        }

        // If the image is already displayed and matches this URL, reset nothing (zero wiggle)
        if loadedURL == url && loadedImage != nil {
            return
        }

        let key = ImageCache.shared.cacheKey(for: url)

        // 1. Fast memory cache check
        if let memoryHit = ImageCache.shared.memoryImage(forKey: key) {
            self.loadedImage = memoryHit
            self.isLoaded = true
            self.loadedURL = url
            return
        }

        // 2. Reset and immediate display of the BlurHash placeholder
        self.loadedImage = nil
        self.isLoaded = false
        self.loadedURL = nil
        let w = max(1, Int(targetBlurHashSize.width))
        let h = max(1, Int(targetBlurHashSize.height))
        if let blurHash {
            self.blurHashImage = renderBlurHash(blurHash: blurHash, width: w, height: h)
        } else {
            self.blurHashImage = nil
        }

        // 3. Asynchronous task (disk then network). A passing failure (slow remote network, busy server)
        //    is tried again twice; otherwise the placeholder stays.
        loadTask?.cancel()
        let currentTask = Task {
            for attempt in 0...ImageRetry.delays.count {
                do {
                    guard let image = try await ImageCache.shared.loadImage(forKey: key, from: url),
                          !Task.isCancelled else { return }
                    self.loadedImage = image
                    self.loadedURL = url
                    self.isLoaded = true
                    return
                } catch {
                    guard attempt < ImageRetry.delays.count, ImageRetry.shouldRetry(error), !Task.isCancelled else { return }
                    try? await Task.sleep(for: ImageRetry.delays[attempt])
                }
            }
        }
        loadTask = currentTask
        await currentTask.value
    }
}

extension AsyncArtwork {
    /// Aligns the image in its frame.
    public func artworkAlignment(_ alignment: Alignment) -> AsyncArtwork {
        var copy = self
        copy.alignment = alignment
        return copy
    }
}

// MARK: - Convenience initialisers

extension AsyncArtwork where Content == AnyView {
    /// Initialiser with custom placeholder and standardised image rendering according to `contentMode`.
    public init(
        url: URL?,
        blurHash: String? = nil,
        targetBlurHashSize: CGSize = CGSize(width: 32, height: 48),
        contentMode: ContentMode = .fill,
        @ViewBuilder placeholder: @escaping () -> Placeholder
    ) {
        self.init(
            url: url,
            blurHash: blurHash,
            targetBlurHashSize: targetBlurHashSize,
            content: { image in
                AnyView(image.resizable().aspectRatio(contentMode: contentMode))
            },
            placeholder: placeholder
        )
    }
}

extension AsyncArtwork where Content == AnyView, Placeholder == AnyView {
    /// Default initialiser with blurred rectangle / default system icon.
    public init(
        url: URL?,
        blurHash: String? = nil,
        targetBlurHashSize: CGSize = CGSize(width: 32, height: 48),
        contentMode: ContentMode = .fill,
        placeholderIcon: String? = "film"
    ) {
        self.init(
            url: url,
            blurHash: blurHash,
            targetBlurHashSize: targetBlurHashSize,
            contentMode: contentMode
        ) {
            AnyView(
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if let icon = placeholderIcon {
                            Image(systemName: icon)
                                .font(.largeTitle)
                                .foregroundStyle(.secondary)
                        }
                    }
            )
        }
    }
}
