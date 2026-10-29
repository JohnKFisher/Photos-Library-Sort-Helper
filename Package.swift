// swift-tools-version: 6.2
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let generatedInfoPlist = packageRoot.appendingPathComponent(".build/BuildInfo.plist").path

let package = Package(
    name: "PhotosLibrarySortHelper",
    platforms: [
        .macOS(.v26),
        // The repository's Swift 6.2 package tools version predates the `.v27`
        // convenience constant. The string form keeps iOS 27 as the floor.
        .iOS("27.0")
    ],
    products: [
        .executable(name: "PhotosLibrarySortHelper", targets: ["PhotosLibrarySortHelper"]),
        .library(name: "PhotosSortCore", targets: ["PhotosSortCore"])
    ],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite"),
        .target(name: "PhotosSortCore", dependencies: ["CSQLite"], path: "Sources/PhotosSortCore"),
        .executableTarget(
            name: "PhotosLibrarySortHelper",
            dependencies: ["PhotosSortCore"],
            path: "Sources/PhotoSortHelper",
            resources: [
                .process("Assets.xcassets")
            ],
            linkerSettings: [
                // Embed Info.plist so the executable has a bundle identifier and usage strings.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", generatedInfoPlist
                ])
            ]
        ),
        .testTarget(
            name: "PhotosLibrarySortHelperTests",
            dependencies: ["PhotosLibrarySortHelper", "PhotosSortCore", "CSQLite"],
            path: "Tests/PhotosLibrarySortHelperTests"
        )
    ]
)
