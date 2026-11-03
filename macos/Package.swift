// swift-tools-version: 6.2
import PackageDescription

// Strict by default: Swift 6 data-race checking and every warning is an error.
let strict: [SwiftSetting] = [
  .swiftLanguageMode(.v6),
  .treatAllWarnings(as: .error),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("MemberImportVisibility"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .strictMemorySafety(),
]

let package = Package(
  name: "Meter",
  platforms: [.macOS(.v15)],
  targets: [
    // Pure logic: config, credentials, usage fetching, scheduling. No AppKit.
    .target(name: "MeterCore", swiftSettings: strict),
    // Menu bar item, menu, settings window. Everything here is main-actor by default.
    .target(
      name: "MeterUI",
      dependencies: ["MeterCore"],
      swiftSettings: strict + [.defaultIsolation(MainActor.self)]
    ),
    // Composition root: builds real dependencies and runs the app.
    .executableTarget(
      name: "Meter",
      dependencies: ["MeterCore", "MeterUI"],
      swiftSettings: strict + [.defaultIsolation(MainActor.self)]
    ),
    .testTarget(name: "MeterCoreTests", dependencies: ["MeterCore"], swiftSettings: strict),
  ]
)
