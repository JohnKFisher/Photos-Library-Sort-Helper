import AppKit
import SwiftUI

enum UITheme {
    static let keep = Color(red: 0.16, green: 0.66, blue: 0.40)
    static let discard = Color(red: 0.84, green: 0.29, blue: 0.24)
    static let suggested = Color(red: 0.88, green: 0.58, blue: 0.16)
    static let mediaBadgeBackground = Color(nsColor: .controlAccentColor).opacity(0.85)

    static func appBackground(for _: ColorScheme) -> Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static func sidebarBackground(for _: ColorScheme) -> Color {
        Color(nsColor: .underPageBackgroundColor)
    }

    static func sidebarSectionBackground(for _: ColorScheme) -> Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static func secondaryText(for _: ColorScheme) -> Color {
        Color(nsColor: .secondaryLabelColor)
    }

    static func sectionStroke(for _: ColorScheme) -> Color {
        Color(nsColor: .separatorColor)
    }

    static func cardBackground(for _: ColorScheme, isHighlighted: Bool) -> Color {
        isHighlighted ? Color(nsColor: .selectedContentBackgroundColor).opacity(0.32) : Color(nsColor: .controlBackgroundColor)
    }

    static func cardImageBackground(for _: ColorScheme) -> Color {
        Color(nsColor: .quaternaryLabelColor).opacity(0.14)
    }

    static func metricChipBackground(for _: ColorScheme) -> Color {
        Color(nsColor: .textBackgroundColor)
    }
}
