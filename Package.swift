// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Roomfill",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "RoomfillCore"),
        .executableTarget(name: "rfprobe", dependencies: ["RoomfillCore"]),
        .executableTarget(name: "Roomfill", dependencies: ["RoomfillCore"]),
        .testTarget(name: "RoomfillCoreTests", dependencies: ["RoomfillCore"]),
    ],
    swiftLanguageModes: [.v5]
)
