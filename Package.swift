// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Triage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TriageCore", targets: ["TriageCore"]),
        .library(name: "TriageBedrock", targets: ["TriageBedrock"]),
        .executable(name: "TriageApp", targets: ["TriageApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "6.29.3"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", exact: "4.2.2"),
        // Only TriageBedrock links this, so TriageCore and the whole test suite stay
        // SDK-free and fast to build. Pinned exactly: an SDK bump can change the
        // Smithy document API this bridges against.
        .package(url: "https://github.com/awslabs/aws-sdk-swift.git", exact: "1.7.72"),
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
        // The ONLY SDK-linked target. Everything with judgement in it — the prompt,
        // the schema, the merge rules — lives in TriageCore as pure code.
        .target(
            name: "TriageBedrock",
            dependencies: [
                "TriageCore",
                .product(name: "AWSBedrockRuntime", package: "aws-sdk-swift"),
                .product(name: "AWSBedrock", package: "aws-sdk-swift"),
            ],
            path: "TriageBedrock/Sources"
        ),
        .executableTarget(
            name: "TriageApp",
            dependencies: ["TriageCore", "TriageBedrock"],
            path: "Triage",
            exclude: [],
            swiftSettings: [
                .unsafeFlags(["-parse-as-library"])
            ]
        ),
        // Deliberately does NOT depend on TriageBedrock: the test suite must not link
        // the AWS SDK, or every run pays for it.
        .testTarget(
            name: "TriageCoreTests",
            dependencies: ["TriageCore"],
            path: "TriageCore/Tests"
        ),
        // Live integration tests. Every test here SKIPS unless TRIAGE_LIVE_BEDROCK=1,
        // so a normal `swift test` never makes a network call, needs credentials, or
        // spends money — but the transport stays verifiable on demand rather than by
        // assumption.
        .testTarget(
            name: "TriageBedrockTests",
            dependencies: ["TriageCore", "TriageBedrock"],
            path: "TriageBedrock/Tests"
        ),
    ]
)
