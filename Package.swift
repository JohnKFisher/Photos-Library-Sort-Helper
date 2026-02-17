// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PhotoSortHelper",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "PhotoSortHelper", targets: ["PhotoSortHelper"])
    ],
    targets: [
        .executableTarget(
            name: "PhotoSortHelper",
            linkerSettings: [
                // Embed Info.plist so the executable has a bundle identifier and usage strings.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/Info.plist"
                ])
            ]
        )
    ]
)
