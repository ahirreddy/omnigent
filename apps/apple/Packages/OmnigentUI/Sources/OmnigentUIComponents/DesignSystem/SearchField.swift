import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The system's search field, for a search or filter inside a pane, a list or a sheet:
/// `NSSearchField` on a Mac, `UISearchTextField` on iPhone and iPad. Return calls `submit`;
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
    func makeUIView(context: Context) -> UISearchTextField {
      let view = UISearchTextField()
      view.placeholder = prompt
      view.autocapitalizationType = .none
      view.returnKeyType = .search
      view.delegate = context.coordinator
      view.addTarget(
        context.coordinator, action: #selector(Coordinator.edited(_:)), for: .editingChanged)
      view.setContentHuggingPriority(.defaultLow, for: .horizontal)
      view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      if let identifier { view.accessibilityIdentifier = identifier }
      return view
    }

    func updateUIView(_ view: UISearchTextField, context: Context) {
      context.coordinator.field = self
      if view.text != text { view.text = text }
      if view.placeholder != prompt { view.placeholder = prompt }
      view.isEnabled = context.environment.isEnabled
      guard isFocused?.wrappedValue == true, !view.isFirstResponder else { return }
      // The field may not be in its window yet on the update that asks for the keyboard.
      Task { @MainActor [weak view] in
        guard let view, !view.isFirstResponder else { return }
        view.becomeFirstResponder()
      }
    }
  }

  extension SearchField.Coordinator: UITextFieldDelegate {
    /// Typing, pasting and the clear button.
    @objc func edited(_ sender: UISearchTextField) { changed(sender.text ?? "") }

    func textFieldDidBeginEditing(_ textField: UITextField) { focusChanged(true) }

    func textFieldDidEndEditing(_ textField: UITextField) { focusChanged(false) }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
      if let submit = field.submit {
        submit()
      } else {
        textField.resignFirstResponder()
      }
      return true
    }
  }
#endif
