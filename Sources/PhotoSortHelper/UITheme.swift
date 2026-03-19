import SwiftUI

enum UITheme {
    static let keep = Color(red: 0.16, green: 0.66, blue: 0.40)
    static let discard = Color(red: 0.84, green: 0.29, blue: 0.24)
    static let suggested = Color(red: 0.88, green: 0.58, blue: 0.16)
    static let mediaBadgeBackground = Color.black.opacity(0.68)

    static func appBackground(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.10, green: 0.11, blue: 0.14)
        }
        return Color(red: 0.94, green: 0.96, blue: 0.98)
    }

    static func sidebarBackground(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.13, green: 0.15, blue: 0.19)
        }
        return Color(red: 0.96, green: 0.97, blue: 0.99)
    }

    static func sidebarSectionBackground(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.05)
        }
        return Color.white.opacity(0.84)
    }

    static func secondaryText(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color.white.opacity(0.72)
        }
        return Color.black.opacity(0.60)
    }

    static func cardBackground(for colorScheme: ColorScheme, isHighlighted: Bool) -> Color {
        if isHighlighted {
            if colorScheme == .dark {
                return Color(red: 0.22, green: 0.25, blue: 0.33)
            }
            return Color(red: 0.89, green: 0.94, blue: 1.0)
        }
        if colorScheme == .dark {
            return Color(red: 0.15, green: 0.17, blue: 0.22)
        }
        return Color(red: 0.97, green: 0.98, blue: 0.995)
    }

    static func cardImageBackground(for colorScheme: ColorScheme) -> Color {
        if colorScheme == .dark {
            return Color(red: 0.19, green: 0.22, blue: 0.28)
        }
        return Color(red: 0.92, green: 0.95, blue: 0.99)
    }
}
