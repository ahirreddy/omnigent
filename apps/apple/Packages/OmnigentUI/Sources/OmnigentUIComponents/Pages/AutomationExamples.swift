import SwiftUI

/// One example the Automations guide shows (the web's `EXAMPLES`).
struct AutomationExample: Hashable, Identifiable {
  let id: String
  let title: String
  let summary: String
  let systemImage: String
  let schedule: String
  let prompt: String
  let needs: String

  static let all = [
    Self(
      id: "product-questions", title: "Answer product questions",
      summary: "A Slack bot for your product question channel.", systemImage: "number",
      schedule: "Hourly",
      prompt:
        "Read the top-level messages posted in #product-questions in the last two hours. For each question with no reply yet, answer it in the thread from our product docs and release notes, and link your sources. If you aren't sure, say so and tag @product-oncall instead of guessing.",
      needs: "a Slack MCP server"),
    Self(
      id: "triage-pages", title: "Triage new pages",
      summary: "A first look at each PagerDuty incident for the on-call engineer.",
      systemImage: "light.beacon.max", schedule: "Hourly",
      prompt:
        "List the PagerDuty incidents on the Payments API service triggered in the last two hours. For each one without a note from you, read the alert, check recent deploys, error logs and dashboards, and add a note with the likely cause, the evidence and a suggested first step. Don't acknowledge, reassign or resolve incidents.",
      needs: "a PagerDuty MCP server and access to your logs and dashboards"),
    Self(
      id: "dependabot", title: "Merge Dependabot updates",
      summary: "A daily security sweep of dependency updates.", systemImage: "checkmark.shield",
      schedule: "Every day at 9:00 AM",
      prompt:
        "List the open pull requests in acme/web opened by dependabot[bot]. Merge each one that bumps a patch or minor version and passes every check. Leave the rest open with a comment saying why: a major version, a failing check or a merge conflict. Reply with what you merged and what needs a person.",
      needs: "the GitHub CLI or a GitHub MCP server allowed to merge"),
  ]
}

/// The guide's examples (web `ExamplesView`): what a few practical automations run and need.
/// Back returns to the steps; Done closes the guide.
struct AutomationExamplesView: View {
  let back: () -> Void
  let done: () -> Void
  @Environment(\.layoutWidth) private var layoutWidth

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.medium) {
      Text("Example Automations").font(.title.weight(.semibold))
        .accessibilityAddTraits(.isHeader)
      Text("Practical examples of what you can automate.").foregroundStyle(.secondary)
      ScrollView {
        let columns = Array(
          repeating: GridItem(.flexible(), spacing: Theme.Spacing.medium, alignment: .top),
          count: layoutWidth == .compact ? 1 : 3)
        LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.medium) {
          ForEach(AutomationExample.all) { card($0) }
        }
      }
      HStack {
        Button("Back", action: back)
          .accessibilityIdentifier("automations-examples-back")
        Spacer()
        Button("Done", action: done)
          .buttonStyle(.borderedProminent)
          .keyboardShortcut(.defaultAction)
          .accessibilityIdentifier("automations-examples-done")
      }
    }
    .padding(Theme.Spacing.extraLarge)
    .accessibilityIdentifier("automations-examples")
  }

  private func card(_ example: AutomationExample) -> some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.small) {
      Label(example.title, systemImage: example.systemImage)
        .font(.headline)
        .labelStyle(.titleAndIcon)
      Text(example.summary).font(.callout).foregroundStyle(.secondary)
      Label(example.schedule, systemImage: "clock").font(.caption).foregroundStyle(.secondary)
      Text("Prompt").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
      Text(example.prompt)
        .font(.callout)
        .textSelection(.enabled)
        .padding(Theme.Spacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
      Text("Needs \(example.needs).").font(.caption).foregroundStyle(.secondary)
    }
    .padding(Theme.Spacing.medium)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 12))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("automations-example-\(example.id)")
  }
}
