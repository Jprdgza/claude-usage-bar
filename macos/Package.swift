// swift-tools-version:6.0
import Foundation
import PackageDescription

var targets: [Target] = [
    // Pure logic: config, defensive decoding, usage/pace math, token + caching analysis.
    // No AppKit/WebKit, so everything here is unit-testable.
    .target(name: "UsageCore"),
    .testTarget(name: "UsageCoreTests", dependencies: ["UsageCore"], exclude: ["Fixtures"]),
]
var appDependencies: [Target.Dependency] = ["UsageCore"]
targets.append(.executableTarget(name: "ClaudeUsageBar", dependencies: appDependencies))

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeUsageBar", targets: ["ClaudeUsageBar"]),
        .library(name: "UsageCore", targets: ["UsageCore"]),
    ],
    targets: targets,
    swiftLanguageModes: [.v5]
)
