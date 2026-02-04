// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [
        .iOS(.v13)
    ],
    products: [
        .library(
            name: "PlayerKit",
            targets: ["PlayerKit"]
        )
    ],
    targets: [
        .target(
            name: "PlayerKit",
            path: "Sources"
        )
    ]
)
