// swift-tools-version:5.9
import PackageDescription

// CenterKit: what a Mac app needs to speak the Center protocol (../../docs/protocol.md).
// The client, the network of nodes an app is connected to (a Center server and other apps,
// found over Bonjour), the local node an app serves its own schemas from, and the settings
// section. Apps copy this folder in with ../vendor.sh until it has a public home.
let package = Package(
  name: "CenterKit",
  platforms: [.macOS(.v14)],
  products: [.library(name: "CenterKit", targets: ["CenterKit"])],
  targets: [
    .target(name: "CenterKit", path: "Sources/CenterKit"),
    .testTarget(name: "CenterKitTests", dependencies: ["CenterKit"], path: "Tests/CenterKitTests"),
  ]
)
