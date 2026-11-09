#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentWorkspaceUI

  // Measures text as AppKit does.
  // swiftlint:disable legacy_objc_type

  /// The viewer's header with Comments, Source and Edit beside the file's name.
  @MainActor
  @Suite("Viewer header", .serialized)
  struct ViewerHeaderTests {
    init() {
      UserDefaults.standard.removeObject(forKey: "workspace.fileViewMode")
      UserDefaults.standard.removeObject(forKey: "workspace.showsComments")
    }

    private static let reviewedFile = WorkspaceFile(
      path: "poems/haiku.txt",
      byteCount: 9, preview: .text(TextPreview(text: "old pond\n", lineCount: 1)))

    private func viewer(width: CGFloat) -> OffscreenWindow<FileViewerView> {
      var actions = WorkspaceActions()
      actions.canEdit = true
      let editor = ReviewFixtures.editor()
      return OffscreenWindow(
        FileViewerView(
          file: Self.reviewedFile, source: SampleWorkspaceDataSource(), actions: actions,
          editor: editor, review: ReviewFixtures.context()),
        width: width, height: 320)
    }

    /// The header's controls: Comments, the mode picker and the actions menu.
    private func headerControls(_ screen: OffscreenWindow<FileViewerView>) -> [CGRect] {
      Array(screen.controls.prefix(3))
    }

    private func titleWidth() -> CGFloat {
      let headline = NSFont.preferredFont(forTextStyle: .headline)
      let caption = NSFont.preferredFont(forTextStyle: .caption1)
      return max(
        ("haiku.txt" as NSString).size(withAttributes: [.font: headline]).width,
        ("poems/haiku.txt" as NSString).size(withAttributes: [.font: caption]).width)
    }

    @Test(
      "the controls never crush the file's name and path at any width",
      arguments: [260.0, 300.0, 340.0, 380.0, 420.0, 480.0, 560.0, 640.0, 900.0, 1_400.0])
    func nameIsNeverCrushed(width: Double) {
      let screen = viewer(width: width)
      defer { screen.close() }
      let controls = headerControls(screen)
      #expect(controls.count == 3)
      let titleEnd = 12 + 16 + 8 + titleWidth()
      for control in controls {
        let isBeside = control.minX > titleEnd
        let isBelow = control.minY > 30
        #expect(
          isBeside || isBelow, "\(control) crowds a title ending at \(titleEnd), \(width) wide")
      }
    }

    @Test("a narrow viewer moves the controls under the name", arguments: [260.0, 300.0, 340.0])
    func narrowStacks(width: Double) {
      let screen = viewer(width: width)
      defer { screen.close() }
      for control in headerControls(screen) { #expect(control.minY > 30) }
    }

    @Test("a wide viewer keeps the controls beside the name", arguments: [640.0, 900.0, 1_400.0])
    func wideKeepsOneRow(width: Double) {
      let screen = viewer(width: width)
      defer { screen.close() }
      for control in headerControls(screen) { #expect(control.maxY < 44) }
    }

    @Test("every control stays inside a narrow viewer", arguments: [300.0, 340.0, 420.0, 520.0])
    func controlsStayInside(width: Double) {
      let screen = viewer(width: width)
      defer { screen.close() }
      for control in headerControls(screen) {
        #expect(control.minX >= 0)
        #expect(control.maxX <= width)
      }
    }
  }
// swiftlint:enable legacy_objc_type
#endif
