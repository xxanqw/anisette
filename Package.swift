// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "anisette",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
    ],
    targets: [
        .systemLibrary(name: "CADI", path: "Sources/CADI"),
        .executableTarget(
            name: "AnisetteServer",
            dependencies: [
                "CADI",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.unsafeFlags(["-L/usr/local/lib"])]
        ),
        .testTarget(
            name: "AnisetteServerTests",
            dependencies: ["AnisetteServer"],
            linkerSettings: [.unsafeFlags(["-L/usr/local/lib"])]
        ),
    ]
)