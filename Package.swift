// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sub2Bar",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Sub2Bar", targets: ["Sub2Bar"])],
    targets: [
        .target(name: "Sub2BarCore"),
        .executableTarget(name: "Sub2Bar", dependencies: ["Sub2BarCore"]),
        .testTarget(name: "Sub2BarCoreTests", dependencies: ["Sub2BarCore"]),
        .testTarget(name: "Sub2BarWindowTests", dependencies: ["Sub2Bar", "Sub2BarCore"])
    ]
)
