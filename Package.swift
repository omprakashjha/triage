// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Triage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TriageCore", targets: ["TriageCore"]),
        .executable(name: "TriageApp", targets: ["TriageApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", exact: "4.2.2"),
    ],
    targets: [
        .target(
            name: "TriageCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "KeychainAccess", package: "KeychainAccess"),
            ],
            path: "TriageCore/Sources"
        ),
        .executableTarget(
            name: "TriageApp",
            dependencies: ["TriageCore"],
            path: "Triage",
            exclude: [],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        .testTarget(
            name: "TriageCoreTests",
            dependencies: ["TriageCore"],
            path: "TriageCore/Tests"
        ),
    ]
)
