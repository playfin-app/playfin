import SwiftUI

/// Persistent but discreet banner at the top of the screen when the Jellyfin server is unreachable.
/// Shows "Server unreachable — showing saved content and downloads", with a Try again button.
struct OfflineBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "wifi.slash")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Colors.warning)

            Text("Server unreachable — showing saved content")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            Spacer()

            Button {
                Task {
                    await model.retryConnection()
                }
            } label: {
                HStack(spacing: 6) {
                    if model.isRetryingConnection {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .bold))
                    }
                    Text("Try again")
                        .font(.system(size: 12, weight: .semibold))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white.opacity(0.12))
                )
            }
            .buttonStyle(.plain)
            .disabled(model.isRetryingConnection)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Colors.background.opacity(0.95))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Theme.Colors.warning.opacity(0.4), lineWidth: 1)
                )
        )
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }
}
