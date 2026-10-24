// swift-tools-version: 6.2
import PackageDescription

let package = Package(
  name: "Loops",
  platforms: [.macOS(.v26)],
  targets: [
    .executableTarget(name: "Loops", path: "Sources/Loops"),
    .testTarget(name: "LoopsTests", dependencies: ["Loops"], path: "Tests/LoopsTests"),
  ],
  swiftLanguageModes: [.v5]
)
