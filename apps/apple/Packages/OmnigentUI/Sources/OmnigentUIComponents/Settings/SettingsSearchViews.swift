public import SwiftUI

/// What Settings search needs from the page's owner: the index for what this build, server and
/// account show, and how to reach what the page itself can't (a server's pane).
public struct SettingsSearchConfiguration {
  /// Every result the page can land on.
  public var entries: [SettingsSearchEntry]
  /// Set to focus the search field (the palette's Search Settings…); the field clears it.
  public var focusRequest: Binding<Bool>
  /// Shows a pane of the server's settings.
  public var openServerPane: @MainActor (ServerSettingsPane) -> Void

  /// Creates the configuration.
  /// - Parameters:
  ///   - entries: The index.
  ///   - focusRequest: Focuses the field while set.
  ///   - openServerPane: Shows a server pane.
  public init(
    entries: [SettingsSearchEntry], focusRequest: Binding<Bool>,
    openServerPane: @escaping @MainActor (ServerSettingsPane) -> Void
  ) {
    self.entries = entries
    self.focusRequest = focusRequest
    self.openServerPane = openServerPane
  }
}

/// A row Settings search scrolls to, once per pick.
public struct SettingsReveal: Equatable {
  /// The row's anchor (``View/settingsSearchAnchor(_:)``).
  public let anchor: String
  let id = UUID()

  /// Creates a request to reveal `anchor`.
  /// - Parameter anchor: The row's anchor.
  public init(anchor: String) { self.anchor = anchor }
}

extension EnvironmentValues {
  /// The Settings row search just revealed, which marks itself for a moment.
  @Entry var settingsRevealedAnchor: String?
}

extension View {
  /// Makes this Settings row one search can reveal: the page scrolls to `anchor` and the row's
  /// background takes the accent for a moment. Use the row's accessibility identifier.
  /// - Parameter anchor: The row's identifier in ``SettingsSearchIndex``.
  /// - Returns: The row.
  public func settingsSearchAnchor(_ anchor: String) -> some View {
    modifier(SettingsSearchAnchorMark(anchor: anchor))
  }

  /// Scrolls to and marks a revealed row inside this content, then clears the request so the
  /// pane's next appearance stays where the user left it.
  /// - Parameter reveal: The row to reveal.
  /// - Returns: The content.
  public func revealsSettingsRows(_ reveal: Binding<SettingsReveal?>) -> some View {
    modifier(SettingsRevealScroller(reveal: reveal))
  }
}

private struct SettingsSearchAnchorMark: ViewModifier {
  let anchor: String
  @Environment(\.settingsRevealedAnchor) private var revealed

  func body(content: Content) -> some View {
    content
      .id(anchor)
      // `nil` keeps the row's own background.
      .listRowBackground(revealed == anchor ? Rectangle().fill(Theme.accent.opacity(0.18)) : nil)
  }
}

/// Scrolls the content to a revealed row once it has laid out, and marks it for two seconds.
private struct SettingsRevealScroller: ViewModifier {
  @Binding var reveal: SettingsReveal?
  @State private var marked: String?

  func body(content: Content) -> some View {
    ScrollViewReader { proxy in
      content
        .environment(\.settingsRevealedAnchor, marked)
        .task(id: reveal) {
          guard let request = reveal else { return }
          // The pane picked with the result builds first.
          do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
          withAnimation { proxy.scrollTo(request.anchor, anchor: .center) }
          marked = request.anchor
          reveal = nil
        }
        .task(id: marked) {
          guard marked != nil else { return }
          do { try await Task.sleep(for: .seconds(2)) } catch { return }
          withAnimation { marked = nil }
        }
    }
  }
}

/// A result's two lines: the setting, then where it is (or a shortcut's keys).
public struct SettingsSearchResultRow: View {
  private let entry: SettingsSearchEntry

  /// Creates the row.
  /// - Parameter entry: The result.
  public init(entry: SettingsSearchEntry) { self.entry = entry }

  /// The row.
  public var body: some View {
    VStack(alignment: .leading, spacing: 1) {
      HStack(spacing: Theme.Spacing.small) {
        Text(entry.title).lineLimit(1)
        if let keys = entry.keys {
          Spacer(minLength: 0)
          Text(keys).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
      }
      Text(entry.location)
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .accessibilityElement(children: .combine)
  }
}

#if os(macOS)
  import AppKit

  /// The Settings sidebar's search field: the system search field, which clears on Escape.
  /// Return picks the first result.
  struct SettingsSearchField: NSViewRepresentable {
    @Binding var text: String
    /// Takes the keyboard each time this changes.
    let focusToken: Int
    let submit: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSearchField {
      let field = NSSearchField()
      field.placeholderString = "Search Settings"
      field.sendsSearchStringImmediately = true
      field.delegate = context.coordinator
      field.setAccessibilityIdentifier("settings-search")
      context.coordinator.focusToken = focusToken
      return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
      context.coordinator.parent = self
      if field.stringValue != text { field.stringValue = text }
      guard context.coordinator.focusToken != focusToken else { return }
      context.coordinator.focusToken = focusToken
      // After this update, so SwiftUI's own focus bookkeeping doesn't take the keyboard back.
      RunLoop.main.perform {
        // AppKit declares `window` unowned(unsafe); it is read while the field is in it.
        unsafe field.window?.makeFirstResponder(field)
      }
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
      var parent: SettingsSearchField
      /// The focus request already met.
      var focusToken = 0

      init(_ parent: SettingsSearchField) { self.parent = parent }

      func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSSearchField else { return }
        parent.text = field.stringValue
      }

      func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector)
        -> Bool
      {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
          parent.submit()
          return true
        case #selector(NSResponder.cancelOperation(_:)) where !parent.text.isEmpty:
          // Escape clears the query; with none, it goes on to leave Settings.
          (control as? NSSearchField)?.stringValue = ""
          parent.text = ""
          return true
        default:
          return false
        }
      }
    }
  }
#endif
