// swift-tools-version:5.9
import PackageDescription

// The GitHub organization of the suite's repositories: the one name to change should it be renamed (the
// suite repository's scripts/rename-organization.sh does it in every repository).
let organization = "love-suite"

// Clipboard: Windows' clipboard history (Win+V) as an app of its own. Its logic stays UI-free in
// ClipboardCore; its settings are a library of their own, which Suite Settings reads for its Clipboard tab.
// Spotlight's clipboard history, which it turns off while it runs, is put back by Suite Guard should it vanish.
let package = Package(
    name: "Clipboard",
    defaultLocalization: "en",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClipboardSettings", targets: ["ClipboardSettings"]),
    ],
    dependencies: [
        .package(url: "https://github.com/\(organization)/suite-core", .upToNextMinor(from: "27.1.0-dev.1")),
        .package(url: "https://github.com/\(organization)/suite-guard", .upToNextMinor(from: "27.1.0-dev.1")),
    ],
    targets: [
        .target(name: "ClipboardSettings", dependencies: [.product(name: "SuiteCore", package: "suite-core")]),
        .target(name: "ClipboardCore",
                dependencies: ["ClipboardSettings", .product(name: "SuiteCore", package: "suite-core")]),
        .executableTarget(
            name: "Clipboard",
            dependencies: ["ClipboardCore", "ClipboardSettings", .product(name: "SuiteCore", package: "suite-core"),
                           .product(name: "SpotlightGuard", package: "suite-guard")],
            resources: [.process("Resources")],
            linkerSettings: [.linkedFramework("Carbon"), .linkedFramework("ServiceManagement")]
        ),
        .testTarget(name: "ClipboardCoreTests", dependencies: ["ClipboardCore", "ClipboardSettings"]),
    ]
)
