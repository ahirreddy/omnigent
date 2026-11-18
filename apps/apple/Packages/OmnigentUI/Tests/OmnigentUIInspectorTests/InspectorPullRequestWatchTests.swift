#if os(macOS)
  import Observation
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Inspector: watching pull requests while on screen", .serialized)
  @MainActor
  struct InspectorPullRequestWatchTests {
    final class Watches {
      var started: [Bool] = []
    }

    /// The scene phase and tab visibility a test moves by hand.
    @Observable final class Place {
      var phase: ScenePhase = .active
      var hidden = false
    }

    private struct Host<Content: View>: View {
      let place: Place
      @ViewBuilder let content: Content

      var body: some View {
        content
          .environment(\.scenePhase, place.phase)
          .environment(\.isTabContentHidden, place.hidden)
      }
    }

    private func settle(_ screen: OffscreenWindow<AnyView>) async throws {
      try await Task.sleep(for: .milliseconds(30))
      screen.settle(0.05)
    }

    @Test("A view on screen watches; the background and a hidden tab stop it; back, it resumes")
    func watchesOnlyOnScreen() async throws {
      let (watches, place) = (Watches(), Place())
      let screen = OffscreenWindow(
        AnyView(
          Host(place: place) {
            Text("Pull requests").whileVisible { resumed in watches.started.append(resumed) }
          }),
        width: 300, height: 100)
      defer { screen.close() }
      try await settle(screen)
      #expect(watches.started == [false])

      place.phase = .background
      try await settle(screen)
      #expect(watches.started == [false])
      place.phase = .active
      try await settle(screen)
      #expect(watches.started == [false, true], "it shows again after the background")

      place.hidden = true
      try await settle(screen)
      #expect(watches.started == [false, true])
    }

    @Test("The Pull Requests tab watches through its action")
    func panelWatches() async throws {
      let (watches, place) = (Watches(), Place())
      var extras = PullRequestPanelExtras()
      extras.actions.watch = { resumed in watches.started.append(resumed) }
      let screen = OffscreenWindow(
        AnyView(
          Host(place: place) {
            PullRequestsPanel(
              state: .loaded([], synced: true), extras: extras, open: nil, refresh: nil)
          }),
        width: 400, height: 300)
      defer { screen.close() }
      try await settle(screen)
      #expect(watches.started == [false])
    }
  }
#endif
