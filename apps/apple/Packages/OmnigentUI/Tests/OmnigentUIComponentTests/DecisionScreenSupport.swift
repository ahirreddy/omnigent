#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI

  @testable import OmnigentUIComponents

  /// Everything a card sent, and every link it opened.
  @MainActor
  final class DecisionResponseLog {
    var responses: [DecisionResponse] = []
    var openedURLs: [URL] = []
    var validator: (([String: ElicitationValue]) -> DecisionFormProblem?)?

    var respond: (DecisionResponse) -> Void {
      { [self] in responses.append($0) }
    }
  }

  /// A card's inputs, which a test changes as the app's store would.
  @MainActor @Observable
  final class DecisionCardModel {
    var phase: DecisionPhase
    var isReadOnly: Bool

    init(phase: DecisionPhase = .pending, isReadOnly: Bool = false) {
      self.phase = phase
      self.isReadOnly = isReadOnly
    }
  }

  /// One card as a screen hosts it.
  struct DecisionCardScreen: View {
    let card: DecisionCard
    @Bindable var model: DecisionCardModel
    let log: DecisionResponseLog
    var style = DecisionCardStyle.full
    var context: String?
    var layoutWidth = LayoutWidth.regular
    var responds = true

    var body: some View {
      DecisionCardView(
        card: card, phase: model.phase, isReadOnly: model.isReadOnly, style: style,
        context: context, respond: responds ? log.respond : nil, validate: log.validator
      )
      .environment(\.layoutWidth, layoutWidth)
      .environment(
        \.openURL,
        OpenURLAction { [log] url in
          log.openedURLs.append(url)
          return .handled
        }
      )
      .padding()
      .frame(width: 800, height: 600, alignment: .top)
    }
  }

  extension DecisionCard {
    /// A pending approval in one session, with only what a test cares about.
    static func sample(
      id: String = "card", title: String = "Approval requested", detail: String = "",
      kind: DecisionKind = .approval, permissions: PermissionOptions = PermissionOptions(),
      policyName: String? = nil, acceptsFeedback: Bool = false, answered: Bool = false,
      message: String? = nil, toolInput: String? = nil, targetSessionId: String? = nil
    ) -> DecisionCard {
      DecisionCard(
        id: id, carryingSessionId: "session", targetSessionId: targetSessionId, title: title,
        detail: detail, kind: kind, permissions: permissions, policyName: policyName,
        acceptsFeedback: acceptsFeedback, answered: answered, message: message,
        toolInput: toolInput)
    }

    /// A pending command approval.
    static func command(
      _ line: String = "cargo test", id: String = "card", permissions: PermissionOptions? = nil,
      acceptsFeedback: Bool = false
    ) -> DecisionCard {
      var options = permissions ?? PermissionOptions()
      options.command = options.command ?? CommandApproval(command: line)
      return sample(
        id: id, detail: line, permissions: options, acceptsFeedback: acceptsFeedback)
    }
  }
#endif
