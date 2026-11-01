import ProjectDescription

let tuist = Tuist(
  project: .tuist(
    compatibleXcodeVersions: .upToNextMajor("27.0"),
    swiftVersion: "6.0"
  )
)
