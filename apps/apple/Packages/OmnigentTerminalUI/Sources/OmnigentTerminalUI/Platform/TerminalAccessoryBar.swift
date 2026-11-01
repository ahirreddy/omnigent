#if os(iOS)
  import UIKit

  /// The row above the software keyboard with the keys a terminal needs and iOS keyboards lack:
  /// Escape, sticky Control and Option, Tab, arrows, common symbols, paste and dismiss.
  final class TerminalAccessoryBar: UIInputView {
    /// What a button sends.
    enum Key: Equatable {
      case special(TerminalKey)
      case text(String)
      case paste
      case dismissKeyboard
    }

    var onKey: ((Key) -> Void)?

    private var control = false
    private var option = false
    private let controlButton = UIButton(configuration: .gray())
    private let optionButton = UIButton(configuration: .gray())

    init(frame: CGRect) {
      super.init(frame: frame, inputViewStyle: .keyboard)
      allowsSelfSizing = true
      let scroll = UIScrollView()
      scroll.showsHorizontalScrollIndicator = false
      scroll.translatesAutoresizingMaskIntoConstraints = false
      addSubview(scroll)
      let stack = UIStackView()
      stack.axis = .horizontal
      stack.spacing = 6
      stack.translatesAutoresizingMaskIntoConstraints = false
      scroll.addSubview(stack)
      NSLayoutConstraint.activate([
        scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
        scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
        scroll.topAnchor.constraint(equalTo: topAnchor),
        scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        heightAnchor.constraint(equalToConstant: 46),
        stack.leadingAnchor.constraint(
          equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
        stack.trailingAnchor.constraint(
          equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
        stack.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        stack.heightAnchor.constraint(equalToConstant: 34),
      ])
      stack.addArrangedSubview(button("esc", accessibility: "Escape", key: .special(.escape)))
      configureToggle(controlButton, title: "ctrl", accessibility: "Control")
      controlButton.addAction(
        UIAction { [weak self] _ in self?.toggleControl() }, for: .touchUpInside)
      stack.addArrangedSubview(controlButton)
      configureToggle(optionButton, title: "alt", accessibility: "Option")
      optionButton.addAction(
        UIAction { [weak self] _ in self?.toggleOption() }, for: .touchUpInside)
      stack.addArrangedSubview(optionButton)
      stack.addArrangedSubview(button("tab", accessibility: "Tab", key: .special(.tab)))
      stack.addArrangedSubview(
        symbol("arrow.left", accessibility: "Left", key: .special(.arrowLeft)))
      stack.addArrangedSubview(
        symbol("arrow.down", accessibility: "Down", key: .special(.arrowDown)))
      stack.addArrangedSubview(symbol("arrow.up", accessibility: "Up", key: .special(.arrowUp)))
      stack.addArrangedSubview(
        symbol("arrow.right", accessibility: "Right", key: .special(.arrowRight)))
      for text in ["~", "|", "/", "-", "`"] {
        stack.addArrangedSubview(button(text, accessibility: text, key: .text(text)))
      }
      stack.addArrangedSubview(
        symbol("doc.on.clipboard", accessibility: "Paste", key: .paste))
      stack.addArrangedSubview(
        symbol(
          "keyboard.chevron.compact.down", accessibility: "Hide keyboard", key: .dismissKeyboard)
      )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      nil
    }

    /// The sticky modifiers for the next key, which then release.
    func takeModifiers() -> TerminalModifiers {
      var modifiers: TerminalModifiers = []
      if control { modifiers.insert(.control) }
      if option { modifiers.insert(.option) }
      if control { toggleControl() }
      if option { toggleOption() }
      return modifiers
    }

    private func toggleControl() {
      control.toggle()
      controlButton.configuration = control ? .filled() : .gray()
      controlButton.configuration?.title = "ctrl"
      controlButton.accessibilityValue = control ? "On" : "Off"
    }

    private func toggleOption() {
      option.toggle()
      optionButton.configuration = option ? .filled() : .gray()
      optionButton.configuration?.title = "alt"
      optionButton.accessibilityValue = option ? "On" : "Off"
    }

    private func configureToggle(_ button: UIButton, title: String, accessibility: String) {
      button.configuration?.title = title
      button.accessibilityLabel = accessibility
      button.accessibilityValue = "Off"
      button.accessibilityTraits.insert(.button)
    }

    private func button(_ title: String, accessibility: String, key: Key) -> UIButton {
      var configuration = UIButton.Configuration.gray()
      configuration.title = title
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 4, leading: 10, bottom: 4, trailing: 10)
      let button = UIButton(
        configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onKey?(key) }
      )
      button.accessibilityLabel = accessibility
      return button
    }

    private func symbol(_ name: String, accessibility: String, key: Key) -> UIButton {
      var configuration = UIButton.Configuration.gray()
      configuration.image = UIImage(systemName: name)
      configuration.contentInsets = NSDirectionalEdgeInsets(
        top: 4, leading: 10, bottom: 4, trailing: 10)
      let button = UIButton(
        configuration: configuration, primaryAction: UIAction { [weak self] _ in self?.onKey?(key) }
      )
      button.accessibilityLabel = accessibility
      return button
    }
  }
#endif
