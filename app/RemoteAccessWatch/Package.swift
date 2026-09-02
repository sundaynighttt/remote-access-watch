// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "RemoteAccessWatch",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "RemoteAccessWatch", targets: ["RemoteAccessWatch"])
    ],
    targets: [
        .executableTarget(name: "RemoteAccessWatch"),
        .testTarget(
            name: "RemoteAccessWatchTests",
            dependencies: ["RemoteAccessWatch"]
        )
    ],
    swiftLanguageModes: [.v5]
)
