// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReplyKit",
    platforms: [.iOS(.v16), .macOS(.v14)],
    products: [.library(name: "ReplyKit", targets: ["ReplyKit"])],
    targets: [
        .target(name: "ReplyKit"),
        .testTarget(name: "ReplyKitTests", dependencies: ["ReplyKit"])
    ]
)
