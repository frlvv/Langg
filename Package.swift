// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Langg",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Langg", targets: ["Langg"])],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(name: "LanggCore"),
        .executableTarget(name: "Langg", dependencies: [
            "LanggCore", .product(name: "Sparkle", package: "Sparkle")
        ], linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("ApplicationServices"),
            .linkedFramework("Carbon"), .linkedFramework("ServiceManagement"),
            .linkedFramework("IOKit"),
            .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])
        ]),
        .testTarget(name: "LanggCoreTests", dependencies: ["LanggCore"]),
        .testTarget(name: "LanggTests", dependencies: ["Langg"])
    ]
)
