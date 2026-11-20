public import SwiftUI

/// The table's find bar, as a text view's: the query, which match is found of how many, the
/// previous and next match, and Done on a Mac. iPhone and iPad keep it as the table's search
/// field, which Command-F focuses from a keyboard.
struct DataTableFindBar: View {
  @Binding var find: DataTableFind
  var focus: FocusState<Bool>.Binding
  /// Closes the bar (Done, Escape); `nil` keeps it, as a search field.
  let close: (() -> Void)?

  var body: some View {
    HStack(spacing: 8) {
      HStack(spacing: 6) {
        findButton
        TextField("Find in Table", text: $find.text)
          .textFieldStyle(.plain)
          .autocorrectionDisabled()
          .focused(focus)
          .onSubmit { find.step(forward: true) }
          #if os(macOS)
            .onExitCommand { close?() }
          #endif
          .accessibilityIdentifier("workspace.table.find-field")
        if let status = find.status {
          Text(status)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .accessibilityIdentifier("workspace.table.find-status")
        }
      }
      .padding(.horizontal, 7)
      .padding(.vertical, 4)
      .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 7))
      Group {
        step("Previous Match", systemImage: "chevron.up", forward: false)
        step("Next Match", systemImage: "chevron.down", forward: true)
      }
      .labelStyle(.iconOnly)
      .buttonStyle(.borderless)
      .disabled(find.matches.isEmpty)
      if let close {
        Button("Done", action: close)
          .accessibilityIdentifier("workspace.table.find-done")
      }
    }
    .font(.callout)
    .lineLimit(1)
    .padding(.horizontal, 10)
    .padding(.bottom, 6)
  }

  /// The magnifying glass, which puts the keyboard in the field (Command-F on iPhone and iPad).
  private var findButton: some View {
    Button {
      focus.wrappedValue = true
    } label: {
      Image(systemName: "magnifyingglass")
    }
    .buttonStyle(.plain)
    .foregroundStyle(.secondary)
    #if os(iOS)
      .keyboardShortcut("f", modifiers: .command)
    #endif
    .accessibilityLabel("Find in Table")
  }

  private func step(_ title: String, systemImage: String, forward: Bool) -> some View {
    Button(title, systemImage: systemImage) { find.step(forward: forward) }
      .help(title)
      #if os(iOS)
        .keyboardShortcut("g", modifiers: forward ? .command : [.command, .shift])
      #endif
      .accessibilityIdentifier("workspace.table.find-\(forward ? "next" : "previous")")
  }
}

/// What the Find menu does for a data table while the table or its find bar has the keyboard.
public struct DataTableFindActions {
  /// Find… (Command-F): opens the bar with the keyboard in it.
  public let show: () -> Void
  /// Find Next (Command-G).
  public let next: () -> Void
  /// Find Previous (Shift-Command-G).
  public let previous: () -> Void
}

extension FocusedValues {
  /// The focused data table's find, which a window's Find menu takes over a text view's.
  @Entry public var dataTableFind: DataTableFindActions?
}

/// How a cell shows a find's matches: a found cell in the find highlight, the one found now in
/// full with dark text, as a text view's find draws it in both appearances.
enum DataTableFindHighlight {
  case none, match, current

  /// The cell's background.
  var fill: Color {
    switch self {
    case .none: .clear
    case .match: Self.color.opacity(0.3)
    case .current: Self.color
    }
  }

  private static var color: Color {
    #if os(macOS)
      Color(nsColor: .findHighlightColor)
    #else
      Color.yellow
    #endif
  }
}

extension View {
  /// Draws a find's highlight behind the view, with dark text over the match found now; a cell
  /// without a match is left as it is.
  @ViewBuilder func findHighlight(_ highlight: DataTableFindHighlight) -> some View {
    switch highlight {
    case .none:
      self
    case .match:
      background(highlight.fill, in: RoundedRectangle(cornerRadius: 3).inset(by: -2))
    case .current:
      foregroundStyle(.black)
        .background(highlight.fill, in: RoundedRectangle(cornerRadius: 3).inset(by: -2))
    }
  }
}
