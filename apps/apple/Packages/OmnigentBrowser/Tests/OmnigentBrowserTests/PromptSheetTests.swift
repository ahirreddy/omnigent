#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentBrowser

  @MainActor
  @Suite("Prompt sheets", .serialized)
  struct PromptSheetTests {
    private func dialog(
      _ fixture: PresenterFixture, kind: BrowserDialogKind, origin: URL? = nil,
      answers: Answers<String?>
    ) {
      let prompt = BrowserDialogPrompt(
        kind: kind, origin: origin, message: "Hello", defaultText: "typed"
      ) { accepted, text in answers.values.append(accepted ? text ?? "accepted" : nil) }
      fixture.presenter.tab(fixture.tab, didRequest: .dialog(prompt))
    }

    @Test("alert, confirm and prompt dialogs name the site and answer the page")
    func dialogs() throws {
      let fixture = try PresenterFixture()
      let answers = Answers<String?>()
      dialog(fixture, kind: .alert, origin: try testURL("https://a.example/"), answers: answers)
      dialog(fixture, kind: .confirm, answers: answers)
      dialog(fixture, kind: .prompt, answers: answers)
      #expect(answers.values == ["accepted", "accepted", "typed"])
      #expect(
        SystemSideEffects.record.alertMessages == [
          "a.example says", "This page says", "This page says",
        ])
      #expect(fixture.presenter.presentedPrompt == nil)

      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      dialog(fixture, kind: .confirm, answers: answers)
      #expect(answers.values.last == .some(nil))
    }

    @Test("leaving a page asks about unsaved changes")
    func beforeUnload() throws {
      let fixture = try PresenterFixture()
      let answers = Answers<String?>()
      dialog(fixture, kind: .beforeUnload, answers: answers)
      #expect(SystemSideEffects.record.alertMessages == ["Leave this page?"])
      #expect(answers.values == ["accepted"])
    }

    private func permission(_ fixture: PresenterFixture, answers: Answers<BrowserPermissionAnswer>)
      -> BrowserPermissionPrompt
    {
      let prompt = BrowserPermissionPrompt(
        origin: "https://a.example", permissions: [.camera, .microphone]
      ) { answers.values.append($0) }
      fixture.presenter.tab(fixture.tab, didRequest: .permission(prompt))
      return prompt
    }

    @Test("Allow is remembered, so the site isn't asked again")
    func allowIsRemembered() throws {
      let fixture = try PresenterFixture()
      let answers = Answers<BrowserPermissionAnswer>()
      _ = permission(fixture, answers: answers)
      #expect(answers.values == [.allow])
      #expect(SystemSideEffects.record.alertMessages.count == 1)
      #expect(SystemSideEffects.record.alertMessages[0].contains("https://a.example wants"))

      _ = permission(fixture, answers: answers)
      #expect(answers.values == [.allow, .allow])
      #expect(SystemSideEffects.record.alertMessages.count == 1)
    }

    @Test("Don't Allow denies and is remembered; closing the sheet decides nothing")
    func denyAndDismiss() throws {
      let fixture = try PresenterFixture()
      let answers = Answers<BrowserPermissionAnswer>()
      SystemSideEffects.answer(alert: .cancel)
      _ = permission(fixture, answers: answers)
      #expect(answers.values == [.dismiss])
      let store = fixture.presenter.permissionStore
      #expect(
        store.decision(for: .camera, origin: "https://a.example", profile: fixture.tab.profile)
          == nil)

      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      _ = permission(fixture, answers: answers)
      #expect(answers.values == [.dismiss, .deny])
      #expect(
        store.decision(for: .camera, origin: "https://a.example", profile: fixture.tab.profile)
          == .deny)
    }

    @Test("a private profile's permission is asked the same way")
    func privateProfilePermission() throws {
      let fixture = try PresenterFixture(profile: .ephemeral("private"))
      let answers = Answers<BrowserPermissionAnswer>()
      _ = permission(fixture, answers: answers)
      #expect(answers.values == [.allow])
    }

    private func authenticate(_ fixture: PresenterFixture) -> Answers<BrowserCredential?> {
      let answers = Answers<BrowserCredential?>()
      let prompt = BrowserAuthPrompt(space: PresenterFixture.space) { answers.values.append($0) }
      fixture.presenter.tab(fixture.tab, didRequest: .authentication(prompt))
      return answers
    }

    @Test("a stored password fills the sign-in sheet and stays stored")
    func signInWithStoredPassword() throws {
      let store = InMemoryBrowserCredentialStore()
      let saved = BrowserCredential(username: "ada", password: "lovelace")
      store.save(saved, for: PresenterFixture.space)
      let fixture = try PresenterFixture(credentials: store)
      #expect(authenticate(fixture).values == [saved])
      #expect(SystemSideEffects.record.alertMessages == ["Sign in to site.example"])
      #expect(store.credential(for: PresenterFixture.space) == saved)
    }

    @Test("signing in without a stored password stores nothing, and Cancel answers nothing")
    func signInWithoutStoredPassword() throws {
      let store = InMemoryBrowserCredentialStore()
      let fixture = try PresenterFixture(credentials: store)
      #expect(authenticate(fixture).values == [BrowserCredential(username: "", password: "")])
      #expect(store.credential(for: PresenterFixture.space) == nil)

      SystemSideEffects.answer(alert: .alertSecondButtonReturn)
      let cancelled = authenticate(fixture).values
      #expect(cancelled.count == 1 && cancelled[0] == nil)
    }

    @Test("a locked Keychain reaches the tab instead of hiding the sheet")
    func keychainFailure() throws {
      let fixture = try PresenterFixture(credentials: FailingCredentialStore())
      #expect(authenticate(fixture).values.count == 1)
      #expect(fixture.tab.state.lastError == .credentialStoreFailed("locked"))

      fixture.tab.state.report(.tabNotReady)
      let prompt = BrowserAuthPrompt(space: PresenterFixture.space) { _ in }
      fixture.presenter.rememberCredential(
        BrowserCredential(username: "a", password: "b"), for: prompt, tab: fixture.tab)
      #expect(fixture.tab.state.lastError == .credentialStoreFailed("locked"))
    }

    @Test("a private profile never reads or writes the Keychain")
    func privateProfileSkipsTheKeychain() throws {
      let fixture = try PresenterFixture(
        profile: .ephemeral("private"), credentials: FailingCredentialStore())
      #expect(authenticate(fixture).values.count == 1)
      #expect(fixture.tab.state.lastError == nil)
    }

    @Test("a tab that isn't in a window refuses every prompt and says why")
    func noWindow() throws {
      let fixture = try PresenterFixture()
      fixture.tab.platformView.removeFromSuperview()
      fixture.window.contentView = nil
      var answered = 0
      let prompts: [BrowserPrompt] = [
        .dialog(
          BrowserDialogPrompt(kind: .alert, origin: nil, message: "", defaultText: "") { _, _ in
            answered += 1
          }),
        .permission(
          BrowserPermissionPrompt(origin: "https://a.example", permissions: .camera) { _ in
            answered += 1
          }),
        .fileChooser(
          BrowserFileChooserPrompt(
            mode: .open, allowedExtensions: [], allowedMIMETypes: [], suggestedName: ""
          ) { _ in answered += 1 }),
        .download(
          BrowserDownloadPrompt(url: nil, suggestedName: "f", mimeType: "", totalBytes: nil) { _ in
            answered += 1
          }),
        .authentication(BrowserAuthPrompt(space: PresenterFixture.space) { _ in answered += 1 }),
        .color(BrowserColorPrompt(initialColor: "#000000") { _ in answered += 1 }),
      ]
      for prompt in prompts {
        fixture.presenter.tab(fixture.tab, didRequest: prompt)
        guard case .featureUnsupported = fixture.tab.state.lastError else {
          Issue.record("\(prompt.kindName) said nothing")
          continue
        }
        fixture.tab.state.lastError = nil
      }
      #expect(answered == prompts.count)
      #expect(SystemSideEffects.record.alertMessages.isEmpty)

      // A certificate is only denied when something calls for it directly.
      let certificate = BrowserCertificatePrompt(
        url: nil, message: "", errorCode: 1, subject: "", issuer: "", isOverridable: false
      ) { _ in answered += 1 }
      fixture.presenter.denyUnshowable(
        .certificateError(certificate), tab: fixture.tab, reason: "test")
      #expect(answered == prompts.count + 1)
    }

    @Test("a queued prompt that was answered meanwhile is skipped, and a withdrawn one dropped")
    func queue() throws {
      let fixture = try PresenterFixture()
      let answers = Answers<String?>()
      let colorPrompt = BrowserColorPrompt(initialColor: "#000000") { answers.values.append($0) }
      fixture.presenter.tab(fixture.tab, didRequest: .color(colorPrompt))

      func queued(_ name: String) -> BrowserDialogPrompt {
        BrowserDialogPrompt(kind: .alert, origin: nil, message: "", defaultText: "") { _, _ in
          answers.values.append(name)
        }
      }
      let finished = queued("finished")
      let withdrawn = queued("withdrawn")
      let waiting = queued("waiting")
      fixture.presenter.tab(fixture.tab, didRequest: .dialog(finished))
      fixture.presenter.tab(fixture.tab, didRequest: .dialog(withdrawn))
      fixture.presenter.tab(fixture.tab, didRequest: .dialog(waiting))
      #expect(fixture.presenter.queue.count == 3)
      finished.cancel()
      answers.values.removeAll()
      fixture.presenter.tab(fixture.tab, didCancel: .dialog(withdrawn))
      #expect(fixture.presenter.queue.count == 2)

      fixture.presenter.tab(fixture.tab, didCancel: .color(colorPrompt))
      NotificationCenter.default.post(
        name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
      #expect(answers.values == ["#000000", "waiting"])
    }

    @Test("withdrawing the prompt on screen closes its alert or panel")
    func dismissingAPresentedSheet() throws {
      let fixture = try PresenterFixture()
      let alert = NSAlert()
      fixture.window.beginSheet(alert.window)
      fixture.presenter.presentedSheet = alert
      fixture.presenter.dismissPresentedSheet()
      #expect(fixture.window.attachedSheet == nil)

      let panel = NSSavePanel()
      fixture.presenter.presentedSheet = panel
      fixture.presenter.dismissPresentedSheet()
      #expect(!panel.isVisible)
      #expect(fixture.presenter.presentedPanel === panel)

      let loose = NSAlert()
      fixture.presenter.presentedSheet = loose
      fixture.presenter.dismissPresentedSheet()
      #expect(fixture.presenter.presentedAlert === loose)
    }

    @Test("a failed certificate override reaches the tab")
    func certificateOverrideFailure() throws {
      let fixture = try PresenterFixture()
      let answered = BrowserCertificatePrompt(
        url: nil, message: "", errorCode: 1, subject: "", issuer: "", isOverridable: false
      ) { _ in }
      fixture.presenter.tab(fixture.tab, didRequest: .certificateError(answered))
      fixture.presenter.resolveInterstitial(for: fixture.tab, proceed: true)
      #expect(fixture.tab.state.lastError != nil)
      // No interstitial left: a second answer does nothing.
      fixture.tab.state.lastError = nil
      fixture.presenter.resolveInterstitial(for: fixture.tab, proceed: true)
      #expect(fixture.tab.state.lastError == nil)
    }

    @Test("started downloads join the list under the tab's profile; blocked popups only log")
    func downloadsAndBlockedPopups() throws {
      let fixture = try PresenterFixture()
      let download = BrowserDownload(
        url: nil, suggestedName: "f", destination: URL(fileURLWithPath: "/tmp/f"), engine: .system,
        totalBytes: nil, cancel: {})
      fixture.presenter.tab(fixture.tab, didStart: download)
      #expect(download.profileIdentifier == fixture.tab.profile.identifier)
      #expect(fixture.presenter.downloadCenter.items.count == 1)
      fixture.presenter.tab(
        fixture.tab, didBlock: BrowserBlockedPopup(url: nil, reason: "no gesture"))
      #expect(
        fixture.presenter.tab(
          fixture.tab,
          contextMenuItemsFor: BrowserContextMenuContext(
            linkURL: nil, selectionText: "", isEditable: false)
        ).isEmpty)
    }
  }

  @MainActor
  @Suite("Popup windows", .serialized)
  struct PopupWindowTests {
    private func popup(
      _ fixture: PresenterFixture, disposition: BrowserPopupDisposition = .popup,
      size: CGSize? = CGSize(width: 320, height: 240), url: URL? = nil
    ) -> (BrowserPopup, FakeTab) {
      let tab = FakeTab(kind: .system, profile: fixture.tab.profile, initialURL: nil)
      return (
        BrowserPopup(
          tab: tab, opener: fixture.tab, targetURL: url, disposition: disposition,
          requestedSize: size), tab
      )
    }

    @Test("without a tab strip, a popup gets its own window titled with its host")
    func opensAWindow() async throws {
      let fixture = try PresenterFixture()
      let (popup, tab) = popup(fixture, url: try testURL("https://pop.example/"))
      fixture.presenter.tab(fixture.tab, didOpen: popup)
      #expect(tab.delegate === fixture.presenter)
      #expect(SystemSideEffects.record.shownWindowTitles.last == "pop.example")

      // The page calling window.close() closes the window, which closes the tab once.
      tab.close()
      await letTasksRun()
      #expect(tab.state.isClosed)
    }

    @Test("closing the popup's window closes its tab")
    func closingTheWindowClosesTheTab() throws {
      let fixture = try PresenterFixture()
      let (popup, tab) = popup(fixture, disposition: .foregroundTab, size: nil)
      fixture.presenter.tab(fixture.tab, didOpen: popup)
      #expect(SystemSideEffects.record.shownWindowTitles.last == "New Window")
      let window = try #require(NSApp.windows.last { $0.title == "New Window" })
      window.close()
      #expect(tab.state.isClosed)
    }

    @Test("a popup window's only engine is its tab's, and it never starts another")
    func popupProvider() throws {
      let fixture = try PresenterFixture()
      let (_, tab) = popup(fixture)
      let provider = PopupProvider(tab: tab)
      #expect(provider.offeredEngines == [tab.engineKind])
      #expect(provider.availability(of: tab.engineKind) == .available)
      let other: BrowserEngineKind = tab.engineKind == .system ? .chromium : .system
      let reason = "Popup windows keep their engine."
      #expect(
        provider.availability(of: other) == .unavailable(.engineNotBundled(other, reason: reason)))
      #expect(throws: BrowserError.engineNotBundled(other, reason: reason)) {
        try provider.engine(for: other)
      }
    }

    @Test("an app's popup handler takes the popup instead of a window")
    func handlerTakesThePopup() throws {
      let fixture = try PresenterFixture()
      var handled = 0
      fixture.presenter.onOpenPopup = { _ in handled += 1 }
      let (popup, _) = popup(fixture)
      fixture.presenter.tab(fixture.tab, didOpen: popup)
      #expect(handled == 1)
      #expect(SystemSideEffects.record.shownWindowTitles.isEmpty)
    }
  }
#endif
