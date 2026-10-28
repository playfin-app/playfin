import SwiftUI

/// Empty, offline or error state shared by all screens: a title, an explanation, a "Try again" button.
struct ErrorStateView: View {
    let title: String
    let message: String
    var systemImage = "exclamationmark.triangle"
    var retry: (() -> Void)?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        } actions: {
            if let retry {
                Button("Try again", action: retry)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Text to show when a list is empty, depending on whether the server is unreachable.
enum EmptyStateText {
    static func message(isOffline: Bool, offline: String, online: String) -> String {
        isOffline ? offline : online
    }
}
