// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Inochi2DKit",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [
        .library(name: "Inochi2DKit", targets: ["Inochi2DKit"]),
    ],
    targets: [
        .target(name: "Inochi2DKit"),
        .testTarget(name: "Inochi2DKitTests", dependencies: ["Inochi2DKit"]),
    ]
)
