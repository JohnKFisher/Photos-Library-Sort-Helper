import Foundation

enum ReleaseVersioning {
    static func versionInfo(from plist: [String: Any]) -> (marketingVersion: String, build: String)? {
        guard
            let marketingVersion = plist["CFBundleShortVersionString"] as? String,
            let build = plist["CFBundleVersion"] as? String
        else {
            return nil
        }

        return (marketingVersion, build)
    }

    static func incrementedReleaseVersion(marketingVersion: String, build: String) -> (marketingVersion: String, build: String)? {
        let parts = marketingVersion.split(separator: ".")
        guard parts.count == 3 else {
            return nil
        }

        guard
            let major = Int(parts[0]),
            let minor = Int(parts[1]),
            let patch = Int(parts[2]),
            let buildNumber = Int(build)
        else {
            return nil
        }

        return ("\(major).\(minor).\(patch + 1)", "\(buildNumber + 1)")
    }
}
