// swift-tools-version:5.6
import PackageDescription

let package = Package(
    name: "IOSBLELibrary",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .watchOS(.v6)
    ],
    products: [
        .library(name: "IOSBLELibrary", targets: ["IOSBLELibrary"]),
        .library(name: "iOS-BLE-Library-Mock", targets: ["iOS-BLE-Library-Mock"]),
    ],
    dependencies: [
        .package(url: "https://github.com/NordicSemiconductor/IOS-CoreBluetooth-Mock.git", from: "0.17.0"),
        .package(url: "https://github.com/NickKibish/CoreBluetoothMock-Collection.git", from: "1.0.0"),
        .package(url: "https://github.com/apple/swift-docc-plugin", from: "1.0.0"),
    ],
    targets: [
        .target(name: "IOSBLELibrary"),
        .target(name: "iOS-BLE-Library-Mock", dependencies: ["IOSBLELibrary", .product(name: "CoreBluetoothMock", package: "IOS-CoreBluetooth-Mock")]),
        .testTarget(name: "iOS-BLE-LibraryTests", dependencies: ["iOS-BLE-Library-Mock", .product(name: "CoreBluetoothMock-Collection", package: "CoreBluetoothMock-Collection")]),
    ]
)
