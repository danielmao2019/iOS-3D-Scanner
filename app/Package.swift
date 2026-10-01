// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RGBDScanner",
    platforms: [.iOS(.v17)],
    products: [.library(name: "RGBDScanner", targets: ["RGBDScanner"])],
    targets: [
        .target(name: "RGBDScanner", swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
