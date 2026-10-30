// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DailyMapLineCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "DailyMapLineCore", targets: ["DailyMapLineCore"])],
    targets: [
        .target(name: "DailyMapLineCore"),
        .testTarget(name: "DailyMapLineCoreTests", dependencies: ["DailyMapLineCore"]),
    ]
)
