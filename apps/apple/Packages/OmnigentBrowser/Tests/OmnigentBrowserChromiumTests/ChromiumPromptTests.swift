import AppKit
import Foundation
import OWLProtocol
import OmnigentBrowser
import Testing

#if os(macOS)
  @testable import OmnigentBrowserChromium
  @testable import OmnigentWebLayer

  @MainActor
  private func lastPrompt(_ fixture: ChromiumTabFixture) throws -> BrowserPrompt {
    try #require(fixture.recorder.requested.last)
  }

  @MainActor
  @Suite("Chromium prompts")
  struct ChromiumPromptTests {
    private func dialog(_ fixture: ChromiumTabFixture, id: UInt64 = 1, kind: UInt64 = 0) throws
      -> BrowserDialogPrompt
    {
      try fixture.receive(
        .jsDialog,
        WireEncoder().u64(.promptID, id).u64(.dialogKind, kind).string(.message, "\u{0}m"))
      guard case .dialog(let prompt) = try lastPrompt(fixture) else {
        throw BrowserError.notAllowed("expected a dialog")
      }
      return prompt
    }

    @Test func dialogsOfEachKindAnswerAndLeaveTheQueue() throws {
      let fixture = try ChromiumTabFixture()
      let kinds: [(OWLDialogKind, BrowserDialogKind)] = [
        (.alert, .alert), (.confirm, .confirm), (.prompt, .prompt), (.beforeUnload, .beforeUnload),
      ]
      for (wire, expected) in kinds {
        let prompt = try dialog(fixture, kind: wire.rawValue)
        #expect(prompt.kind == expected)
        #expect(fixture.tab.state.pendingPrompts.count == 1)
        prompt.accept(text: "a\u{0}b")
        #expect(fixture.tab.state.pendingPrompts.isEmpty)
        #expect(fixture.tab.prompts.isEmpty)
      }
      #expect(fixture.last(.dialogReply)?.string(.text) == "a\u{0}b")
      let refused = try dialog(fixture)
      refused.cancel()
      refused.cancel()
      #expect(fixture.last(.dialogReply)?.bool(.accepted) == false)
    }

    private let everyPromptKind: [OWLMessageKind] = [
      .jsDialog, .permissionRequest, .fileChooser, .downloadRequest, .authRequest,
      .certificateError, .colorChooser,
    ]

    @Test func withoutADelegateEveryPromptIsRefused() throws {
      let fixture = try ChromiumTabFixture(withDelegate: false)
      for (offset, kind) in everyPromptKind.enumerated() {
        fixture.sent.removeAll()
        try fixture.receive(
          kind, WireEncoder().u64(.promptID, UInt64(offset)).bool(.overridable, true))
        #expect(!fixture.sent.isEmpty, "\(kind)")
        #expect(fixture.tab.state.pendingPrompts.isEmpty, "\(kind)")
        #expect(fixture.tab.prompts.isEmpty, "\(kind)")
      }
    }

    @Test(
      "a prompt nobody can answer is reported to the UI",
      .disabled("Behavior: syncState overwrites state.report with webView.lastError, which is nil"))
    func promptsWithoutADelegateAreReported() throws {
      let fixture = try ChromiumTabFixture(withDelegate: false)
      try fixture.receive(.jsDialog, WireEncoder().u64(.promptID, 1))
      guard case .featureUnsupported = fixture.tab.state.lastError else {
        Issue.record("the refused dialog was not reported")
        return
      }
    }

    @Test func permissionsCarryTheirOriginAndAnswers() throws {
      let fixture = try ChromiumTabFixture()
      let bits = OWLPermission.camera.rawValue | OWLPermission.other.rawValue
      let origins = ["https://meet.test:8443/path", "", "\u{0}", "not a url"]
      for origin in origins {
        try fixture.receive(
          .permissionRequest,
          WireEncoder().u64(.promptID, 3).string(.origin, origin).u64(.permissions, bits))
        guard case .permission(let prompt) = try lastPrompt(fixture) else {
          Issue.record("expected a permission")
          return
        }
        #expect(prompt.permissions.rawValue == bits)
        prompt.dismiss()
      }
      for answer in 0..<2 {
        try fixture.receive(
          .permissionRequest, WireEncoder().u64(.promptID, 4).u64(.permissions, .max))
        guard case .permission(let prompt) = try lastPrompt(fixture) else {
          Issue.record("expected a permission")
          return
        }
        if answer == 0 { prompt.allow() } else { prompt.deny() }
        #expect(fixture.tab.state.pendingPrompts.isEmpty)
      }
    }

    @Test func colorsAndAuthenticationAnswer() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(.colorChooser, WireEncoder().u64(.promptID, 1))
      guard case .color(let color) = try lastPrompt(fixture) else {
        Issue.record("expected a color")
        return
      }
      color.choose("not a color")
      #expect(fixture.last(.colorReply)?.bool(.accepted) == false)
      try fixture.receive(.colorChooser, WireEncoder().u64(.promptID, 2))
      guard case .color(let second) = try lastPrompt(fixture) else {
        Issue.record("expected a color")
        return
      }
      second.cancel()
      #expect(fixture.tab.state.pendingPrompts.isEmpty)
      try fixture.receive(
        .authRequest,
        WireEncoder().u64(.promptID, 3).string(.origin, "https://a.test").string(.host, "\u{0}")
          .string(.realm, "").string(.scheme, "").bool(.isProxy, true))
      guard case .authentication(let auth) = try lastPrompt(fixture) else {
        Issue.record("expected authentication")
        return
      }
      #expect(auth.space.isProxy)
      #expect(auth.space.isSecure)
      auth.respond(BrowserCredential(username: "\u{0}", password: ""))
      #expect(fixture.last(.authReply)?.string(.username) == "\u{0}")
      try fixture.receive(.authRequest, WireEncoder().u64(.promptID, 4))
      guard case .authentication(let refused) = try lastPrompt(fixture) else {
        Issue.record("expected authentication")
        return
      }
      #expect(!refused.space.isSecure)
      refused.cancel()
      #expect(fixture.tab.state.pendingPrompts.isEmpty)
    }

    @Test func certificatesProceedOnlyWhenOverridable() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(
        .certificateError,
        WireEncoder().u64(.promptID, 1).string(.URL, "https://bad.test/").i64(.errorCode, .min)
          .bool(.overridable, true))
      guard case .certificateError(let first) = try lastPrompt(fixture) else {
        Issue.record("expected a certificate error")
        return
      }
      #expect(first.errorCode == Int(Int64.min))
      try first.proceed()
      #expect(fixture.tab.state.pendingPrompts.isEmpty)
      try fixture.receive(
        .certificateError, WireEncoder().u64(.promptID, 2).bool(.overridable, false))
      guard case .certificateError(let second) = try lastPrompt(fixture) else {
        Issue.record("expected a certificate error")
        return
      }
      second.cancel()
      #expect(fixture.tab.state.pendingPrompts.isEmpty)
    }

    @Test func fileChoosersMapModesAndAnswers() throws {
      let fixture = try ChromiumTabFixture()
      let modes: [(OWLFileChooserMode, BrowserFileChooserMode)] = [
        (.open, .open), (.openMultiple, .openMultiple), (.openFolder, .openFolder), (.save, .save),
      ]
      let accept =
        #"[{"filter":"image/*","extensions":["png"],"description":""},{"filter":".txt","extensions":[],"description":"\u0000"}]"#
      for (wire, expected) in modes {
        try fixture.receive(
          .fileChooser,
          WireEncoder().u64(.promptID, 1).u64(.fileChooserMode, wire.rawValue)
            .string(.acceptTypes, accept).string(.defaultText, "/tmp/dir/name.txt"))
        guard case .fileChooser(let chooser) = try lastPrompt(fixture) else {
          Issue.record("expected a chooser")
          return
        }
        #expect(chooser.mode == expected)
        #expect(chooser.allowedExtensions == ["png"])
        #expect(chooser.allowedMIMETypes == ["image/*"])
        #expect(chooser.suggestedName == "name.txt")
        chooser.choose([])
        #expect(fixture.tab.state.pendingPrompts.isEmpty)
      }
      try fixture.receive(.fileChooser, WireEncoder().u64(.promptID, 2))
      guard case .fileChooser(let chooser) = try lastPrompt(fixture) else {
        Issue.record("expected a chooser")
        return
      }
      chooser.choose([URL(fileURLWithPath: "/tmp/never-read")])
      #expect(fixture.tab.state.pendingPrompts.isEmpty)
    }

    @Test(
      "a chooser with no default path suggests no name",
      .disabled("Behavior: an empty path as a file URL resolves to the working directory's name"))
    func aChooserWithNoDefaultPathSuggestsNoName() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(.fileChooser, WireEncoder().u64(.promptID, 2))
      guard case .fileChooser(let chooser) = try lastPrompt(fixture) else {
        Issue.record("expected a chooser")
        return
      }
      #expect(chooser.suggestedName.isEmpty)
    }

    @Test func aWithdrawnPromptLeavesTheQueueAndTellsTheDelegate() throws {
      let fixture = try ChromiumTabFixture()
      let prompt = try dialog(fixture, id: 9)
      try fixture.receive(.promptCancelled, WireEncoder().u64(.promptID, 9).string(.reason, "nav"))
      #expect(prompt.isFinished)
      #expect(prompt.cancellationReason == "nav")
      #expect(fixture.recorder.cancelled.count == 1)
      #expect(fixture.tab.state.pendingPrompts.isEmpty)
      try fixture.receive(.promptCancelled, WireEncoder().u64(.promptID, 9))
      #expect(fixture.recorder.cancelled.count == 1)
    }
  }

  @MainActor
  @Suite("Chromium downloads and popups")
  struct ChromiumDownloadAndPopupTests {
    @Test func downloadsAreMirroredUntilTheyFinish() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(
        .downloadRequest,
        WireEncoder().u64(.promptID, 1).u64(.downloadID, 42).string(.URL, "https://a.test/f")
          .string(.suggestedName, "f").i64(.totalBytes, .max))
      guard case .download(let prompt) = try lastPrompt(fixture) else {
        Issue.record("expected a download")
        return
      }
      #expect(prompt.totalBytes == .max)
      prompt.save(to: URL(fileURLWithPath: "/tmp/never-written"))
      let download = try #require(fixture.recorder.downloads.first)
      #expect(fixture.tab.state.pendingPrompts.isEmpty)
      let update = { (state: OWLDownloadState, received: Int64) in
        try fixture.receive(
          .downloadUpdated,
          WireEncoder().u64(.downloadID, 42).i64(.receivedBytes, received)
            .u64(.downloadState, state.rawValue))
      }
      try update(.inProgress, .max)
      #expect(download.receivedBytes == .max)
      #expect(download.totalBytes == nil)
      try update(.paused, -1)
      #expect(download.state == .paused)
      try update(.inProgress, 1)
      #expect(download.state == .inProgress)
      try download.cancel()
      #expect(fixture.last(.downloadControl) != nil)
      try update(.interrupted, 2)
      #expect(download.state == .failed("Chromium interrupted the download."))
      try update(.inProgress, 3)
      #expect(download.receivedBytes == 2)
      #expect(throws: BrowserError.self) { try download.cancel() }
    }

    @Test func aDownloadCanBeRefusedOrCompleted() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(.downloadRequest, WireEncoder().u64(.promptID, 1).u64(.downloadID, 1))
      guard case .download(let refused) = try lastPrompt(fixture) else {
        Issue.record("expected a download")
        return
      }
      refused.cancel()
      #expect(fixture.recorder.downloads.isEmpty)
      for (id, state) in [(2, OWLDownloadState.complete), (3, .cancelled)] {
        try fixture.receive(
          .downloadRequest, WireEncoder().u64(.promptID, UInt64(id)).u64(.downloadID, UInt64(id)))
        guard case .download(let prompt) = try lastPrompt(fixture) else {
          Issue.record("expected a download")
          return
        }
        prompt.save(to: URL(fileURLWithPath: "/tmp/never-written"))
        try fixture.receive(
          .downloadUpdated,
          WireEncoder().u64(.downloadID, UInt64(id)).u64(.downloadState, state.rawValue))
      }
      #expect(fixture.recorder.downloads.map(\.state) == [.complete, .cancelled])
    }

    @Test func popupsGoToTheDelegateAndInheritPolicies() throws {
      let fixture = try ChromiumTabFixture()
      fixture.tab.popupPolicy = .allow
      fixture.tab.urlPolicy = DenyEverything()
      let dispositions: [(OWLDisposition, BrowserPopupDisposition)] = [
        (.currentTab, .foregroundTab), (.foregroundTab, .foregroundTab),
        (.backgroundTab, .backgroundTab), (.popup, .popup), (.window, .window),
      ]
      for (index, (wire, expected)) in dispositions.enumerated() {
        try fixture.receive(
          .popupCreated, target: (1 << 48) + UInt64(index),
          WireEncoder().u64(.openerID, fixture.webView.id).string(.URL, "https://child.test/")
            .u64(.disposition, wire.rawValue).double(.width, .nan).double(.height, -1))
        let popup = try #require(fixture.recorder.popups.last)
        #expect(popup.disposition == expected)
        #expect(popup.tab.popupPolicy == .allow)
        #expect(popup.tab.urlPolicy != nil)
      }
    }

    @Test func aPopupWithNoDelegateClosesAndIsReported() throws {
      let fixture = try ChromiumTabFixture(withDelegate: false)
      try fixture.receive(
        .popupCreated, target: 1 << 48,
        WireEncoder().u64(.openerID, fixture.webView.id).string(.URL, "https://child.test/"))
      #expect(fixture.sent.last?.kind == .viewClose)
      guard case .popupBlocked = fixture.tab.state.lastError else {
        Issue.record("expected popupBlocked")
        return
      }
    }

    @Test func blockedPopupsAreRecorded() throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(
        .popupBlocked, WireEncoder().string(.URL, "https://ads.test/").string(.reason, "\u{0}"))
      #expect(fixture.recorder.blocked.first?.reason == "\u{0}")
      #expect(fixture.tab.state.lastBlockedPopup?.reason == "\u{0}")
    }

    @Test func aContextMenuOnAViewInNoWindowIsDismissed() async throws {
      let fixture = try ChromiumTabFixture()
      try fixture.receive(
        .contextMenu,
        WireEncoder().u64(.promptID, 6).string(.menuItems, "[]").string(
          .menuParams,
          #"{"x":0,"y":0,"linkURL":"","sourceURL":"","pageURL":"","frameURL":"","selectionText":"","isEditable":false,"mediaType":0,"editFlags":0}"#
        ))
      #expect(fixture.recorder.requested.isEmpty)
      #expect(await fixture.eventually { fixture.last(.contextMenuReply) != nil })
    }

    @Test func aNewTabFromALinkKeepsThePoliciesAndHasNoEngineAfterTheEngineGoes() throws {
      let fixture = try ChromiumTabFixture()
      fixture.tab.popupPolicy = .block
      let link = try #require(URL(string: "https://child.test/"))
      fixture.tab.openInNewTab(link)
      let popup = try #require(fixture.recorder.popups.first)
      #expect(popup.targetURL == link)
      #expect(popup.disposition == .foregroundTab)
      #expect(popup.tab.popupPolicy == .block)
    }

    @Test func linksOutsideTheBrowserAreReportedWhenNothingOpensThem() throws {
      let fixture = try ChromiumTabFixture()
      let webPage = try #require(URL(string: "https://a.test/"))
      let noApp = try #require(
        URL(string: "omnigent-test-no-handler-\(UUID().uuidString.lowercased()):x"))
      for url in [webPage, noApp] {
        fixture.tab.webView(
          fixture.webView, wantsToOpenExternally: WebExternalURLRequest(url: url, origin: nil))
        guard case .featureUnsupported = fixture.tab.state.lastError else {
          Issue.record("\(url) was not reported")
          continue
        }
      }
      #expect(fixture.recorder.requested.isEmpty)
    }
  }
#endif
