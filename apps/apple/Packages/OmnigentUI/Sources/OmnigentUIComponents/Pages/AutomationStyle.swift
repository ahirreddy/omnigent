import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The Automations screens' look: the system's text styles, materials, separators and radii,
/// with color only where it means something (the accent for the primary action, green for
/// active, red for a failure, each service's brand color on its mark).
enum AutomationStyle {
  /// The page title ("Automations", an automation's name).
  static let pageTitle = Font.largeTitle.weight(.semibold)
  /// A card's title ("Daily standup notes").
  static let cardTitle = Font.headline
  /// A section heading ("Suggested", "Runs").
  static let sectionTitle = Font.headline
  /// A card's or a row's second line.
  static let detail = Font.subheadline

  /// The standard corner radius of a grouped card.
  static let cardRadius: CGFloat = 10

  /// The page's side gutter: the platform's margins.
  static func gutter(_ layout: LayoutWidth) -> CGFloat {
    layout == .compact ? Theme.Spacing.large : Theme.Spacing.extraLarge
  }

  /// The brand color of an integration's mark.
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

extension View {
  /// A card on the system's regular material, with a hairline separator and the standard radius.
  func automationCard(isHighlighted: Bool = false) -> some View {
    let shape = RoundedRectangle(cornerRadius: AutomationStyle.cardRadius, style: .continuous)
    return
      background(.regularMaterial, in: shape)
      .overlay {
        if isHighlighted { shape.fill(.quaternary.opacity(0.5)).allowsHitTesting(false) }
      }
      .overlay(shape.strokeBorder(.separator, lineWidth: 0.5).allowsHitTesting(false))
  }

  /// A button that reads as a link: the link style on a Mac; iOS has none, so a borderless
  /// button in the link color.
  @ViewBuilder func automationLinkStyle() -> some View {
    #if os(macOS)
      buttonStyle(.link)
    #else
      buttonStyle(.borderless).foregroundStyle(Theme.link)
    #endif
  }
}

#if os(macOS)
  /// The system's search field.
  struct AutomationSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt = "Search automations"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
      let field = NSSearchField()
      field.placeholderString = prompt
      field.controlSize = .large
      field.delegate = context.coordinator
      field.setAccessibilityIdentifier("automations-search")
      return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
      context.coordinator.text = $text
      if field.stringValue != text { field.stringValue = text }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
      var text: Binding<String>

      init(text: Binding<String>) {
        self.text = text
      }

      func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        text.wrappedValue = field.stringValue
      }

      /// The field's clear button, which empties it without a text change.
      func searchFieldDidEndSearching(_ sender: NSSearchField) {
        text.wrappedValue = ""
      }
    }
  }
#else
  /// The system's search field.
  struct AutomationSearchField: UIViewRepresentable {
    @Binding var text: String
    var prompt = "Search automations"

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeUIView(context: Context) -> UISearchBar {
      let bar = UISearchBar()
      bar.placeholder = prompt
      bar.searchBarStyle = .minimal
      bar.delegate = context.coordinator
      bar.accessibilityIdentifier = "automations-search"
      return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
      context.coordinator.text = $text
      if bar.text != text { bar.text = text }
    }

    final class Coordinator: NSObject, UISearchBarDelegate {
      var text: Binding<String>

      init(text: Binding<String>) {
        self.text = text
      }

      func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
        text.wrappedValue = searchText
      }

      func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        searchBar.resignFirstResponder()
      }
    }
  }
#endif

/// A failure with an optional fix: a red warning label beside its button.
struct AutomationErrorBanner: View {
  let message: String
  var detail: String?
  var actionTitle: String?
  var action: (@MainActor () -> Void)?

  var body: some View {
    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
      Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
        Text(message)
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer(minLength: 0)
      if let actionTitle, let action {
        Button(actionTitle, action: action)
      }
    }
    .padding(Theme.Spacing.medium)
    .automationCard()
    .accessibilityElement(children: .contain)
  }
}

/// A spinner and what is loading.
struct AutomationLoadingRow: View {
  let title: String
  var verticalPadding: CGFloat = 48

  var body: some View {
    HStack(spacing: Theme.Spacing.small) {
      ProgressView().controlSize(.small)
      Text(title).foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, verticalPadding)
    .accessibilityElement(children: .combine)
  }
}
