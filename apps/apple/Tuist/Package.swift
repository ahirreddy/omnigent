// swift-tools-version: 6.0
import PackageDescription

#if TUIST
  import ProjectDescription

  let packageSettings = PackageSettings(productTypes: [:])
#endif

let package = Package(
  name: "OmnigentExternalDependencies",
  dependencies: []
)
