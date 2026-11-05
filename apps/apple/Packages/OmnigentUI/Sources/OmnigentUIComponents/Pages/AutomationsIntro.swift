public import SwiftUI

/// The first-visit guide to Automations (the web's `AutomationsIntro`): a few steps, each with
/// a small illustration, that the user pages through or dismisses.
public struct AutomationsIntro: View {
  /// One step of the guide.
  nonisolated public struct Step: Hashable, Sendable, Identifiable {
    /// Stable id.
    public var id: String
    /// The step's title.
    public var title: String
    /// What it does.
    public var detail: String
    /// The illustration's first card.
    public var caption: String
    /// The illustration's last card, when it has one.
    public var result: String?
    /// The illustration's SF Symbol.
    public var systemImage: String
    /// The illustration's checklist instead of cards, when set.
    public var checklist: [String] = []
  }

  private let steps: [Step]
  private let appName: String
  private let dismiss: () -> Void
  @State private var index = 0

  /// Creates the guide.
  /// - Parameters:
  ///   - steps: The steps, from ``steps(sessionModes:sandboxes:)``.
  ///   - appName: The product name.
  ///   - dismiss: Close the guide for good.
  public init(steps: [Step], appName: String = "Omnigent", dismiss: @escaping () -> Void) {
    self.steps = steps
    self.appName = appName
    self.dismiss = dismiss
  }

  /// The steps the server supports: continuing one session needs `sessionModes`.
  /// - Parameters:
  ///   - sessionModes: Automations can continue one session across runs.
  ///   - sandboxes: The server offers managed sandboxes.
  ///   - triggers: The Jira, Slack and GitHub trigger templates are offered.
  /// - Returns: The steps, in order.
  public static func steps(sessionModes: Bool, sandboxes: Bool, triggers: Bool = false) -> [Step] {
    var steps = [
      Step(
        id: "schedule", title: "Run on a schedule",
        detail:
          "Set a recurring time for your agent to investigate issues, review code, or prepare a report.",
        caption: "Every weekday \u{00B7} 9:00 AM", result: "Your results, ready to review",
        systemImage: "clock")
    ]
    if triggers {
      steps.append(
        Step(
          id: "watch", title: "Watch for new work",
          detail:
            "Use Jira, Slack, or GitHub templates to check periodically and start sessions for matching items. Your agent needs access to the service.",
          caption: "Jira \u{00B7} Slack \u{00B7} GitHub", result: "Start work on matching items",
          systemImage: "magnifyingglass"))
    }
    if sessionModes {
      steps.append(
        Step(
          id: "context", title: "Keep context between runs",
          detail:
            "Start fresh each run, or continue one session so your agent can build on its earlier work.",
          caption: "Continue one session", result: "Build on what you learned",
          systemImage: "arrow.2.squarepath"))
    }
    steps.append(
      Step(
        id: "configure", title: "Make it yours",
        detail: sandboxes
          ? "Choose your agent and a connected computer or available sandbox. Customize model and permission settings where supported."
          : "Choose your agent and connected computer. Keep the server and computer running, and customize model and permission settings where supported.",
        caption: "Your agent \u{00B7} Your instructions", systemImage: "slider.horizontal.3",
        checklist: [
          "Your agent", sandboxes ? "Computer or sandbox" : "Connected computer",
          "Your instructions",
        ]))
    return steps
  }

  private var active: Step? { steps.indices.contains(index) ? steps[index] : steps.last }
  private var isLast: Bool { index >= steps.count - 1 }

  /// The guide.
  public var body: some View {
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
        Text("Introducing Automations").font(.title.weight(.semibold))
        Text("Put recurring work on autopilot with \(appName).").foregroundStyle(.secondary)
        VStack(spacing: Theme.Spacing.extraSmall) {
          ForEach(Array(steps.enumerated()), id: \.element.id) { offset, step in
            stepRow(step, number: offset + 1, isActive: offset == index) { index = offset }
          }
        }
        .padding(.vertical, Theme.Spacing.small)
        Spacer(minLength: 0)
        HStack {
          Spacer()
          Button("Maybe later", action: dismiss)
            .accessibilityIdentifier("automations-intro-dismiss")
          Button(isLast ? "Done" : "Next") {
            if isLast { dismiss() } else { index += 1 }
          }
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("automations-intro-next")
        }
      }
      .padding(Theme.Spacing.extraLarge)
      .frame(width: 420, alignment: .leading)
      illustration
        .frame(width: 380)
        .frame(maxHeight: .infinity)
        .background(.quaternary.opacity(0.4))
    }
    .frame(minHeight: 480)
    .accessibilityIdentifier("automations-intro")
  }

  private func stepRow(
    _ step: Step, number: Int, isActive: Bool, select: @escaping () -> Void
  ) -> some View {
    Button(action: select) {
      HStack(alignment: .top, spacing: Theme.Spacing.medium) {
        Text("\(number)").font(.caption.weight(.medium))
          .frame(width: 26, height: 26)
          .foregroundStyle(isActive ? Theme.accent : Theme.secondary)
          .overlay(Circle().strokeBorder(.separator))
        VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
          Text(step.title).font(.callout.weight(.medium))
          Text(step.detail).font(.callout).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }
      .padding(Theme.Spacing.medium)
      .background(
        Theme.selection.opacity(isActive ? 1 : 0),
        in: RoundedRectangle(cornerRadius: Theme.Radius.large)
      )
      .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.large))
    }
    .buttonStyle(.plain)
    .accessibilityAddTraits(isActive ? .isSelected : [])
    .accessibilityIdentifier("automations-intro-step-\(step.id)")
  }

  @ViewBuilder private var illustration: some View {
    if let step = active {
      VStack(spacing: Theme.Spacing.medium) {
        Spacer()
        if step.checklist.isEmpty {
          let first = step.id == "context" ? "Earlier work" : step.caption
          let middle = step.id == "context" ? step.caption : appName
          card(first, systemImage: step.systemImage)
          arrow
          card(middle, systemImage: "sparkles")
          if let result = step.result {
            arrow
            card(result, systemImage: "text.bubble")
          }
        } else {
          checklist(step)
        }
        Spacer()
        Text("\(index + 1) of \(steps.count) \u{00B7} \(step.title)")
          .font(.caption).foregroundStyle(.secondary)
      }
      .padding(Theme.Spacing.extraLarge)
      .accessibilityHidden(true)
    }
  }

  private var arrow: some View {
    Image(systemName: "arrow.down").foregroundStyle(.tertiary)
  }

  private func card(_ text: String, systemImage: String) -> some View {
    Label {
      Text(text).font(.callout.weight(.medium))
    } icon: {
      Image(systemName: systemImage).foregroundStyle(Theme.accent)
    }
    .padding(.horizontal, Theme.Spacing.large).padding(.vertical, Theme.Spacing.medium)
    .cardSurface(cornerRadius: Theme.Radius.large)
  }

  private func checklist(_ step: Step) -> some View {
    VStack(alignment: .leading, spacing: 0) {
      Label("Your automation", systemImage: step.systemImage)
        .font(.callout.weight(.medium))
        .padding(.bottom, Theme.Spacing.medium)
      ForEach(step.checklist, id: \.self) { item in
        Divider()
        HStack {
          Text(item).font(.callout).foregroundStyle(.secondary)
          Spacer()
          Image(systemName: "checkmark").foregroundStyle(Theme.accent)
        }
        .padding(.vertical, Theme.Spacing.small)
      }
    }
    .padding(Theme.Spacing.large)
    .frame(maxWidth: 288)
    .cardSurface(cornerRadius: Theme.Radius.large)
  }
}
