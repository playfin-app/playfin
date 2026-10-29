import SwiftUI
import AppKit

/// Goes back to the previous page of the main window (detail → grid), whatever has the focus, with:
/// - Escape (not while typing in a field, nor when a sheet is open: they handle Escape themselves);
/// - a two-finger swipe from left to right on the trackpad, like in Safari (if allowed in System Settings):
///   `swipeBegan`, then `swipeMoved` with the progress (0 to 1), then `swipeEnded` (true: the page left);
/// - the "back" button of a mouse.
struct GoBackMonitor: NSViewRepresentable {
    let canGoBack: () -> Bool
    let goBack: () -> Bool
    let swipeBegan: () -> Void
    let swipeMoved: (CGFloat) -> Void
    let swipeEnded: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.canGoBack = canGoBack
        coordinator.goBack = goBack
        coordinator.swipeBegan = swipeBegan
        coordinator.swipeMoved = swipeMoved
        coordinator.swipeEnded = swipeEnded
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .scrollWheel, .otherMouseDown]
        ) { [weak coordinator] event in
            let used = MainActor.assumeIsolated { coordinator?.handle(event) ?? false }
            return used ? nil : event
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.canGoBack = canGoBack
        context.coordinator.goBack = goBack
        context.coordinator.swipeBegan = swipeBegan
        context.coordinator.swipeMoved = swipeMoved
        context.coordinator.swipeEnded = swipeEnded
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor) }
        coordinator.monitor = nil
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        weak var view: NSView?
        var monitor: Any?
        var canGoBack: () -> Bool = { false }
        var goBack: () -> Bool = { false }
        var swipeBegan: () -> Void = {}
        var swipeMoved: (CGFloat) -> Void = { _ in }
        var swipeEnded: (Bool) -> Void = { _ in }
        /// The current trackpad gesture was already examined: only its first movement decides.
        private var swipeDecided = false

        /// True when the event was used (it then goes no further).
        func handle(_ event: NSEvent) -> Bool {
            guard let window = view?.window, event.window === window, window.attachedSheet == nil else { return false }
            switch event.type {
            case .keyDown:
                guard event.keyCode == 53,
                      event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
                      !(window.firstResponder is NSText)
                else { return false }
                return goBack()
            case .otherMouseDown:
                guard event.buttonNumber == 3 else { return false }
                return goBack()
            case .scrollWheel:
                return handleScroll(event, in: window)
            default:
                return false
            }
        }

        private func handleScroll(_ event: NSEvent, in window: NSWindow) -> Bool {
            // A mouse wheel has no phase: only the trackpad is concerned.
            if event.phase == .began { swipeDecided = false }
            guard event.phase == .began || event.phase == .changed, !swipeDecided else { return false }
            let deltaX = event.scrollingDeltaX
            let deltaY = event.scrollingDeltaY
            guard deltaX != 0 || deltaY != 0 else { return false }
            swipeDecided = true

            // Towards the right, mostly horizontal, and not over a row of posters that can still scroll back.
            guard deltaX > 0, abs(deltaX) > abs(deltaY),
                  NSEvent.isSwipeTrackingFromScrollEventsEnabled,
                  canGoBack(),
                  !Self.rowCanScrollBack(under: event, in: window)
            else { return false }

            // After the fingers are lifted, macOS keeps calling with an animated amount, up to 1 (page gone)
            // or back to 0 (cancelled): the page only has to follow it.
            var goesBack = false
            swipeBegan()
            event.trackSwipeEvent(
                options: [.lockDirection, .clampGestureAmount],
                dampenAmountThresholdMin: 0,
                max: 1
            ) { [weak self] amount, phase, isComplete, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // `.ended`: the fingers were lifted far enough (otherwise `.cancelled`).
                    if phase == .ended { goesBack = amount > 0 }
                    if phase == .cancelled { goesBack = false }
                    self.swipeMoved(min(max(amount, 0), 1))
                    if isComplete { self.swipeEnded(goesBack) }
                }
            }
            return true
        }

        /// True when the pointer is over a horizontal row (home shelves, cast…) that is not at its start.
        private static func rowCanScrollBack(under event: NSEvent, in window: NSWindow) -> Bool {
            guard let content = window.contentView, let frame = content.superview else { return false }
            var view = content.hitTest(frame.convert(event.locationInWindow, from: nil))
            while let current = view {
                if let scrollView = current as? NSScrollView, isShown(scrollView), let document = scrollView.documentView {
                    let clip = scrollView.contentView
                    let isHorizontal = document.frame.width > clip.bounds.width + 1
                    if isHorizontal, clip.bounds.minX > -clip.contentInsets.left + 1 { return true }
                }
                view = current.superview
            }
            return false
        }

        /// False for a row of a page covered by another one (drawn transparent).
        private static func isShown(_ view: NSView) -> Bool {
            var current: NSView? = view
            while let candidate = current {
                if candidate.isHidden || candidate.alphaValue < 0.01 || (candidate.layer?.opacity ?? 1) < 0.01 { return false }
                current = candidate.superview
            }
            return true
        }
    }
}
