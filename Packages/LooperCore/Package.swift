// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "LooperCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [
        .library(name: "LooperCore", targets: ["LooperCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "LooperCore",
            dependencies: [.product(name: "Atomics", package: "swift-atomics")]
        ),
        .testTarget(name: "LooperCoreTests", dependencies: ["LooperCore"])
    ]
)
