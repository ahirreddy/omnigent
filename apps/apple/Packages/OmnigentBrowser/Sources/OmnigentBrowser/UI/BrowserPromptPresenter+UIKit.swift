#if os(iOS)
  internal import UIKit

  /// iOS and iPadOS sheets: UIAlertController for dialogs, permissions and HTTP auth. File
  /// choosers and colors use WebKit's own pickers there, so they never reach the presenter;
  /// if they do, they are cancelled and reported.
  extension BrowserPromptPresenter {
    func showSheet(_ prompt: BrowserPrompt, for tab: any BrowserTab) -> Bool {
      guard let root = tab.platformView.window?.rootViewController else {
        denyUnshowable(prompt, tab: tab, reason: "the tab is not in a window")
        return false
      }
      let host = root.presentedViewController ?? root
      let alert: UIAlertController
      switch prompt {
      case .dialog(let dialog): alert = dialogAlert(dialog)
      case .permission(let permission): alert = permissionAlert(permission, tab: tab)
      case .authentication(let auth): alert = authAlert(auth)
      case .download(let download):
        download.save(to: downloadSettings.uniqueDestination(for: download.suggestedName))
        return false
      case .fileChooser, .color, .certificateError:
        denyUnshowable(prompt, tab: tab, reason: "not supported on this platform")
        return false
      }
      presentedSheet = alert
      host.present(alert, animated: true)
      return true
    }

    func dismissPresentedSheet() {
      (presentedSheet as? UIAlertController)?.dismiss(animated: true) { [weak self] in
        MainActor.assumeIsolated { self?.sheetDidEnd() }
      }
    }

    func openInWindow(_ popup: BrowserPopup) {
      // No popup windows on iOS without an app handler: load in the opener instead.
      if let url = popup.targetURL { popup.opener.load(url) }
      popup.tab.close()
    }

    private func action(_ title: String, _ style: UIAlertAction.Style, _ run: @escaping () -> Void)
      -> UIAlertAction
    {
      UIAlertAction(title: title, style: style) { [weak self] _ in
        MainActor.assumeIsolated {
          run()
          self?.sheetDidEnd()
        }
      }
    }

    private func dialogAlert(_ prompt: BrowserDialogPrompt) -> UIAlertController {
      let alert = UIAlertController(
        title: prompt.origin?.host(percentEncoded: false), message: prompt.message,
        preferredStyle: .alert)
      if prompt.kind == .prompt {
        alert.addTextField { $0.text = prompt.defaultText }
      }
      alert.addAction(
        action("OK", .default) { [weak alert] in
          prompt.accept(text: alert?.textFields?.first?.text)
        })
      if prompt.kind != .alert {
        alert.addAction(action("Cancel", .cancel) { prompt.cancel() })
      }
      return alert
    }

    private func permissionAlert(_ prompt: BrowserPermissionPrompt, tab: any BrowserTab)
      -> UIAlertController
    {
      let alert = UIAlertController(
        title:
          "\(prompt.origin) wants to use your \(prompt.permissions.names.joined(separator: " and ")).",
        message: nil, preferredStyle: .alert)
      alert.addAction(
        action("Allow", .default) { [weak self] in
          self?.recordPermission(prompt, allowed: true, remember: true, tab: tab)
        })
      alert.addAction(
        action("Don't Allow", .cancel) { [weak self] in
          self?.recordPermission(prompt, allowed: false, remember: true, tab: tab)
        })
      return alert
    }

    private func authAlert(_ prompt: BrowserAuthPrompt) -> UIAlertController {
      let alert = UIAlertController(
        title: "Sign in to \(prompt.space.host)", message: prompt.space.realm,
        preferredStyle: .alert)
      alert.addTextField { $0.placeholder = "User name" }
      alert.addTextField {
        $0.placeholder = "Password"
        $0.isSecureTextEntry = true
      }
      alert.addAction(
        action("Sign In", .default) { [weak alert] in
          prompt.respond(
            BrowserCredential(
              username: alert?.textFields?.first?.text ?? "",
              password: alert?.textFields?.last?.text ?? ""))
        })
      alert.addAction(action("Cancel", .cancel) { prompt.cancel() })
      return alert
    }
  }
#endif
