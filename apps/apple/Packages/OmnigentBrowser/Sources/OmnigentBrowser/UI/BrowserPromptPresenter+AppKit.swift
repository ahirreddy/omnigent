#if os(macOS)
  public import AppKit
  internal import UniformTypeIdentifiers

  /// Native sheets on macOS: NSAlert for dialogs, permissions and HTTP auth, NSOpenPanel and
  /// NSSavePanel for files and downloads, NSColorPanel for colors.
  extension BrowserPromptPresenter {
    /// The alert on screen, for tests and proofs that drive the sheet.
    public var presentedAlert: NSAlert? { presentedSheet as? NSAlert }
    /// The open or save panel on screen, for tests and proofs.
    public var presentedPanel: NSSavePanel? { presentedSheet as? NSSavePanel }

    func showSheet(_ prompt: BrowserPrompt, for tab: any BrowserTab) -> Bool {
      guard let window = tab.platformView.window else {
        denyUnshowable(prompt, tab: tab, reason: "the tab is not in a window")
        return false
      }
      switch prompt {
      case .dialog(let dialog): showDialog(dialog, in: window)
      case .permission(let permission): showPermission(permission, tab: tab, in: window)
      case .fileChooser(let chooser): showFileChooser(chooser, in: window)
      case .download(let download): showSavePanel(download, in: window)
      case .authentication(let auth): showAuth(auth, tab: tab, in: window)
      case .color(let color): showColorPanel(color)
      case .certificateError:
        return false  // Shown as an interstitial, never queued.
      }
      return true
    }

    func dismissPresentedSheet() {
      if let alert = presentedAlert, let parent = alert.window.sheetParent {
        parent.endSheet(alert.window, returnCode: .cancel)
      } else if let panel = presentedPanel {
        panel.cancel(nil)
      } else if presentedSheet is ColorPanelObserver {
        NSColorPanel.shared.close()
      }
    }

    private func run(
      _ alert: NSAlert, in window: NSWindow, _ done: @escaping (NSApplication.ModalResponse) -> Void
    ) {
      presentedSheet = alert
      alert.beginSheetModal(for: window) { [weak self] response in
        MainActor.assumeIsolated {
          done(response)
          self?.sheetDidEnd()
        }
      }
    }

    private static func host(_ url: URL?) -> String {
      url?.host(percentEncoded: false) ?? url?.absoluteString ?? "This page"
    }

    private func showDialog(_ prompt: BrowserDialogPrompt, in window: NSWindow) {
      let alert = NSAlert()
      alert.messageText =
        prompt.kind == .beforeUnload ? "Leave this page?" : "\(Self.host(prompt.origin)) says"
      alert.informativeText =
        prompt.kind == .beforeUnload ? "Changes you made may not be saved." : prompt.message
      alert.addButton(withTitle: prompt.kind == .beforeUnload ? "Leave" : "OK")
      if prompt.kind != .alert { alert.addButton(withTitle: "Cancel") }
      var field: NSTextField?
      if prompt.kind == .prompt {
        let input = NSTextField(string: prompt.defaultText)
        input.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
        input.setAccessibilityIdentifier("browser.dialog.text")
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        field = input
      }
      run(alert, in: window) { response in
        if response == .alertFirstButtonReturn {
          prompt.accept(text: field?.stringValue)
        } else {
          prompt.cancel()
        }
      }
    }

    private func showPermission(
      _ prompt: BrowserPermissionPrompt, tab: any BrowserTab, in window: NSWindow
    ) {
      let alert = NSAlert()
      let names = prompt.permissions.names.joined(separator: " and ")
      alert.messageText = "\(prompt.origin) wants to use your \(names)."
      alert.informativeText =
        tab.profile.persistence == .persistent
        ? "Your choice is remembered for this site."
        : "Your choice is remembered until this private session ends."
      alert.addButton(withTitle: "Allow")
      alert.addButton(withTitle: "Don't Allow")
      alert.showsSuppressionButton = true
      alert.suppressionButton?.title = "Remember for this site"
      alert.suppressionButton?.state = .on
      run(alert, in: window) { [weak self] response in
        guard !prompt.isFinished else { return }
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else {
          prompt.dismiss()
          return
        }
        self?.recordPermission(
          prompt, allowed: response == .alertFirstButtonReturn,
          remember: alert.suppressionButton?.state == .on, tab: tab)
      }
    }

    private func showAuth(_ prompt: BrowserAuthPrompt, tab: any BrowserTab, in window: NSWindow) {
      let alert = NSAlert()
      let space = prompt.space
      alert.messageText = "Sign in to \(space.host)"
      alert.informativeText =
        (space.isProxy ? "The proxy " : "The server ") + "requires a user name and password."
        + (space.realm.isEmpty ? "" : " (\(space.realm))")
        + (space.isSecure ? "" : " Your password is sent without encryption.")
      alert.addButton(withTitle: "Sign In")
      alert.addButton(withTitle: "Cancel")
      let stored = storedCredential(for: prompt, tab: tab)
      let username = NSTextField(string: stored?.username ?? "")
      username.placeholderString = "User name"
      username.setAccessibilityIdentifier("browser.auth.username")
      let password = NSSecureTextField(string: stored?.password ?? "")
      password.placeholderString = "Password"
      password.setAccessibilityIdentifier("browser.auth.password")
      let remember = NSButton(checkboxWithTitle: "Remember in Keychain", target: nil, action: nil)
      remember.state = stored == nil ? .off : .on
      remember.isHidden = tab.profile.persistence != .persistent
      let stack = NSStackView(views: [username, password, remember])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.frame = NSRect(x: 0, y: 0, width: 300, height: 84)
      for field in [username, password] {
        field.widthAnchor.constraint(equalToConstant: 300).isActive = true
      }
      alert.accessoryView = stack
      alert.window.initialFirstResponder = username
      run(alert, in: window) { [weak self] response in
        guard response == .alertFirstButtonReturn else {
          prompt.cancel()
          return
        }
        let credential = BrowserCredential(
          username: username.stringValue, password: password.stringValue)
        if remember.state == .on, !remember.isHidden {
          self?.rememberCredential(credential, for: prompt, tab: tab)
        }
        prompt.respond(credential)
      }
    }

    private func showFileChooser(_ prompt: BrowserFileChooserPrompt, in window: NSWindow) {
      let types = Self.contentTypes(prompt)
      let panel: NSSavePanel
      if prompt.mode == .save {
        panel = NSSavePanel()
        panel.nameFieldStringValue = prompt.suggestedName
      } else {
        let open = NSOpenPanel()
        open.canChooseFiles = prompt.mode != .openFolder
        open.canChooseDirectories = prompt.mode == .openFolder
        open.allowsMultipleSelection = prompt.mode == .openMultiple
        panel = open
      }
      if !types.isEmpty { panel.allowedContentTypes = types }
      presentedSheet = panel
      panel.beginSheetModal(for: window) { [weak self] response in
        MainActor.assumeIsolated {
          if response == .OK {
            let urls = (panel as? NSOpenPanel)?.urls ?? panel.url.map { [$0] } ?? []
            if urls.isEmpty {
              prompt.cancel()
            } else {
              prompt.choose(urls)
            }
          } else {
            prompt.cancel()
          }
          self?.sheetDidEnd()
        }
      }
    }

    static func contentTypes(_ prompt: BrowserFileChooserPrompt) -> [UTType] {
      var types = prompt.allowedExtensions.compactMap { UTType(filenameExtension: $0) }
      for mime in prompt.allowedMIMETypes {
        if mime.hasSuffix("/*") {
          let family = String(mime.dropLast(2))
          types.append(
            family == "image"
              ? .image
              : family == "video"
                ? .movie
                : family == "audio"
                  ? .audio
                  : family == "text" ? .text : .item)
        } else if let type = UTType(mimeType: mime) {
          types.append(type)
        }
      }
      return types
    }

    private func showSavePanel(_ prompt: BrowserDownloadPrompt, in window: NSWindow) {
      let panel = NSSavePanel()
      panel.nameFieldStringValue = BrowserDownloadSettings.safeFileName(prompt.suggestedName)
      panel.directoryURL = downloadSettings.directory
      panel.message = "Save the download from \(Self.host(prompt.url))"
      presentedSheet = panel
      panel.beginSheetModal(for: window) { [weak self] response in
        MainActor.assumeIsolated {
          if response == .OK, let url = panel.url {
            prompt.save(to: url)
          } else {
            prompt.cancel()
          }
          self?.sheetDidEnd()
        }
      }
    }

    private func showColorPanel(_ prompt: BrowserColorPrompt) {
      let observer = ColorPanelObserver(prompt: prompt) { [weak self] in self?.sheetDidEnd() }
      presentedSheet = observer
      observer.show()
    }

    func openInWindow(_ popup: BrowserPopup) {
      BrowserPopupWindowController.open(popup, presenter: self)
    }
  }

  /// Answers a color prompt when the shared color panel closes.
  final class ColorPanelObserver: NSObject {
    let prompt: BrowserColorPrompt
    private let onEnd: () -> Void
    private var observer: (any NSObjectProtocol)?

    init(prompt: BrowserColorPrompt, onEnd: @escaping () -> Void) {
      self.prompt = prompt
      self.onEnd = onEnd
    }

    func show() {
      let panel = NSColorPanel.shared
      panel.color = Self.color(hex: prompt.initialColor) ?? .black
      panel.showsAlpha = false
      observer = NotificationCenter.default.addObserver(
        forName: NSWindow.willCloseNotification, object: panel, queue: .main
      ) { [weak self] _ in
        MainActor.assumeIsolated { self?.finish() }
      }
      panel.orderFront(nil)
    }

    func finish() {
      if let observer { NotificationCenter.default.removeObserver(observer) }
      observer = nil
      prompt.choose(Self.hex(NSColorPanel.shared.color))
      onEnd()
    }

    static func hex(_ color: NSColor) -> String {
      let rgb = color.usingColorSpace(.sRGB) ?? .black
      let parts = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map {
        String(format: "%02x", Int(($0 * 255).rounded()))
      }
      return "#" + parts.joined()
    }

    static func color(hex: String) -> NSColor? {
      guard hex.count == 7, hex.first == "#", let value = Int(hex.dropFirst(), radix: 16) else {
        return nil
      }
      return NSColor(
        srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255,
        blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }
  }
#endif
