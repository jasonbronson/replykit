// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReplyKitDemo",
    platforms: [.macOS(.v14)],
    dependencies: [.package(path: "../..")],
    targets: [.executableTarget(name: "ReplyKitDemo", dependencies: [.product(name: "ReplyKit", package: "ReplyKit")])]
)
