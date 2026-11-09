#if os(macOS)
  import AppKit
  import Foundation
  import OmnigentViewTesting
  import OmnigentViewTextReading
  import SwiftUI

  @testable import OmnigentAuthUI

  /// Records what the sign-in UI asked the store to do.
  @MainActor
  final class AuthSpy {
    var log: [String] = []
    var credentials: [AccountCredentials] = []
    var creations: [AccountCreationRequest] = []
    var browserOptions: [SignInOption] = []
    var reachability: ServerReachability = .reachable
    var reachabilityByServer: [String: ServerReachability] = [:]
    var opened: [URL] = []

    /// Actions that report here.
    func actions(localSetup: LocalSetupActions? = nil) -> AuthActions {
      AuthActions(
        connect: { self.log.append("connect \($0)") },
        submitCredentials: { self.credentials.append($0) },
        startBrowserSignIn: { self.browserOptions.append($0) },
        cancel: { self.log.append("cancel") },
        signOut: { self.log.append("signOut") },
        retry: { self.log.append("retry") },
        forgetServer: { self.log.append("forget \($0)") },
        createAccount: { self.creations.append($0) },
        showAccountForm: { self.log.append("form \($0)") },
        checkServer: { self.reachabilityByServer[$0] ?? self.reachability },
        localSetup: localSetup)
    }

    /// Local setup actions that report here, as `setup X` lines.
    func setup(canShowLogs: Bool = true, canInstall: Bool = true) -> LocalSetupActions {
      var actions = LocalSetupActions(
        start: { self.log.append("setup start") },
        recheckCLI: { self.log.append("setup recheck") },
        hostAfterSignIn: { self.log.append("setup host \($0)") })
      if canShowLogs { actions.showLogs = { self.log.append("setup logs") } }
      if canInstall { actions.installCLI = { self.log.append("setup install") } }
      return actions
    }

    /// Records opened links, so that no test reaches a real browser.
    var openURL: OpenURLAction {
      OpenURLAction(
        handler: { url in
          self.opened.append(url)
          return .handled
        })
    }
  }

  extension OffscreenWindow {
    /// The editable fields, top to bottom.
    var fields: [NSTextField] {
      allViews.compactMap { $0 as? NSTextField }.filter(\.isEditable)
        .sorted { $0.convert($0.bounds, to: host).minY < $1.convert($1.bounds, to: host).minY }
    }

    /// Clicks into the field at `index` and types into it.
    func fill(_ index: Int, _ text: String) throws {
      let all = fields
      guard all.indices.contains(index) else {
        throw OffscreenWindowError.notFound("field \(index) of \(all.count)")
      }
      try click(all[index])
      try type(text)
    }

    /// All the text drawn, as one string to search.
    func allText() throws -> String { try shownText().joined(separator: "\n") }

    /// Clicks the control at `index` from the end of the reading order.
    func clickFromEnd(_ index: Int = 0) throws {
      let frames = controlFrames
      guard frames.count > index else {
        throw OffscreenWindowError.notFound("control \(index) from the end of \(frames.count)")
      }
      let frame = frames[frames.count - 1 - index]
      try click(CGPoint(x: frame.midX, y: frame.midY))
    }

    /// The full-width rows of a server list, top to bottom: wide controls below the URL field.
    var serverRows: [CGRect] {
      let fieldBottom = fields.first.map { $0.convert($0.bounds, to: host).maxY } ?? 0
      return controlFrames.filter { $0.width > 300 && $0.minY > fieldBottom }
    }

    /// Clicks the middle of a frame.
    func click(_ frame: CGRect) throws { try click(CGPoint(x: frame.midX, y: frame.midY)) }

    /// Presses Return.
    func pressReturn() throws { try press(keyCode: 36, characters: "\r") }
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

  /// Lets started tasks run and the view update.
  @MainActor
  func flush<Content: View>(_ screen: OffscreenWindow<Content>) async {
    for _ in 0..<4 {
      screen.settle(0.02)
      await Task.yield()
    }
    screen.settle(0.02)
  }
#endif
