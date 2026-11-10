#if os(macOS) && DEBUG
  import AppKit
  import Observation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  private struct OpenTab: Identifiable {
    let id: String
  }

  /// The window's tabs, which a test adds to as opening another conversation does.
  @MainActor
  @Observable
  private final class OpenTabs {
    var ids = ["first"]
    var shown = "first"
  }

  /// Every size each tab's conversation was laid out at.
  @MainActor
  private final class LaidOutSizes {
    var byID: [String: [CGSize]] = [:]
  }

  /// The shell with a long conversation in each kept tab, as the app's window has them.
  private struct ShellWithConversations: View {
    let tabs: OpenTabs
    let sizes: LaidOutSizes

    var body: some View {
      AppShell(
        sidebar: SidebarSamples.empty, selection: .constant(nil), searchText: .constant(""),
        actions: SidebarActions(sessions: SessionListActions())
      ) { _ in
        KeptAliveTabs(tabs.ids.map(OpenTab.init(id:)), shownID: tabs.shown) { tab in
          ObservationScope("tab") {
            LiveTranscriptHost(
              conversation: LiveConversation(
                ConversationViewState(
                  header: TranscriptFixture.header, rows: TranscriptFixture.turns(400))),
              actions: ConversationActions()
            )
            .onGeometryChange(for: CGSize.self) {
              $0.size
            } action: { size in
              sizes.byID[tab.id, default: []].append(size)
            }
          }
        }
      }
    }
  }

  /// The split view lays its detail column out at a placeholder before the column's size. A
  /// conversation built then builds rows at the placeholder's width and again at the column's.
  @Suite("A conversation in a window that opens", .serialized)
  @MainActor
  struct AppShellConversationMountTests {
    @Test("It is built at the column's size, with the rows a tab opened later builds")
    func opensAtTheColumnsSize() async throws {
      let tabs = OpenTabs()
      let sizes = LaidOutSizes()
      var opened: OffscreenWindow<AnyView>?
      let windowOpening = RenderTally.recording {
        let window = transcriptScreen(
          ShellWithConversations(tabs: tabs, sizes: sizes), width: 1200, height: 800)
        window.settle(0.5)
        opened = window
      }
      let window = try #require(opened)
      defer { window.close() }
      try await letTasksRun(window, milliseconds: 300)

      // A tab opened in the settled window is laid out once, at the column's size.
      let tabOpening = RenderTally.recording {
        tabs.ids.append("second")
        tabs.shown = "second"
        window.settle(0.5)
      }
      let column = try #require(sizes.byID["second"]?.last)
      #expect(sizes.byID["second"] == [column])
      let firstSizes = sizes.byID["first", default: []]
      #expect(firstSizes.last == column)
      #expect(firstSizes.allSatisfy { $0.width > UnmeasuredMinimum.column.width }, "\(firstSizes)")
      let screenOfRows = tabOpening["row", default: 0]
      #expect(screenOfRows > 0)
      #expect(windowOpening["row", default: 0] <= screenOfRows)
    }
  }
#endif
