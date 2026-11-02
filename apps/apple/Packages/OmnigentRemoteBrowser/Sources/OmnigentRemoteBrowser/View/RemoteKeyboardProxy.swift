#if os(iOS)
  import OmnigentCoreFFI
  import UIKit

  /// The software keyboard for a remote text field: an invisible first responder that takes
  /// over while the page's focused field is editable (after the user tapped the page), typing
  /// committed text and named keys into the remote page. Hardware keys go to the view.
  final class RemoteKeyboardProxy: UIView, UIKeyInput {
    weak var owner: RemoteBrowserView?

    var keyboardType = UIKeyboardType.default
    var returnKeyType = UIReturnKeyType.default
    var autocorrectionType = UITextAutocorrectionType.no
    var autocapitalizationType = UITextAutocapitalizationType.none
    var spellCheckingType = UITextSpellCheckingType.no
    var smartQuotesType = UITextSmartQuotesType.no
    var smartDashesType = UITextSmartDashesType.no
    var smartInsertDeleteType = UITextSmartInsertDeleteType.no

    override init(frame: CGRect) {
      super.init(frame: frame)
      isAccessibilityElement = false
      accessibilityIdentifier = "remote-browser.keyboard"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      nil
    }

    override var canBecomeFirstResponder: Bool { true }

    /// Always true, so Delete stays enabled: the page owns the text.
    var hasText: Bool { true }

    func insertText(_ text: String) {
      owner?.typeText(text)
    }

    func deleteBackward() {
      owner?.pressNamedKey("Backspace", hidUsage: 0x2A)
    }

    /// Matches the keyboard to the remote field.
    /// - Parameter mode: The page's text input mode.
    /// - Returns: Whether the traits changed (the keyboard must reload).
    func configure(for mode: TextInputKind) -> Bool {
      let (type, returnKey): (UIKeyboardType, UIReturnKeyType) =
        switch mode {
        case .tel: (.phonePad, .default)
        case .url: (.URL, .go)
        case .email: (.emailAddress, .default)
        case .numeric: (.numberPad, .default)
        case .decimal: (.decimalPad, .default)
        case .search: (.webSearch, .search)
        case .text, .none: (.default, .default)
        }
      guard type != keyboardType || returnKey != returnKeyType else { return false }
      keyboardType = type
      returnKeyType = returnKey
      return true
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard owner?.sendKeys(presses, down: true) == true else {
        super.pressesBegan(presses, with: event)
        return
      }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      guard owner?.sendKeys(presses, down: false) == true else {
        super.pressesEnded(presses, with: event)
        return
      }
    }
  }
#endif
