import SwiftUI

/// Minimal design system: a single source for colours, spacing, radii and animations.
/// Every screen uses these values instead of hard-coded numbers, to stay consistent.
enum Theme {
    enum Colors {
        /// Dark background shared by all screens (home, grids, details).
        static let background = Color(red: 0.08, green: 0.09, blue: 0.11)
        /// Background of cards, fields and pills.
        static let surface = Color.white.opacity(0.08)
        /// Single accent colour (progress, selection, focus): Jellyfin's blue (#00A4DC).
        static let accent = Color(red: 0.0, green: 0.643, blue: 0.863)
        /// Jellyfin's secondary purple (#AA5CC3), for brand gradients.
        static let accentSecondary = Color(red: 0.667, green: 0.361, blue: 0.765)
        /// Users' rating (star).
        static let rating = Color(red: 1.0, green: 0.78, blue: 0.2)
        static let textPrimary = Color.white
        static let textSecondary = Color.white.opacity(0.7)
        static let textTertiary = Color.white.opacity(0.5)
        static let watched = Color.green
        static let error = Color.red
        static let warning = Color(red: 1.0, green: 0.62, blue: 0.2)
        static let reachable = Color.green
        static let unreachable = Color.red
        static let checking = Color.gray
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 16
        static let lg: CGFloat = 24
        static let xl: CGFloat = 40
        /// Horizontal margin of the detail screens.
        static let screenMargin: CGFloat = 48
    }

    enum Typography {
        /// Title of the large home visual (when there is no logo).
        static let hero = Font.system(size: 44, weight: .bold)
        /// Title of a detail page.
        static let detail = Font.system(size: 42, weight: .bold)
        /// Title of a row or a section.
        static let section = Font.title2.bold()
    }

    /// Card sizes (2:3 posters, 16:9 thumbnails).
    enum Layout {
        static let posterWidth: CGFloat = 160
        static let continueWidth: CGFloat = 300
    }

    enum Radius {
        static let small: CGFloat = 6
        static let card: CGFloat = 8
        static let panel: CGFloat = 16
    }

    /// Shared durations and curves: the same gestures feel the same everywhere.
    enum Motion {
        static let hover = Animation.snappy(duration: 0.18)
        static let standard = Animation.smooth(duration: 0.25)
        static let fade = Animation.easeOut(duration: 0.3)
        static let hero = Animation.easeInOut(duration: 0.7)
        static let controls = Animation.easeOut(duration: 0.2)
        /// Delay before the player controls are hidden (3 s).
        static let controlsHideDelay: Duration = .seconds(3)
    }
}
