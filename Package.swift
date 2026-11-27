// swift-tools-version: 6.4
import PackageDescription

let package = Package(
    name: "Helm",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelmCore", targets: ["HelmCore"]),
        .library(name: "HelmIsolation", targets: ["HelmIsolation"]),
        .library(name: "HelmBrowser", targets: ["HelmBrowser"]),
        .library(name: "HelmAppCore", targets: ["HelmAppCore"]),
        .executable(name: "helmctl", targets: ["HelmCLI"]),
    ],
    targets: [
        .target(
            name: "HelmCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "HelmIsolation",
            dependencies: ["HelmCore"],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "HelmBrowser",
            dependencies: ["HelmCore"]
        ),
        .target(
            name: "HelmAppCore",
            dependencies: ["HelmCore", "HelmIsolation", "HelmBrowser"],
            path: "Sources/HelmApp",
            exclude: ["HelmApp.swift", "HelmMain.swift"]
        ),
        .executableTarget(
            name: "HelmCLI",
            dependencies: ["HelmCore", "HelmIsolation", "HelmBrowser"]
        ),
        .testTarget(
            name: "HelmCoreTests",
            dependencies: ["HelmCore", "HelmIsolation", "HelmBrowser"]
        ),
        .testTarget(
            name: "HelmIsolationTests",
            dependencies: ["HelmIsolation", "HelmCore"]
        ),
        .testTarget(
            name: "HelmBrowserTests",
            dependencies: ["HelmCore", "HelmBrowser"]
        ),
        .testTarget(
            name: "HelmAppTests",
            dependencies: ["HelmAppCore", "HelmCore", "HelmIsolation", "HelmBrowser"]
        ),
    ]
)
