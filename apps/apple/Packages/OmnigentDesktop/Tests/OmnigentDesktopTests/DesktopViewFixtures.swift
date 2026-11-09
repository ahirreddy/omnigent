#if os(macOS)
  import AppKit
  import Foundation
  import ObjectiveC
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI
  import os

  @testable import OmnigentDesktop

  /// A `DesktopController` over fakes: no real process, sound setting or preference domain.
  @MainActor
  struct DesktopFixture {
    let local: LocalServerHarness
    let desktop: DesktopController
    var issues: IssueRecorder

    init(
      capability: LocalServerCapability = .available,
      executables: Set<String> = [LocalServerHarness.cliPath], managedDomains: [String] = []
    ) throws {
      local = try LocalServerHarness(capability: capability, executables: executables)
      let suite = "ai.omnigent.desktop.view-tests.\(UUID().uuidString)"
      guard let defaults = UserDefaults(suiteName: suite) else {
        throw FixtureError(description: "no defaults suite")
      }
      desktop = DesktopController(
        defaults: defaults, managedDomains: managedDomains,
        localServerCapability: capability, localServerDependencies: local.dependencies)
      desktop.localServerPreferences.dataDirectory = local.dataDirectory.path
      issues = IssueRecorder()
      let recorder = issues
      desktop.onIssue = { recorder.issues.append($0) }
    }

    var manager: LocalServerManager { desktop.localServer }

    /// Starts the fake local server on 6767 through the manager.
    func startServer() async throws -> URL {
      let url = try loopback(6767)
      local.runner.script(announces(6767))
      local.probe.answer(
        url, .ready(LocalServerManifest(manifestVersion: 1, serverVersion: "0.9.0")))
      await manager.startServer()
      return url
    }

    func cleanUp() { local.cleanUp() }
  }

  /// The issues a controller reported.
  @MainActor
  final class IssueRecorder {
    var issues: [DesktopIssue] = []
  }

  /// Lets started tasks run and the view update.
  @MainActor
  func flush<Content: View>(_ screen: OffscreenWindow<Content>) async {
    for _ in 0..<4 {
      screen.settle(0.02)
      await Task.yield()
    }
    screen.settle(0.02)
  }

  /// Waits for a condition while tasks and the run loop proceed.
  @MainActor
  func settle<Content: View>(
    _ screen: OffscreenWindow<Content>, until condition: () -> Bool
  ) async -> Bool {
    for _ in 0..<200 {
      screen.settle(0.005)
      if condition() { return true }
      await Task.yield()
      do {
        try await Task.sleep(for: .milliseconds(5))
      } catch {
        return condition()
      }
    }
    return condition()
  }

  extension OffscreenWindow {
    /// All the text drawn, as one string to search.
    func allText() throws -> String { try shownText().joined(separator: "\n") }

    /// The toggles and check boxes, top to bottom.
    var toggles: [NSButton] {
      allViews.compactMap { $0 as? NSButton }
        .filter { !($0 is NSPopUpButton) && $0.bezelStyle != .push }
    }

    /// Clicks the middle of a frame.
    func click(_ frame: CGRect) throws { try click(CGPoint(x: frame.midX, y: frame.midY)) }

    /// The titles of a menu that an item holds, in order, without separators.
    func titles(_ menu: NSMenu) -> [String] {
      menu.items.filter { !$0.isSeparatorItem }.map(\.title)
    }
  }

  // These replace Objective-C methods, so their signatures use its reference types.
  // swiftlint:disable legacy_objc_type
  /// Stands in for what `SystemSideEffects` leaves real: what a panel chose, sounds and the reply
  /// that would end the process.
  enum DesktopSideEffects {
    struct State {
      var panelURL: URL?
      var playedSounds: [String] = []
      var soundsPlay = true
      var terminationReplies: [Bool] = []
    }

    private static let lock = OSAllocatedUnfairLock(initialState: State())

    /// What has been recorded, and what panels and sounds will answer.
    static var state: State {
      get { lock.withLock { $0 } }
      set { lock.withLock { $0 = newValue } }
    }

    private static let installation: Void = {
      SystemSideEffects.install()
      let url: @convention(c) (NSSavePanel, Selector) -> NSURL? = { _, _ in
        state.panelURL as NSURL?
      }
      replace(NSOpenPanel.self, "URL", with: url)
      let play: @convention(c) (NSSound, Selector) -> Bool = { sound, _ in
        let name = MainActor.assumeIsolated { sound.name ?? "" }
        return lock.withLock { current in
          current.playedSounds.append(name)
          return current.soundsPlay
        }
      }
      replace(NSSound.self, "play", with: play)
      let reply: @convention(c) (NSApplication, Selector, Bool) -> Void = { _, _, answer in
        lock.withLock { $0.terminationReplies.append(answer) }
      }
      replace(NSApplication.self, "replyToApplicationShouldTerminate:", with: reply)
    }()

    /// Installs once and forgets what was recorded.
    static func reset() {
      _ = installation
      SystemSideEffects.reset()
      state = State()
    }

    private static func replace<Function>(
      _ owner: AnyClass, _ name: String, with function: Function
    ) {
      guard let method = unsafe class_getInstanceMethod(owner, NSSelectorFromString(name)) else {
        preconditionFailure("DesktopSideEffects: \(owner) has no \(name)")
      }
      unsafe method_setImplementation(method, unsafeBitCast(function, to: IMP.self))
    }
  }
  // swiftlint:enable legacy_objc_type

  /// A menu hosted for its items, as `CommandGroup` would list them.
  struct MenuHost<Items: View>: View {
    @ViewBuilder let items: Items

    var body: some View {
      Menu("Menu") { items }
        .menuStyle(.button)
    }
  }
#endif
