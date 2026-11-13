import AppKit
import Foundation
import OmnigentCoreFFI
import OmnigentUIComponents
import OmnigentViewTesting
import OmnigentViewTextReading
import OmnigentWorkspaceUI
import SwiftUI
import Testing

@testable import OmnigentAppUI
@testable import OmnigentStores

/// The right panel as a conversation builds it: the app's slots over a workspace, in the
/// component's panel.
private struct DocumentPanel: View {
  let workspace: WorkspaceBrowserModel
  let composer: ComposerStore?
  @State private var tab = InspectorTab.files

  var body: some View {
    let slots = WorkspacePanelSlots(
      workspace: workspace, panel: nil, terminals: nil, tabRoutes: nil,
      terminalNames: .names([]), permissionLevel: 4, composer: composer)
    WorkspaceInspector(
      state: ConversationViewState(
        header: OmnigentUIComponents.SessionHeader(id: "conv", title: "")),
      actions: ConversationActions(), slots: slots.slots, tab: $tab)
  }
}

/// The open files' tabs and the file's review actions, pressed in the hosted panel, reach the
/// workspace and the composer through the closures the app supplies.
@MainActor
@Suite("The right panel's open files, clicked", .serialized)
struct WorkspacePanelDocumentClickTests {
  init() {
    SystemSideEffects.install()
    SystemSideEffects.reset()
    UserDefaults.standard.removeObject(forKey: "workspace.fileViewMode")
    UserDefaults.standard.removeObject(forKey: "workspace.showsComments")
  }

  /// A workspace with `src/main.rs` open under the diff of `src/lib.rs`, which is shown.
  private func workspace() async -> WorkspaceBrowserModel {
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await workspace.open(.file(path: "src/main.rs", line: nil))
    await workspace.open(.diff(path: "src/lib.rs"))
    return workspace
  }

  /// One open file's tab: its name, which shows it, and the small X beside it, which closes it.
  private struct Chip {
    let select: CGRect
    let close: CGRect
  }

  /// The open files' tabs, left to right: each ends in a close button 14 points square, under
  /// the panel's own row of tabs.
  private func chips<Content: View>(_ screen: OffscreenWindow<Content>) -> [Chip] {
    let controls = screen.controlFrames
    let closes = controls.filter { $0.width <= 16 && $0.height <= 16 && $0.minY < 90 }
    return closes.sorted { $0.minX < $1.minX }.compactMap { close in
      let beside = controls.filter {
        abs($0.midY - close.midY) < 8 && $0.maxX <= close.minX + 1 && $0.width > 16
      }
      return beside.max { $0.maxX < $1.maxX }.map { Chip(select: $0, close: close) }
    }
  }

  private func click<Content: View>(_ frame: CGRect, in screen: OffscreenWindow<Content>) throws {
    try screen.click(CGPoint(x: frame.midX, y: frame.midY))
  }

  @Test("a click on an open file's tab shows it, its close button closes it, and Files hides it")
  func tabs() async throws {
    let workspace = await workspace()
    let screen = OffscreenWindow(
      DocumentPanel(workspace: workspace, composer: nil), width: 760, height: 520)
    defer { screen.close() }
    try await pause(screen)
    #expect(workspace.document?.tabID == "diff:src/lib.rs")
    // The tabs stand in the order their files were opened: main.rs, then the diff of lib.rs.
    let open = chips(screen)
    try #require(open.count == 2, "\(screen.controlFrames)")
    try click(open[0].select, in: screen)
    try await eventually("the file's tab to show") {
      workspace.document?.tabID == "file:src/main.rs"
    }
    try await pause(screen)
    let shown = chips(screen)
    try #require(shown.count == 2, "\(screen.controlFrames)")
    try click(shown[1].close, in: screen)
    try await eventually("the diff to close") { workspace.openDocuments.count == 1 }
    #expect(workspace.openDocuments.map(\.tabID) == ["file:src/main.rs"])
    #expect(workspace.document?.tabID == "file:src/main.rs")
    try await pause(screen)
    // Files is the first of the panel's own tabs.
    try screen.clickControl(at: 0)
    try await eventually("the panel to show") { workspace.document == nil }
    #expect(workspace.openDocuments.count == 1, "hidden, not closed")
    #expect(try screen.shows("Files"))
  }

  /// The context menu of the first line down the page that has one with `title`.
  private func lineMenu<Content: View>(
    with title: String, in screen: OffscreenWindow<Content>
  ) throws -> NSMenu {
    for height in stride(from: 60.0, to: 500.0, by: 4.0) {
      let point = CGPoint(x: 120, y: height)
      let event = try #require(
        NSEvent.mouseEvent(
          with: .rightMouseDown, location: screen.host.convert(point, to: nil), modifierFlags: [],
          timestamp: ProcessInfo.processInfo.systemUptime,
          windowNumber: screen.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1,
          pressure: 1))
      // Inside a scroll view the menu may belong to a view above the deepest one at the point.
      for view in screen.allViews.reversed()
      where view.convert(view.bounds, to: screen.host).contains(point) {
        if let menu = view.menu(for: event), menu.items.contains(where: { $0.title == title }) {
          return menu
        }
      }
    }
    throw OffscreenWindowError.notFound("a line menu with \(title)")
  }

  @Test("Ask About This in a line's menu quotes the line in the composer and attaches its place")
  func ask() async throws {
    let store = try await ConversationFixtures.store()
    let workspace = WorkspaceBrowserModel(source: SampleWorkspaceDataSource())
    await workspace.open(.file(path: "src/main.rs", line: nil))
    let screen = OffscreenWindow(
      DocumentPanel(workspace: workspace, composer: store.composer), width: 760, height: 520)
    defer { screen.close() }
    try await pause(screen)
    #expect(store.composer.quotes.isEmpty)
    let menu = try lineMenu(with: "Ask About This", in: screen)
    try screen.choose("Ask About This", in: menu)
    // Whichever line the menu was found on, its text is quoted and its place attached.
    let lines = WorkspaceSamples.mainText.split(separator: "\n", omittingEmptySubsequences: false)
    let quoted = try #require(store.composer.quotes.first?.text)
    let line = try #require(lines.firstIndex { $0 == quoted }).advanced(by: 1)
    #expect(!quoted.isEmpty)
    #expect(store.composer.quotes.count == 1)
    #expect(store.composer.mentions == ["src/main.rs:\(line)-\(line)"])
  }
}
