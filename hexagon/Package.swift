// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "hexagon",
    platforms: [.iOS("26.4")],
    products: [
        .library(name: "hexagon", targets: ["hexagon"]),
    ],
    targets: [
        .target(name: "hexagon", path: "Sources"),
    ]
)
