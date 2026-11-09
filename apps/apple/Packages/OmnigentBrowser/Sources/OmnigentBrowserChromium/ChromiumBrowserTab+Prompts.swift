#if os(macOS)
  internal import AppKit
  internal import Foundation
  internal import OmnigentBrowser
  internal import OmnigentWebLayer

  /// Maps web-layer prompts, popups and downloads to the engine-neutral API.
  extension ChromiumBrowserTab: WebViewUIDelegate {
    func webView(_ webView: WebView, didRequest prompt: WebPrompt) {
      if case .contextMenu(let menu) = prompt {
        // Present after this message is handled; the menu runs a tracking loop.
        DispatchQueue.main.async { [weak self] in self?.presentContextMenu(menu) }
        return
      }
      guard let mapped = map(prompt) else { return }
      prompts[prompt.id] = mapped
      state.enqueue(mapped)
      guard let delegate else {
        deny(mapped)
        state.report(
          .featureUnsupported(feature: "\(mapped.kindName) (no tab delegate)", engine: .chromium))
        return
      }
      delegate.tab(self, didRequest: mapped)
    }

    func webView(_ webView: WebView, didCancel prompt: WebPrompt, reason: String) {
      guard let mapped = prompts.removeValue(forKey: prompt.id) else { return }
      mapped.base.withdraw(reason: reason)
      state.remove(mapped.base)
      delegate?.tab(self, didCancel: mapped)
    }

    func webView(_ webView: WebView, didOpen popup: WebPopup) {
      let tab = ChromiumBrowserTab(profile: profile, webView: popup.webView, engine: engine)
      tab.popupPolicy = popupPolicy
      tab.urlPolicy = urlPolicy
      let browserPopup = BrowserPopup(
        tab: tab, opener: self, targetURL: popup.targetURL,
        disposition: Self.disposition(popup.disposition), requestedSize: popup.requestedSize)
      guard let delegate else {
        tab.close()
        state.report(.popupBlocked(url: popup.targetURL, reason: "No tab delegate shows popups."))
        return
      }
      delegate.tab(self, didOpen: browserPopup)
    }

    func webView(_ webView: WebView, didBlock popup: WebBlockedPopup) {
      let blocked = BrowserBlockedPopup(url: popup.url, reason: popup.reason)
      state.lastBlockedPopup = blocked
      delegate?.tab(self, didBlock: blocked)
    }

    func webView(_ webView: WebView, wantsToOpenExternally request: WebExternalURLRequest) {
      BrowserExternalApplication.request(
        request.url, origin: request.origin, from: self, delegate: delegate)
    }

    /// Finishes a prompt locally once it is answered.
    private func finished(_ id: UInt64) {
      if let mapped = prompts.removeValue(forKey: id) {
        state.remove(mapped.base)
      }
    }

    private func deny(_ prompt: BrowserPrompt) {
      switch prompt {
      case .dialog(let dialog): dialog.cancel()
      case .permission(let permission): permission.deny()
      case .fileChooser(let chooser): chooser.cancel()
      case .download(let download): download.cancel()
      case .authentication(let auth): auth.cancel()
      case .certificateError(let certificate): certificate.cancel()
      case .color(let color): color.cancel()
      }
    }

    private func map(_ prompt: WebPrompt) -> BrowserPrompt? {
      let id = prompt.id
      switch prompt {
      case .dialog(let request): return .dialog(dialog(request, id: id))
      case .permission(let request): return .permission(permission(request, id: id))
      case .fileChooser(let request): return .fileChooser(fileChooser(request, id: id))
      case .download(let request): return .download(download(request, id: id))
      case .authentication(let request): return .authentication(authentication(request, id: id))
      case .certificateError(let request): return .certificateError(certificate(request, id: id))
      case .color(let request): return .color(color(request, id: id))
      case .contextMenu: return nil
      }
    }

    private func dialog(_ request: WebDialogRequest, id: UInt64) -> BrowserDialogPrompt {
      BrowserDialogPrompt(
        kind: Self.dialogKind(request.kind), origin: request.origin, message: request.message,
        defaultText: request.defaultText
      ) { [weak self] accepted, text in
        if accepted {
          request.accept(text: text)
        } else {
          request.cancel()
        }
        self?.finished(id)
      }
    }

    private func permission(_ request: WebPermissionRequest, id: UInt64) -> BrowserPermissionPrompt
    {
      BrowserPermissionPrompt(
        origin: BrowserPermissionStore.origin(of: request.origin),
        permissions: BrowserPermissions(rawValue: request.permissions.rawValue)
      ) { [weak self] answer in
        switch answer {
        case .allow: request.allow()
        case .deny: request.deny()
        case .dismiss: request.dismiss()
        }
        self?.finished(id)
      }
    }

    private func color(_ request: WebColorRequest, id: UInt64) -> BrowserColorPrompt {
      BrowserColorPrompt(initialColor: request.initialColor) { [weak self] hex in
        if let hex {
          request.choose(hex)
        } else {
          request.cancel()
        }
        self?.finished(id)
      }
    }

    private func fileChooser(_ request: WebFileChooserRequest, id: UInt64)
      -> BrowserFileChooserPrompt
    {
      let mode: BrowserFileChooserMode =
        switch request.mode {
        case .open: .open
        case .openMultiple: .openMultiple
        case .openFolder: .openFolder
        case .save: .save
        }
      return BrowserFileChooserPrompt(
        mode: mode, allowedExtensions: request.acceptTypes.flatMap(\.extensions),
        allowedMIMETypes: request.acceptTypes.map(\.filter).filter { $0.contains("/") },
        suggestedName: request.defaultPath.isEmpty
          ? "" : URL(fileURLWithPath: request.defaultPath).lastPathComponent
      ) { [weak self] urls in
        if urls.isEmpty {
          request.cancel()
        } else {
          request.choose(urls)
        }
        self?.finished(id)
      }
    }

    private func download(_ request: WebDownloadRequest, id: UInt64) -> BrowserDownloadPrompt {
      BrowserDownloadPrompt(
        url: request.url, suggestedName: request.suggestedName, mimeType: request.mimeType,
        totalBytes: request.totalBytes
      ) { [weak self] destination in
        defer { self?.finished(id) }
        guard let destination else {
          request.cancel()
          return
        }
        guard let webDownload = request.save(to: destination), let self else { return }
        let download = BrowserDownload(
          url: request.url, suggestedName: request.suggestedName, destination: destination,
          engine: .chromium, totalBytes: request.totalBytes
        ) { () throws(BrowserError) in
          do throws(WebLayerError) {
            try webDownload.cancel()
          } catch {
            throw Self.convert(error)
          }
        }
        engine?.track(download, as: webDownload)
        delegate?.tab(self, didStart: download)
      }
    }

    private func authentication(_ request: WebAuthRequest, id: UInt64) -> BrowserAuthPrompt {
      let space = BrowserProtectionSpace(
        host: request.host, port: request.port, realm: request.realm, scheme: request.scheme,
        isProxy: request.isProxy, isSecure: request.origin?.scheme == "https")
      return BrowserAuthPrompt(space: space) { [weak self] credential in
        if let credential {
          request.respond(username: credential.username, password: credential.password)
        } else {
          request.cancel()
        }
        self?.finished(id)
      }
    }

    private func certificate(_ request: WebCertificateErrorRequest, id: UInt64)
      -> BrowserCertificatePrompt
    {
      BrowserCertificatePrompt(
        url: request.url, message: request.message, errorCode: request.errorCode,
        subject: request.subject, issuer: request.issuer, isOverridable: request.isOverridable
      ) { [weak self] proceed in
        if proceed {
          request.proceed()
        } else {
          request.cancel()
        }
        self?.finished(id)
      }
    }

    private func presentContextMenu(_ menu: WebContextMenu) {
      guard !menu.isFinished else { return }
      guard platformView.window != nil else {
        menu.dismiss()  // Off-screen (agent) tabs never show menus.
        return
      }
      let context = BrowserContextMenuContext(
        linkURL: URL(string: menu.context.linkURL), selectionText: menu.context.selectionText,
        isEditable: menu.context.isEditable)
      var items = linkItems(context)
      items += delegate?.tab(self, contextMenuItemsFor: context) ?? []
      WebContextMenuPresenter.present(
        menu, in: platformView,
        appItems: items.map { item in WebAppMenuItem(title: item.title, action: item.action) })
    }

    func linkItems(_ context: BrowserContextMenuContext) -> [BrowserContextMenuItem] {
      guard let link = context.linkURL, !link.absoluteString.isEmpty else { return [] }
      return [
        BrowserContextMenuItem(title: "Open Link in New Tab") { [weak self] in
          self?.openInNewTab(link)
        },
        BrowserContextMenuItem(title: "Copy Link") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(link.absoluteString, forType: .string)
        },
      ]
    }

    /// Opens `url` in a new tab of this profile, without an opener.
    func openInNewTab(_ url: URL) {
      guard let engine else { return }
      do {
        let tab = try engine.makeTab(profile: profile, initialURL: url)
        tab.popupPolicy = popupPolicy
        tab.urlPolicy = urlPolicy
        delegate?.tab(
          self,
          didOpen: BrowserPopup(
            tab: tab, opener: self, targetURL: url, disposition: .foregroundTab,
            requestedSize: nil))
      } catch {
        state.report(error)
      }
    }

    private static func dialogKind(_ kind: WebDialogKind) -> BrowserDialogKind {
      switch kind {
      case .alert: .alert
      case .confirm: .confirm
      case .prompt: .prompt
      case .beforeUnload: .beforeUnload
      }
    }

    private static func disposition(_ disposition: WebPopupDisposition) -> BrowserPopupDisposition {
      switch disposition {
      case .currentTab, .foregroundTab: .foregroundTab
      case .backgroundTab: .backgroundTab
      case .popup: .popup
      case .window: .window
      }
    }
  }

  /// Agent input on Chromium: the web layer's renderer-direct path.
  final class ChromiumAgentInput: BrowserAgentInput {
    private weak var webView: WebView?

    init(webView: WebView) {
      self.webView = webView
    }

    var isRendererDirect: Bool { true }
    var needsHostWindow: Bool { false }

    func prepareForAgent(viewport: CGSize) {
      guard let webView else { return }
      webView.rendersOffscreen = true
      webView.updateGeometry(size: viewport, scale: 2, screenOrigin: .zero)
    }

    private func renderer() throws(BrowserError) -> WebContentRenderer {
      guard let webView else { throw .tabClosed }
      return webView.renderer
    }

    func click(at point: CGPoint, clickCount: Int) throws(BrowserError) {
      let renderer = try renderer()
      do {
        try renderer.agentClick(at: point, clickCount: clickCount)
      } catch {
        throw ChromiumBrowserTab.convert(error)
      }
    }

    func scroll(at point: CGPoint, deltaX: Double, deltaY: Double) throws(BrowserError) {
      let renderer = try renderer()
      do {
        // Chromium wheel deltas are positive for scrolling up and left.
        try renderer.agentScroll(at: point, deltaX: -deltaX, deltaY: -deltaY)
      } catch {
        throw ChromiumBrowserTab.convert(error)
      }
    }

    func insertText(_ text: String) throws(BrowserError) {
      let renderer = try renderer()
      do {
        try renderer.agentInsertText(text)
      } catch {
        throw ChromiumBrowserTab.convert(error)
      }
    }

    func press(_ key: BrowserAgentKey, modifiers: BrowserAgentModifiers) throws(BrowserError) {
      var agentModifiers: AgentModifiers = []
      if modifiers.contains(.shift) { agentModifiers.insert(.shift) }
      if modifiers.contains(.control) { agentModifiers.insert(.control) }
      if modifiers.contains(.option) { agentModifiers.insert(.option) }
      if modifiers.contains(.command) { agentModifiers.insert(.command) }
      let renderer = try renderer()
      do {
        try renderer.agentPress(Self.agentKey(key), modifiers: agentModifiers)
      } catch {
        throw ChromiumBrowserTab.convert(error)
      }
    }

    private static let namedKeys: [BrowserAgentKey: AgentKey] = [
      .enter: .enter, .tab: .tab, .escape: .escape, .backspace: .backspace, .delete: .delete,
      .arrowLeft: .arrowLeft, .arrowRight: .arrowRight, .arrowUp: .arrowUp,
      .arrowDown: .arrowDown, .home: .home, .end: .end, .pageUp: .pageUp, .pageDown: .pageDown,
    ]

    private static func agentKey(_ key: BrowserAgentKey) -> AgentKey {
      if case .character(let character) = key { return .character(character) }
      guard let mapped = namedKeys[key] else {
        preconditionFailure("BrowserAgentKey \(key) has no AgentKey; namedKeys is incomplete.")
      }
      return mapped
    }
  }
#endif
