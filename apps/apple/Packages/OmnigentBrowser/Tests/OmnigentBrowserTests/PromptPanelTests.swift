#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import Testing
  import UniformTypeIdentifiers

  @testable import OmnigentBrowser

  @MainActor
  @Suite("Prompt panels", .serialized)
  struct PromptPanelTests {
    private func chooser(
      _ fixture: PresenterFixture, mode: BrowserFileChooserMode, answers: Answers<[URL]>
    ) {
      let prompt = BrowserFileChooserPrompt(
        mode: mode, allowedExtensions: ["txt"], allowedMIMETypes: [], suggestedName: "notes.txt"
      ) { answers.values.append($0) }
      fixture.presenter.tab(fixture.tab, didRequest: .fileChooser(prompt))
    }

    @Test(
      "every file chooser mode opens a panel; cancelling answers no files",
      arguments: [
        BrowserFileChooserMode.open, .openMultiple, .openFolder, .save,
      ])
    func fileChoosers(mode: BrowserFileChooserMode) throws {
      let fixture = try PresenterFixture()
      let answers = Answers<[URL]>()
      chooser(fixture, mode: mode, answers: answers)
      #expect(SystemSideEffects.record.panelCount == 1)
      #expect(answers.values == [[]])
      #expect(fixture.presenter.presentedPrompt == nil)
    }

    @Test("an OK from a panel that holds no file answers no files")
    func fileChooserWithoutAFile() throws {
      let fixture = try PresenterFixture()
      SystemSideEffects.answer(panel: .OK)
      let answers = Answers<[URL]>()
      chooser(fixture, mode: .open, answers: answers)
      #expect(answers.values == [[]])
    }

    @Test("a save panel's OK answers where the page should write")
    func fileChooserSave() throws {
      let fixture = try PresenterFixture()
      SystemSideEffects.answer(panel: .OK)
      let answers = Answers<[URL]>()
      chooser(fixture, mode: .save, answers: answers)
      #expect(answers.values.count == 1)
      // The panel never ran, so it holds its own default name; the answer is still its URL.
      #expect(answers.values[0].count == 1)
    }

    @Test("MIME patterns map to the panel's content types")
    func contentTypes() {
      let prompt = BrowserFileChooserPrompt(
        mode: .open, allowedExtensions: ["png", "", "zzznotreal"],
        allowedMIMETypes: [
          "image/*", "video/*", "audio/*", "text/*", "font/*", "application/pdf",
          "not a type",
        ],
        suggestedName: ""
      ) { _ in }
      let types = BrowserPromptPresenter.contentTypes(prompt)
      #expect(types.contains(.png))
      #expect(types.contains(.image))
      #expect(types.contains(.movie))
      #expect(types.contains(.audio))
      #expect(types.contains(.text))
      #expect(types.contains(.item))
      #expect(types.contains(.pdf))
    }

    @Test("a download asks where to save; Cancel stops it")
    func downloadPanel() throws {
      let fixture = try PresenterFixture()
      let answers = Answers<URL?>()
      let cancelled = BrowserDownloadPrompt(
        url: try testURL("https://a.example/f.zip"), suggestedName: "../f.zip", mimeType: "",
        totalBytes: nil
      ) { answers.values.append($0) }
      fixture.presenter.tab(fixture.tab, didRequest: .download(cancelled))
      #expect(SystemSideEffects.record.panelCount == 1)
      #expect(answers.values.count == 1 && answers.values[0] == nil)

      SystemSideEffects.answer(panel: .OK)
      let saved = BrowserDownloadPrompt(
        url: nil, suggestedName: "f.zip", mimeType: "", totalBytes: 4
      ) { answers.values.append($0) }
      fixture.presenter.tab(fixture.tab, didRequest: .download(saved))
      #expect(answers.values.count == 2)
      #expect(answers.values[1] != nil)
    }

    @Test("a download folder that can't exist cancels the download and says why")
    func downloadFolderUnavailable() throws {
      let fixture = try PresenterFixture()
      fixture.presenter.downloadSettings.askBeforeDownload = false
      let file = FileManager.default.temporaryDirectory.appending(path: "owl-file-\(UUID())")
      try Data().write(to: file)
      defer { try? FileManager.default.removeItem(at: file) }
      fixture.presenter.downloadSettings.directory = file.appending(path: "sub")
      let answers = Answers<URL?>()
      let prompt = BrowserDownloadPrompt(
        url: nil, suggestedName: "f.zip", mimeType: "", totalBytes: nil
      ) { answers.values.append($0) }
      fixture.presenter.tab(fixture.tab, didRequest: .download(prompt))
      #expect(answers.values.count == 1 && answers.values[0] == nil)
      guard case .downloadFailed = fixture.tab.state.lastError else {
        Issue.record("expected a failed download on the tab")
        return
      }
    }

    @Test("a color input answers when the panel closes")
    func colorPanel() throws {
      let fixture = try PresenterFixture()
      let answers = Answers<String?>()
      let prompt = BrowserColorPrompt(initialColor: "#102030") { answers.values.append($0) }
      fixture.presenter.tab(fixture.tab, didRequest: .color(prompt))
      #expect(fixture.presenter.presentedPrompt != nil)
      #expect(answers.values.isEmpty)

      fixture.presenter.dismissPresentedSheet()
      NotificationCenter.default.post(
        name: NSWindow.willCloseNotification, object: NSColorPanel.shared)
      #expect(answers.values == ["#102030"])
      #expect(fixture.presenter.presentedPrompt == nil)
    }

    @Test("colors convert both ways, and a bad color is refused")
    func colorConversion() throws {
      let color = try #require(ColorPanelObserver.color(hex: "#ff8000"))
      #expect(ColorPanelObserver.hex(color) == "#ff8000")
      #expect(ColorPanelObserver.color(hex: "ff8000") == nil)
      #expect(ColorPanelObserver.color(hex: "#gggggg") == nil)
      #expect(ColorPanelObserver.color(hex: "#fff") == nil)
    }

    @Test("a withdrawn certificate leaves the page")
    func withdrawnCertificate() throws {
      let fixture = try PresenterFixture()
      let prompt = BrowserCertificatePrompt(
        url: nil, message: "", errorCode: 1, subject: "", issuer: "", isOverridable: true
      ) { _ in }
      fixture.presenter.tab(fixture.tab, didRequest: .certificateError(prompt))
      #expect(fixture.presenter.interstitial(for: fixture.tab) != nil)
      fixture.presenter.tab(fixture.tab, didCancel: .certificateError(prompt))
      #expect(fixture.presenter.interstitial(for: fixture.tab) == nil)
    }
  }
#endif
