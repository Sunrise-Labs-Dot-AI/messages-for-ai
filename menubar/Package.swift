// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "MessagesForAIMenu",
  platforms: [.macOS(.v13)],
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
