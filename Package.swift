// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "PlayerKit",
    platforms: [
        .iOS(.v16)
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
