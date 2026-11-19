import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The system's search field, for a search or filter inside a pane, a list or a sheet:
/// `NSSearchField` on a Mac, `UISearchBar`'s field on iPhone and iPad. Return calls `submit`;
/// Escape calls `escape`, which says whether it took the key (otherwise the field clears itself).
/// `isFocused` follows the keyboard and, set to `true`, puts the keyboard in the field.
struct SearchField {
  let prompt: String
  @Binding var text: String
  var identifier: String?
  var isFocused: Binding<Bool>?
  var submit: (@MainActor () -> Void)?
  var escape: (@MainActor () -> Bool)?

  init(
    _ prompt: String, text: Binding<String>, identifier: String? = nil,
    isFocused: Binding<Bool>? = nil, submit: (@MainActor () -> Void)? = nil,
    escape: (@MainActor () -> Bool)? = nil
  ) {
    self.prompt = prompt
    _text = text
    self.identifier = identifier
    self.isFocused = isFocused
    self.submit = submit
    self.escape = escape
  }

  func makeCoordinator() -> Coordinator { Coordinator(self) }

  /// Keeps the field's binding, focus and keys current.
  final class Coordinator: NSObject {
    var field: SearchField

    init(_ field: SearchField) {
      self.field = field
    }

    func changed(_ text: String) {
      if field.text != text { field.text = text }
    }

    func focusChanged(_ focused: Bool) {
      if let isFocused = field.isFocused, isFocused.wrappedValue != focused {
        isFocused.wrappedValue = focused
      }
    }
  }
}

#if os(macOS)
  extension SearchField: NSViewRepresentable {
    func makeNSView(context: Context) -> NSSearchField {
      let view = NSSearchField()
      view.placeholderString = prompt
      view.delegate = context.coordinator
      view.setContentHuggingPriority(.defaultLow, for: .horizontal)
      if let identifier { view.setAccessibilityIdentifier(identifier) }
      return view
    }

    func updateNSView(_ view: NSSearchField, context: Context) {
      context.coordinator.field = self
      if view.stringValue != text { view.stringValue = text }
      if view.placeholderString != prompt { view.placeholderString = prompt }
      view.controlSize = Self.controlSize(context.environment.controlSize)
      view.isEnabled = context.environment.isEnabled
      guard isFocused?.wrappedValue == true, view.currentEditor() == nil else { return }
      // The field may not be in its window yet on the update that asks for the keyboard.
      Task { @MainActor [weak view] in
        guard let view, view.currentEditor() == nil, let window = unsafe view.window else { return }
        window.makeFirstResponder(view)
      }
    }

    private static func controlSize(_ size: ControlSize) -> NSControl.ControlSize {
      switch size {
      case .mini: .mini
      case .small: .small
      case .large, .extraLarge: .large
      default: .regular
      }
    }
  }

  extension SearchField.Coordinator: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
      guard let view = notification.object as? NSSearchField else { return }
      changed(view.stringValue)
    }

    func controlTextDidBeginEditing(_ notification: Notification) { focusChanged(true) }

    func controlTextDidEndEditing(_ notification: Notification) { focusChanged(false) }

    /// The clear button, which empties the field without a text change.
    func searchFieldDidEndSearching(_ sender: NSSearchField) { changed("") }

    func control(
      _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
      switch selector {
      case #selector(NSResponder.insertNewline(_:)):
        guard let submit = field.submit else { return false }
        submit()
        return true
      case #selector(NSResponder.cancelOperation(_:)):
        return field.escape?() ?? false
      default:
        return false
      }
    }
  }
#else
  extension SearchField: UIViewRepresentable {
    func makeUIView(context: Context) -> UISearchBar {
      let bar = UISearchBar()
      bar.searchBarStyle = .minimal
      bar.placeholder = prompt
      bar.autocapitalizationType = .none
      bar.delegate = context.coordinator
      bar.setContentHuggingPriority(.defaultLow, for: .horizontal)
      if let identifier { bar.searchTextField.accessibilityIdentifier = identifier }
      return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
      context.coordinator.field = self
      if bar.text != text { bar.text = text }
      if bar.placeholder != prompt { bar.placeholder = prompt }
      bar.isUserInteractionEnabled = context.environment.isEnabled
      guard isFocused?.wrappedValue == true, !bar.searchTextField.isFirstResponder else { return }
      Task { @MainActor [weak bar] in
        guard let bar, !bar.searchTextField.isFirstResponder else { return }
        bar.searchTextField.becomeFirstResponder()
      }
    }
  }

  extension SearchField.Coordinator: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
      changed(searchText)
    }

    func searchBarTextDidBeginEditing(_ searchBar: UISearchBar) { focusChanged(true) }

    func searchBarTextDidEndEditing(_ searchBar: UISearchBar) { focusChanged(false) }

    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
      if let submit = field.submit {
        submit()
      } else {
        searchBar.resignFirstResponder()
      }
    }
  }
#endif
