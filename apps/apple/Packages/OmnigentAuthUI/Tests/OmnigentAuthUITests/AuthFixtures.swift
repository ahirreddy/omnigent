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
        checkServer: { _ in self.reachability },
        localSetup: localSetup)
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

    /// Presses Return.
    func pressReturn() throws { try press(keyCode: 36, characters: "\r") }
  }
#endif
