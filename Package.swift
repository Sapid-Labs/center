// swift-tools-version:5.9
import PackageDescription

// CenterKit for an app's Package.swift:
//   .package(url: "https://github.com/Sapid-Labs/center", from: "0.2.0")
// The package itself is swift/CenterKit (its tests run there).
let package = Package(
  name: "CenterKit",
  platforms: [.macOS(.v14)],
  products: [.library(name: "CenterKit", targets: ["CenterKit"])],
  targets: [.target(name: "CenterKit", path: "swift/CenterKit/Sources/CenterKit")]
)
