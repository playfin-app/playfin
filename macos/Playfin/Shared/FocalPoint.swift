import AppKit
import SwiftUI
import Vision

/// Where the subject of an image is, to frame a cropped image on it instead of always on its centre.
/// Faces first (a cut-off head is what shows most), then people, otherwise what draws the eye (Apple's saliency).
enum FocalPoint {
    /// Subject of the image and its proportions. `point` is in fractions of the image, (0, 0) = top left.
    struct Framing: Equatable, Sendable {
        let point: CGPoint
        let aspectRatio: CGFloat
    }

    /// Analyses an image (a few dozen ms: call it off the main thread). Nil: no clear subject, the centre is kept.
    /// Order: faces, then people (also seen from behind or far away: aimed at the head), then what draws the eye.
    static func detect(in image: CGImage) -> CGPoint? {
        let handler = VNImageRequestHandler(cgImage: image)
        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let saliency = VNGenerateAttentionBasedSaliencyImageRequest()
        try? handler.perform([faces, humans, saliency])

        // Small faces or people (a crowd in the background) do not count.
        let faceBoxes = (faces.results ?? []).map(\.boundingBox).filter { $0.width * $0.height > 0.002 }
        if let box = union(faceBoxes) { return topLeftPoint(x: box.midX, y: box.midY) }
        let humanBoxes = (humans.results ?? []).map(\.boundingBox).filter { $0.width * $0.height > 0.004 }
        if let box = union(humanBoxes) {
            // The head, near the top of the body: a cut-off head is what shows most.
            return topLeftPoint(x: box.midX, y: box.maxY - box.height * 0.15)
        }
        let salient = (saliency.results?.first?.salientObjects ?? []).map(\.boundingBox)
        if let box = union(salient) { return topLeftPoint(x: box.midX, y: box.midY) }
        return nil
    }

    private static func union(_ boxes: [CGRect]) -> CGRect? {
        guard let first = boxes.first else { return nil }
        return boxes.dropFirst().reduce(first) { $0.union($1) }
    }

    /// Vision counts from the bottom left; the interface from the top left.
    private static func topLeftPoint(x: CGFloat, y: CGFloat) -> CGPoint {
        CGPoint(x: x, y: 1 - y)
    }

    /// Shift of an image that fills `frame` (centred, like `.fill`) so that its subject lands on `target`
    /// (fractions of the frame), without ever uncovering an edge of the frame.
    static func offset(subject: CGPoint, imageSize: CGSize, frame: CGSize, target: CGPoint) -> CGSize {
        func shift(_ fraction: CGFloat, image: CGFloat, frame: CGFloat, target: CGFloat) -> CGFloat {
            let margin = max(0, (image - frame) / 2)
            let centred = (frame - image) / 2 + fraction * image
            return min(max(target * frame - centred, -margin), margin)
        }
        return CGSize(
            width: shift(subject.x, image: imageSize.width, frame: frame.width, target: target.x),
            height: shift(subject.y, image: imageSize.height, frame: frame.height, target: target.y)
        )
    }

    /// Size of an image of these proportions that fills `frame` (same as `.aspectRatio(contentMode: .fill)`).
    static func fillSize(aspectRatio: CGFloat, frame: CGSize) -> CGSize {
        guard aspectRatio > 0, frame.width > 0, frame.height > 0 else { return frame }
        return frame.width / frame.height > aspectRatio
            ? CGSize(width: frame.width, height: frame.width / aspectRatio)
            : CGSize(width: frame.height * aspectRatio, height: frame.height)
    }
}

/// Framings already computed in this session (an image is analysed once).
@MainActor
final class FocalPointCache {
    static let shared = FocalPointCache()
    private var framings: [String: FocalPoint.Framing] = [:]
    private var misses: Set<String> = []

    /// Known framing, without waiting (nil: not analysed yet, or no subject).
    func cachedFraming(for url: URL?) -> FocalPoint.Framing? {
        url.flatMap { framings[ImageCache.shared.cacheKey(for: $0)] }
    }

    /// Loads the image (from the image cache) and analyses it off the main thread.
    func framing(for url: URL?) async -> FocalPoint.Framing? {
        guard let url else { return nil }
        let key = ImageCache.shared.cacheKey(for: url)
        if let known = framings[key] { return known }
        guard !misses.contains(key),
              let image = try? await ImageCache.shared.loadImage(forKey: key, from: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              cgImage.height > 0 else { return nil }
        let aspectRatio = CGFloat(cgImage.width) / CGFloat(cgImage.height)
        let point = await Task.detached(priority: .utility) { FocalPoint.detect(in: cgImage) }.value
        guard let point else {
            misses.insert(key)
            return nil
        }
        let framing = FocalPoint.Framing(point: point, aspectRatio: aspectRatio)
        framings[key] = framing
        return framing
    }
}

/// Image that fills its frame like `.fill`, but framed on its subject when it is known (otherwise on the centre).
struct FocusedFillImage: View {
    let image: Image
    let framing: FocalPoint.Framing?
    /// Where the subject should land in the frame (fractions).
    var target = CGPoint(x: 0.5, y: 0.5)

    var body: some View {
        GeometryReader { geo in
            if let framing {
                let size = FocalPoint.fillSize(aspectRatio: framing.aspectRatio, frame: geo.size)
                image.resizable()
                    .frame(width: size.width, height: size.height)
                    .offset(FocalPoint.offset(subject: framing.point, imageSize: size, frame: geo.size, target: target))
                    .frame(width: geo.size.width, height: geo.size.height)
            } else {
                image.resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
        .clipped()
    }
}
