// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Arena",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Arena", targets: ["Arena"])],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(name: "Arena", dependencies: [
            .product(name: "MCP", package: "swift-sdk"),
            .product(name: "Hummingbird", package: "hummingbird")
        ], exclude: ["Assets.xcassets"], resources: [.copy("Resources")]),
        .testTarget(name: "ArenaTests", dependencies: ["Arena"])
    ]
)
