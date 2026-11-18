import SwiftUI

/// The Automations screens' type, metrics and small controls, after the web's `/tasks` pages:
/// a 24 px page title, 15 px card titles, 14 px interface text and 13 px secondary text on a
/// Mac, and the system's sizes on iOS.
enum AutomationStyle {
  /// The page title ("Automations", an automation's name).
  static let pageTitle = Font.title
  /// A card's or a section's title ("Daily standup notes", "Suggested").
  #if os(macOS)
    static let cardTitle = Font.title3.weight(.semibold)
  #else
    static let cardTitle = Font.headline
  #endif
  /// A muted section label ("Runs", "Configuration", "Prompt").
  static let sectionLabel = Font.callout.weight(.medium)

  /// A control row's height: the web's `h-9`, at the platform's touch target on iOS.
  #if os(macOS)
    static let controlHeight: CGFloat = 30
  #else
    static let controlHeight: CGFloat = 44
  #endif

  /// The page's side gutter: the web's `px-4 md:px-8`.
  static func gutter(_ layout: LayoutWidth) -> CGFloat {
    layout == .compact ? Theme.Spacing.large : Theme.Spacing.section
  }

  /// A web-tinted fill for selected filters and icon tiles (`bg-muted`).
  static let mutedFill = Color.secondary.opacity(0.12)

  /// The brand color of an integration's mark, as the web's template icons.
  static func brandColor(_ source: String) -> Color {
    switch source {
    case "jira": .blue
    case "slack": .purple
    case "linear": .indigo
    case "pagerduty": .green
    default: .primary
    }
  }
}

/// The web's search box: a magnifying glass inside a bordered field.
struct AutomationSearchField: View {
  @Binding var text: String
  var prompt = "Search automations\u{2026}"

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
        .accessibilityHidden(true)
      TextField("Search automations", text: $text, prompt: Text(prompt))
        .textFieldStyle(.plain)
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .frame(height: AutomationStyle.controlHeight)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        .strokeBorder(ThemeColor.border)
    )
    .contentShape(Rectangle())
  }
}

/// A row of text pills, one selected, as the web's All / Active / Paused filter.
struct AutomationPillPicker<Value: Hashable & Identifiable>: View {
  let label: String
  let values: [Value]
  @Binding var selection: Value
  let title: (Value) -> String
  var identifier: (Value) -> String = { _ in "" }

  var body: some View {
    HStack(spacing: Theme.Spacing.extraSmall) {
      ForEach(values) { value in
        let isSelected = value == selection
        Button {
          selection = value
        } label: {
          Text(title(value))
            .fontWeight(.medium)
            .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, Theme.Spacing.medium)
            .padding(.vertical, Theme.Spacing.extraSmall)
            .background(
              RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? AutomationStyle.mutedFill : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityIdentifier(identifier(value))
      }
    }
    .accessibilityElement(children: .contain)
    .accessibilityLabel(label)
  }
}

/// A failure with an optional fix, in the web's destructive-tinted box.
struct AutomationErrorBanner: View {
  let message: String
  var detail: String?
  var actionTitle: String?
  var action: (@MainActor () -> Void)?

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.failure)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(message)
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      if let actionTitle, let action {
        Button(actionTitle, action: action).controlSize(.small)
      }
    }
    .padding(.horizontal, Theme.Spacing.medium)
    .padding(.vertical, Theme.Spacing.small)
    .background(
      RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        .fill(Theme.failure.opacity(0.05))
    )
    .overlay(
      RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
        .strokeBorder(Theme.failure.opacity(0.3))
    )
    .accessibilityElement(children: .contain)
  }
}

/// A spinner and what is loading, left-aligned as the web's.
struct AutomationLoadingRow: View {
  let title: String
  var verticalPadding: CGFloat = 48

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      ProgressView().controlSize(.small)
      Text(title).foregroundStyle(.secondary)
    }
    .padding(.vertical, verticalPadding)
    .accessibilityElement(children: .combine)
  }
}
