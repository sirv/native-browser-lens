// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "NativeBrowserLens",
    platforms: [.macOS(.v15)],
    products: [.library(name: "LensCore", targets: ["LensCore"]), .executable(name: "NativeBrowserLens", targets: ["NativeLens"]), .executable(name: "lens-host", targets: ["LensHost"])],
    targets: [
        .systemLibrary(name: "CSQLite"),
        .target(name: "LensCore", dependencies: ["CSQLite"]),
        .executableTarget(name: "NativeLens", dependencies: ["LensCore"]),
        .executableTarget(name: "LensHost", dependencies: ["LensCore"]),
        .testTarget(name: "LensCoreTests", dependencies: ["LensCore"]),
        .testTarget(name: "NativeLensTests", dependencies: ["NativeLens", "LensCore"])
    ],
    swiftLanguageModes: [.v5]
)
