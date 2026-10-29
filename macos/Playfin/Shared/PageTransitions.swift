import SwiftUI
import AppKit
import QuartzCore

/// A page opened over the first page of a section (see `LibraryView`).
///
/// The pages are stacked by the app itself instead of `NavigationStack`, which changes pages at once on macOS:
/// every opened page stays alive under the next one (scroll position kept), so that the changes can fade, and
/// so that the two-finger swipe shows the real previous page under the one leaving.
struct OpenedPage: Identifiable, Equatable {
    let id = UUID()
    let route: Route
}

/// The two-finger swipe back. The pages are moved by Core Animation, outside SwiftUI: each page is in its own
/// AppKit view (`PageHost`), whose layer moves in one piece. Moved by SwiftUI, the text, the scroll areas and
/// the pictures followed the fingers one after the other.
@MainActor
@Observable
final class SwipeBack {
    /// True during a swipe: the page under the top one is shown.
    private(set) var isActive = false

    @ObservationIgnored private var hosts: [UUID: WeakPageHost] = [:]
    @ObservationIgnored private weak var moving: PageHostView?
    @ObservationIgnored private weak var revealed: PageHostView?
    @ObservationIgnored private var slides = true

    fileprivate func register(_ view: PageHostView, for id: UUID) {
        hosts[id] = WeakPageHost(view: view)
        hosts = hosts.filter { $0.value.view != nil }
    }

    /// `top`: the page leaving. `below`: the one it uncovers.
    func begin(top: UUID, below: UUID) {
        moving = hosts[top]?.view
        revealed = hosts[below]?.view
        slides = !Theme.Motion.reduceMotion
        isActive = true
        move(to: 0)
    }

    /// 0: the page is in place. 1: it has left on the right.
    func move(to progress: CGFloat) {
        guard let moving else { return }
        // The whole width of the page, part under the sidebar included: nothing of it stays on screen at the end.
        let width = moving.bounds.width
        withoutActions {
            if slides {
                moving.shift(by: progress * width)
                // The page below comes from a little to the left, and lights up as the top one leaves.
                revealed?.shift(by: -(1 - progress) * width * 0.25)
            } else {
                moving.hosting.alphaValue = 1 - progress
            }
            revealed?.dim(0.35 * (1 - progress))
        }
    }

    /// Puts the pages back in place. The page that left is not moved back: it is being closed.
    func finish(pageClosed: Bool) {
        withoutActions {
            if !pageClosed {
                moving?.shift(by: 0)
                moving?.hosting.alphaValue = 1
            }
            revealed?.shift(by: 0)
            revealed?.dim(0)
        }
        moving = nil
        revealed = nil
        isActive = false
    }

    private func withoutActions(_ change: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        change()
        CATransaction.commit()
    }
}

private struct WeakPageHost {
    weak var view: PageHostView?
}

/// A page in its own AppKit view (an `NSHostingView` inside a container moved by `SwipeBack`).
/// `isShown` false: the page is hidden for AppKit too (no click, no mouse wheel, nothing drawn).
struct PageHost<Content: View>: NSViewRepresentable {
    let id: UUID
    let isShown: Bool
    let swipe: SwipeBack
    let content: Content

    func makeNSView(context: Context) -> PageHostView {
        let hosting = NSHostingView(rootView: content)
        // The page takes the size it is given, and leaves the window's toolbar and title to the main view.
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        // Its margins (toolbar, sidebar) are given by the main view: never worked out again here.
        hosting.safeAreaRegions = []
        let view = PageHostView(hosting: hosting)
        view.isHidden = !isShown
        swipe.register(view, for: id)
        return view
    }

    func updateNSView(_ view: PageHostView, context: Context) {
        (view.hosting as? NSHostingView<Content>)?.rootView = content
        view.isHidden = !isShown
        swipe.register(view, for: id)
    }
}

/// Container of a page: moved and darkened by `SwipeBack`.
final class PageHostView: NSView {
    let hosting: NSView
    private let shade = PassThroughView()

    init(hosting: NSView) {
        self.hosting = hosting
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = false
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        shade.wantsLayer = true
        shade.layer?.backgroundColor = NSColor.black.cgColor
        shade.alphaValue = 0
        shade.autoresizingMask = [.width, .height]
        addSubview(shade)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        hosting.frame = bounds
        shade.frame = bounds
    }

    fileprivate func shift(by x: CGFloat) {
        layer?.sublayerTransform = CATransform3DMakeTranslation(x, 0, 0)
    }

    fileprivate func dim(_ amount: CGFloat) {
        shade.alphaValue = amount
    }
}

/// Draws without catching any click.
private final class PassThroughView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// Link to a page, like `NavigationLink(value:)`: the page opens over the current one with a fade.
struct RouteLink<Label: View>: View {
    @Environment(AppModel.self) private var model
    let route: Route
    let label: Label

    init(value: Route, @ViewBuilder label: () -> Label) {
        route = value
        self.label = label()
    }

    var body: some View {
        Button { model.openPage(route) } label: { label }
    }
}

extension RouteLink where Label == Text {
    init(_ title: String, value: Route) {
        self.init(value: value) { Text(title) }
    }
}
