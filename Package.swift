// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SensorSources",
    platforms: [.watchOS("27.0"), .iOS("27.0")],
    products: [
        .library(name: "SensorSources", targets: ["SensorSources"])
    ],
    targets: [
        .target(name: "SensorSources"),
        .testTarget(name: "SensorSourcesTests", dependencies: ["SensorSources"])
    ]
)
