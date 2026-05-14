// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "iMessageDraftsMenu",
  platforms: [.macOS(.v13)],
  products: [
    .executable(name: "iMessageDraftsMenu", targets: ["iMessageDraftsMenu"]),
  ],
  targets: [
    .executableTarget(
      name: "iMessageDraftsMenu",
      path: "Sources/iMessageDraftsMenu"
    ),
  ]
)
