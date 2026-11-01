import ProjectDescription

/// Third-party notices the apps ship in `Resources/Acknowledgements`: Ghostty's MIT license
/// (staged by `scripts/fetch-ghostty.sh`) and `OmnigentTerminalUI/THIRD_PARTY_NOTICES.md`.
public enum Acknowledgements {
  static let inputs: [FileListGlob] = [
    "$(SRCROOT)/Vendor/ghostty/out/LICENSE",
    "$(SRCROOT)/Packages/OmnigentTerminalUI/THIRD_PARTY_NOTICES.md",
  ]

  static let outputs: [Path] = [
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Acknowledgements/Ghostty-LICENSE.txt",
    "$(TARGET_BUILD_DIR)/$(UNLOCALIZED_RESOURCES_FOLDER_PATH)/Acknowledgements/OmnigentTerminalUI-THIRD_PARTY_NOTICES.md",
  ]

  /// Copies the notices into the app; fails the build when one is missing, so an app never ships
  /// libghostty without its license.
  public static let script = TargetScript.post(
    script: """
      set -euo pipefail
      dest="${TARGET_BUILD_DIR}/${UNLOCALIZED_RESOURCES_FOLDER_PATH}/Acknowledgements"
      mkdir -p "$dest"
      license="${SRCROOT}/Vendor/ghostty/out/LICENSE"
      if [ ! -f "$license" ]; then
        echo "error: $license is missing; run apps/apple/scripts/fetch-ghostty.sh" >&2
        exit 1
      fi
      cp "$license" "$dest/Ghostty-LICENSE.txt"
      cp "${SRCROOT}/Packages/OmnigentTerminalUI/THIRD_PARTY_NOTICES.md" \\
        "$dest/OmnigentTerminalUI-THIRD_PARTY_NOTICES.md"
      """,
    name: "Copy third-party notices",
    inputPaths: inputs,
    outputPaths: outputs
  )
}
