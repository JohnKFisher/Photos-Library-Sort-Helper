// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "PhotosLibrarySortHelper",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "PhotosLibrarySortHelper", targets: ["PhotosLibrarySortHelper"])
    ],
    targets: [
        .executableTarget(
            name: "PhotosLibrarySortHelper",
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
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "PhotosLibrarySortHelperTests",
            dependencies: ["PhotosLibrarySortHelper"],
            path: "Tests/PhotosLibrarySortHelperTests"
        )
    ]
)
