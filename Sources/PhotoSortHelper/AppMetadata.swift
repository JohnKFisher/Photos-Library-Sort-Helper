import Foundation

enum AppMetadata {
    static let displayName = "Photos Library Sort Helper"
    static let repositoryURL = URL(string: "https://github.com/JohnKFisher/Photos-Library-Sort-Helper")!
    static let copyrightNotice = "Copyright © 2026 John Kenneth Fisher"
    static let aboutSummary = "Review similar media from Apple Photos or a regular folder safely. Nothing is deleted automatically; follow-up actions only happen when you explicitly queue albums or commit sibling queue folders."

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "2.1.0"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var releaseLabel: String {
        "Version \(version) (Build \(build))"
    }
}
