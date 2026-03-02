// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ShamirSecretSharing",
    products: [
        .library(
            name: "ShamirSecretSharing",
            targets: ["ShamirSecretSharing"]),
    ],
    targets: [
        .target(
            name: "ShamirSecretSharing"),
        .testTarget(
            name: "ShamirSecretSharingTests",
            dependencies: ["ShamirSecretSharing"]),
    ]
)
