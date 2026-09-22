// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Allomer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "allomer", targets: ["ConvertCLI"]),
        .executable(name: "AllomerApp", targets: ["ConvertApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2")
    ],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "ConfigBridge", cxxSettings: [.define("TOML_MAX_NESTED_VALUES", to: "64")]),
        .target(name: "ConversionCore", dependencies: ["Yams", "ConfigBridge", "CArchive"], resources: [.process("Resources")]),
        .executableTarget(name: "ConvertCLI", dependencies: ["ConversionCore"]),
        .executableTarget(name: "ConvertApp", dependencies: ["ConversionCore"]),
        .testTarget(name: "ConversionCoreTests", dependencies: ["ConversionCore"]),
        .testTarget(name: "ConvertAppTests", dependencies: ["ConvertApp"])
    ],
    cxxLanguageStandard: .cxx17
)
