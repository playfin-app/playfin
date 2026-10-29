import AppKit
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
        static let favorite = Color.pink
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
    ///
    /// Springs, as in Apple's apps: they start fast, settle softly, and an interrupted animation (hovering
    /// across several cards, a quick second click) carries on from its current speed instead of jumping.
    /// With "Reduce motion" (System Settings › Accessibility › Display), every one becomes a short fade
    /// curve, and the panels only fade (no zoom).
    @MainActor
    enum Motion {
        /// Card and button reactions under the pointer.
        static var hover: Animation { reduced(0.15) ?? .snappy(duration: 0.2) }
        /// Most changes of state: pages of a menu, rows, filters, banners.
        static var standard: Animation { reduced(0.2) ?? .smooth(duration: 0.3) }
        /// Images that arrive (cross-fade from the BlurHash).
        static var fade: Animation { reduced(0.2) ?? .smooth(duration: 0.35) }
        /// Slow changes of the home banner.
        static var hero: Animation { reduced(0.3) ?? .smooth(duration: 0.8) }
        /// Player controls appearing or hiding.
        static var controls: Animation { reduced(0.15) ?? .smooth(duration: 0.25) }
        /// Panels that open over the player ("Stream details", subtitle settings).
        static var panel: Animation { reduced(0.15) ?? .snappy(duration: 0.3) }
        /// Centre icon of the player (play, pause, jump): quick in, softer out.
        static var splashIn: Animation { reduced(0.1) ?? .snappy(duration: 0.15) }
        static var splashOut: Animation { reduced(0.2) ?? .smooth(duration: 0.35) }

        /// Panels grow slightly while they appear, like Apple's popovers and sheets.
        static var panelTransition: AnyTransition {
            reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96))
        }

        /// Duration of the window fades (picture in picture, player closing).
        static var windowFade: TimeInterval { reduceMotion ? 0.1 : 0.25 }
        /// The window gliding into or out of picture in picture.
        static var pictureInPictureResize: TimeInterval { 0.4 }
        /// The video fading in once its first frame is decoded (black before: no sudden picture during the opening).
        static var videoReveal: TimeInterval { reduceMotion ? 0.15 : 0.35 }
        /// Player opening: a plain fade, a little slower than the closing one.
        static var windowOpenFade: TimeInterval { reduceMotion ? 0.15 : 0.4 }

        static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

        private static func reduced(_ duration: Double) -> Animation? {
            reduceMotion ? .easeInOut(duration: duration) : nil
        }

        static let controlsHideDelay: Duration = .seconds(3)
    }
}
