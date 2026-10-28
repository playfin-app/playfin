import SwiftUI
import AppKit

/// Escape goes back to the previous page of the main window (detail → grid), whatever has the focus.
/// Not while typing in a field, nor when a sheet is open (they handle Escape themselves).
struct EscapeToGoBack: NSViewRepresentable {
    let goBack: () -> Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.goBack = goBack
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak coordinator] event in
            MainActor.assumeIsolated {
                guard let coordinator, event.keyCode == 53,
                      event.modifierFlags.isDisjoint(with: [.command, .option, .control, .shift]),
                      let window = coordinator.view?.window, event.window === window,
                      window.attachedSheet == nil, !(window.firstResponder is NSText)
                else { return event }
                return coordinator.goBack() ? nil : event
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.goBack = goBack
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
        var goBack: () -> Bool = { false }
    }
}
