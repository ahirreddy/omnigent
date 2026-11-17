#if os(iOS)
  import OmnigentPlatform
  import SwiftUI
  import UIKit

  /// A code block's Download and Copy over its header in a drawn run, as ``CodeBlockView`` shows
  /// them: Copy says "Copied" for a moment, Download saves the code through the system's file
  /// exporter. The drawing has the language label; code always wraps in a drawn run.
  final class MessageTextCodeControls: UIView {
    let downloadButton = UIButton(type: .system)
    let copyButton = UIButton(type: .system)
    /// What Copy and Download give.
    let code: String
    private let language: String?
    private var reset: Task<Void, Never>?

    init(code: String, language: String?, palette: MessageTextPalette) {
      self.code = code
      self.language = language
      super.init(frame: .zero)
      let size = palette.style.ramp.body
      let symbol = UIImage.SymbolConfiguration(pointSize: size)
      downloadButton.setImage(
        UIImage(systemName: "arrow.down.circle", withConfiguration: symbol), for: .normal)
      downloadButton.accessibilityLabel = "Download code"
      downloadButton.accessibilityIdentifier = "markdown.code.download"
      downloadButton.addTarget(self, action: #selector(download), for: .primaryActionTriggered)
      var copy = UIButton.Configuration.plain()
      copy.imagePadding = Theme.Spacing.extraSmall
      copy.preferredSymbolConfigurationForImage = symbol
      copy.contentInsets = .zero
      copy.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
        var attributes = $0
        attributes.uiKit.font = UIFont.systemFont(ofSize: size)
        return attributes
      }
      copyButton.configuration = copy
      copyButton.addTarget(self, action: #selector(copyCode), for: .primaryActionTriggered)
      for button in [downloadButton, copyButton] {
        button.tintColor = palette.secondary
        addSubview(button)
      }
      showCopied(false)
    }

    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
      super.layoutSubviews()
      // As the SwiftUI header pads its controls: a medium margin, a small gap between them.
      let target = Theme.Control.target
      let top = Theme.Spacing.extraSmall
      let copyWidth = max(target, copyButton.intrinsicContentSize.width.rounded(.up))
      let trailing = bounds.width - Theme.Spacing.medium
      copyButton.frame = CGRect(x: trailing - copyWidth, y: top, width: copyWidth, height: target)
      downloadButton.frame = CGRect(
        x: copyButton.frame.minX - Theme.Spacing.small - target, y: top, width: target,
        height: target)
    }

    // Only the buttons take touches: the rest of the header is the run's text.
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
      let hit = super.hitTest(point, with: event)
      return hit === self ? nil : hit
    }

    private func showCopied(_ copied: Bool) {
      copyButton.configuration?.title = copied ? "Copied" : "Copy code"
      copyButton.configuration?.image = UIImage(systemName: copied ? "checkmark" : "doc.on.doc")
      copyButton.accessibilityLabel = copied ? "Copied" : "Copy code"
      setNeedsLayout()
    }

    /// Copies the code, and says "Copied" for a moment.
    @objc func copyCode() {
      Pasteboard.copy(code)
      showCopied(true)
      reset?.cancel()
      reset = Task { [weak self] in
        do {
          try await Task.sleep(for: Theme.Timing.pause(.seconds(1.5)))
        } catch {
          // A newer copy or the view going away cancelled it; that one shows its own state.
          return
        }
        self?.showCopied(false)
      }
    }

    @objc private func download() {
      let name = "snippet.\(CodeFileExtension.for(language))"
      do {
        let folder = FileManager.default.temporaryDirectory
          .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(name)
        try Data(code.utf8).write(to: file)
        presentFromFront(UIDocumentPickerViewController(forExporting: [file], asCopy: true))
      } catch {
        let alert = UIAlertController(
          title: "Could Not Save", message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .cancel))
        presentFromFront(alert)
      }
    }
  }

  /// A table's controls row under it in a drawn run: the SwiftUI table's own row
  /// (``MarkdownTableControlsRow``), Copy and Download menus and Expand, hosted.
  enum MessageTextTableControls {
    static func make(table: MarkdownTable, environment: EnvironmentValues?) -> UIView {
      let view = UIHostingConfiguration {
        MarkdownTableControlsRow(table: table)
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .transformEnvironment(\.self) { own in
            if let environment { own = environment }
          }
      }
      .margins(.all, 0)
      .makeContentView()
      view.backgroundColor = .clear
      return view
    }
  }

  extension UIView {
    /// Presents `controller` over the front-most controller of this view's window.
    func presentFromFront(_ controller: UIViewController) {
      var front = window?.rootViewController
      while let presented = front?.presentedViewController, !presented.isBeingDismissed {
        front = presented
      }
      guard let front else { return }
      if let popover = controller.popoverPresentationController {
        popover.sourceView = self
        popover.sourceRect = bounds
      }
      front.present(controller, animated: true)
    }
  }
#endif
