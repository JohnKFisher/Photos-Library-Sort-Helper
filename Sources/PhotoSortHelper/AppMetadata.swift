import Foundation

enum AppMetadata {
    static let displayName = "Photo Sort Helper"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.5"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var releaseLabel: String {
        "Version \(version) (Build \(build))"
    }
}
