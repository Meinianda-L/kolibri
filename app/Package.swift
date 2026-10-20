// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Kolibri",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Kolibri", targets: ["Kolibri"]),
    ],
    dependencies: [
        .package(url: "https://github.com/grpc/grpc-swift-2.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", from: "2.0.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", from: "1.28.0"),
    ],
    targets: [
        // Pure logic (keymap engine, models). No UI, no gRPC: unit-testable.
        .target(name: "KolibriCore"),
        .executableTarget(
            name: "Kolibri",
            dependencies: [
                "KolibriCore",
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(name: "KolibriCoreTests", dependencies: ["KolibriCore"]),
    ]
)
