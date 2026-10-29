import SwiftUI

/// "Loading…" placeholder that only shows up after a short wait, as in Apple's apps: a list that arrives quickly
/// goes straight to its content, with no spinner flashing in between.
struct LoadingStateView: View {
    var message: String?
    @State private var isVisible = false

    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.regular)
            if let message {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(isVisible ? 1 : 0)
        .task {
            try? await Task.sleep(for: .milliseconds(300))
            withAnimation(Theme.Motion.fade) { isVisible = true }
        }
    }
}
