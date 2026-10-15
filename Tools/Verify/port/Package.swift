// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "port",
    dependencies: [.package(path: "../../../Packages/Inochi2DKit")],
    targets: [.executableTarget(name: "port", dependencies: ["Inochi2DKit"])]
)
