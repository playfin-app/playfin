import SwiftUI

/// Round avatar: profile picture if the server has one, otherwise the initials.
struct ProfileAvatar: View {
    let profile: ServerProfile?
    var imageURL: URL?
    var size: CGFloat = 28

    var body: some View {
        ZStack {
            Circle().fill(.tint.opacity(0.85))
            if let imageURL {
                AsyncArtwork(url: imageURL, contentMode: .fill) { initials }
                    .clipShape(Circle())
            } else {
                initials
            }
        }
        .frame(width: size, height: size)
    }

    private var initials: some View {
        Text(profile?.initials ?? "?")
            .font(.system(size: size * 0.42, weight: .bold))
            .foregroundStyle(.white)
    }
}

/// Colour dot: reachable (green), unreachable (red), check in progress (grey).
struct StatusDot: View {
    let status: ProfileStatus?

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(color)
            .help(helpText)
    }

    private var color: Color {
        switch status {
        case .reachable: return Theme.Colors.reachable
        case .unreachable: return Theme.Colors.unreachable
        default: return Theme.Colors.checking
        }
    }

    private var helpText: String {
        switch status {
        case .reachable(let label): return "Reachable (\(label))"
        case .unreachable: return "Unreachable"
        default: return "Checking…"
        }
    }
}
