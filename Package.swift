// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MBJFW",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "MBJFW", targets: ["MBJFW"]),
        .library(name: "MBJFWFrameBridge", type: .dynamic, targets: ["MBJFWFrameBridge"])
    ],
    dependencies: [],
    targets: [
        .executableTarget(name: "MBJFW", dependencies: ["CSQLite", "MBJFWFrameBridge"], path: "Sources/MBJFW", resources: [.copy("Resources/mbjfw-hid-arm64"), .copy("Resources/mbjfw-hid-x86_64"), .copy("Resources/appliance.apk")]),
        .target(
            name: "MBJFWFrameBridge",
            path: "NativeGameHost/FrameBridge",
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-fobjc-arc"])],
            linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("AppKit")]
        ),
        .systemLibrary(name: "CSQLite"),
        .testTarget(name: "MBJFWTests", dependencies: ["MBJFW", "MBJFWFrameBridge"], path: "Tests/MBJFWTests", resources: [.copy("Fixtures")])
    ],
    cxxLanguageStandard: .cxx17
)
