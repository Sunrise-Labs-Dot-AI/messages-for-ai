// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MessagesForAIMenu",
  // macOS 14 (Sonoma) required for SwiftUI dismissWindow environment
  // and the modern Window scene APIs. Released Sept 2023 — fine for a
  // v0.3.0 utility shipping in 2026.
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "MessagesForAIMenu", targets: ["MessagesForAIMenu"]),
  ],
  targets: [
    .executableTarget(
      name: "MessagesForAIMenu",
      path: "Sources/MessagesForAIMenu"
    ),
  ]
)
