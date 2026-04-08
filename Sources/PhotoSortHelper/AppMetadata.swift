import Foundation

enum AppMetadata {
    static let displayName = "Photos Library Sort Helper"

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
