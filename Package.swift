// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pane",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // Keep SwiftPM useful for the non-UI test suite without exposing a
        // bare GUI executable. The runnable product is Pane.app in the Xcode
        // project, where macOS supplies a real bundle identifier and lifecycle.
        .library(name: "PaneCore", targets: ["Pane"])
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.14.0")
    ],
    targets: [
        .target(
            name: "Pane",
            dependencies: ["SwiftTerm"],
            path: "Pane",
            exclude: ["Info.plist", "App/PaneApp.swift", "Assets.xcassets"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PaneTests",
            dependencies: ["Pane"],
            path: "Tests/PaneTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
