// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "IOSBLELibrary",
    // Arccos (Wave C3): the app's deployment target is iOS 17, and the fork's connect and
    // disconnect contracts are written against iOS 17 CoreBluetooth (auto-reconnect, the
    // timestamp/isReconnecting disconnect callback). macOS 14 / watchOS 10 are the matching
    // releases. Upstream: iOS 13 / macOS 10.15 / watchOS 6.
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "IOSBLELibrary", targets: ["IOSBLELibrary"]),
        .library(name: "iOS-BLE-Library-Mock", targets: ["iOS-BLE-Library-Mock"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git",
                 .upToNextMajor(from: "1.0.6")
        ),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.5.0"),
    ],
    targets: [
        // Arccos: target/product renamed from upstream's "iOS-BLE-Library" so the
        // app keeps `import IOSBLELibrary`; the source path stays upstream's so
        // future upstream merges apply cleanly.
        .target(name: "IOSBLELibrary", path: "Sources/iOS-BLE-Library"),
        .target(
            name: "iOS-BLE-Library-Mock",
            dependencies: [
                .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock"),
            ],
            swiftSettings: [.define("MOCK_TRANSPORT")],
            plugins: ["MockGenerator"]
        ),
        .executableTarget(name: "MockGeneratorTool"),
        .plugin(
            name: "MockGenerator",
            capability: .buildTool(),
            dependencies: ["MockGeneratorTool"]
        ),
        .testTarget(
            name: "iOS-BLE-LibraryTests",
            dependencies: ["iOS-BLE-Library-Mock"]
        ),
    ]
)
