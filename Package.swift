// swift-tools-version: 6.0
import PackageDescription
var coreDependencies: [Target.Dependency] = ["CSQLite"]
#if os(Linux)
coreDependencies.append("CLinux")
#endif
var products: [Product] = [.library(name: "LensCore", targets: ["LensCore"]), .executable(name: "lens-host", targets: ["LensHost"]), .executable(name: "lens-evidence", targets: ["LensEvidence"])]
var targets: [Target] = [
    .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3"),
    .target(name: "LensCore", dependencies: coreDependencies),
    .executableTarget(name: "LensHost", dependencies: ["LensCore"]),
    .executableTarget(name: "LensEvidence", dependencies: ["LensCore"]),
    .testTarget(name: "LensCoreTests", dependencies: ["LensCore"])
]
#if os(Linux)
products.append(.executable(name: "lens-service", targets: ["LensService"]))
targets.append(.systemLibrary(name: "CLinux", pkgConfig: "openssl"))
targets.append(.executableTarget(name: "LensService", dependencies: ["LensCore"]))
#else
products.append(.executable(name: "NativeBrowserLens", targets: ["NativeLens"]))
targets.append(.executableTarget(name: "NativeLens", dependencies: ["LensCore"]))
targets.append(.testTarget(name: "NativeLensTests", dependencies: ["NativeLens", "LensCore"]))
#endif
let package = Package(
    name: "NativeBrowserLens",
    platforms: [.macOS(.v15)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
