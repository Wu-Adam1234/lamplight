// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Lamplight",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Lamplight", targets: ["Lamplight"])
    ],
    targets: [
        // Pure logic with no AppKit, so it can be unit tested.
        .target(name: "LamplightCore"),
        // The menu bar app itself.
        .executableTarget(
            name: "Lamplight",
            dependencies: ["LamplightCore"],
            linkerSettings: [.linkedFramework("IOKit"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(name: "LamplightCoreTests", dependencies: ["LamplightCore"])
    ]
)
