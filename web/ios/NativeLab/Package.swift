// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "NativeLabCore",
  platforms: [.iOS("18.0"), .macOS(.v13)],
  products: [.library(name: "NativeLabCore", targets: ["NativeLabCore"])],
  targets: [
    .target(name: "NativeLabCore"),
    .testTarget(name: "NativeLabCoreTests", dependencies: ["NativeLabCore"]),
  ]
)
