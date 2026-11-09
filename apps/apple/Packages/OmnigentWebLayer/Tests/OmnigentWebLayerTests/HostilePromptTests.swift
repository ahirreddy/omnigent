import AppKit
import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

@MainActor
@Suite("Prompts from a broken host")
struct HostilePromptTests {
  private func prompt(_ fixture: ProtocolFixture) throws -> WebPrompt {
    try #require(fixture.recorder.requested.last)
  }

  @Test func promptsWithNoFieldsUseTheirDefaults() throws {
    let fixture = ProtocolFixture()
    let kinds: [OWLMessageKind] = [
      .jsDialog, .permissionRequest, .fileChooser, .downloadRequest, .authRequest,
      .certificateError, .contextMenu, .colorChooser,
    ]
    for kind in kinds { try? fixture.receive(kind, WireEncoder()) }
    // The context menu needs a MenuParams object, so "{}" fails to decode and is reported.
    #expect(fixture.recorder.requested.count == 7)
    #expect(fixture.webView.lastError != nil)
    for prompt in fixture.recorder.requested {
      #expect(prompt.id == 0)
      _ = prompt.request.isFinished
    }
  }

  @Test func theSamePromptIDTwiceKeepsBoth() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.jsDialog, WireEncoder().u64(.promptID, .max))
    try fixture.receive(.colorChooser, WireEncoder().u64(.promptID, .max))
    #expect(fixture.webView.pendingPrompts.count == 2)
    // A cancel removes both, and reports the first.
    try fixture.receive(.promptCancelled, WireEncoder().u64(.promptID, .max))
    #expect(fixture.webView.pendingPrompts.isEmpty)
    #expect(fixture.recorder.cancelled.first?.1 == "Withdrawn by the host.")
    try fixture.receive(.promptCancelled, WireEncoder().u64(.promptID, 12))
    #expect(fixture.recorder.cancelled.count == 1)
  }

  @Test func answeringTwiceIsReportedAndNotSent() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.jsDialog, WireEncoder().u64(.promptID, 3))
    guard case .dialog(let dialog) = try prompt(fixture) else {
      Issue.record("expected a dialog")
      return
    }
    dialog.accept(text: "a\u{0}b")
    dialog.cancel()
    #expect(fixture.webView.lastError == .promptFinished("prompt 3"))
    #expect(fixture.sent.count == 1)
    #expect(fixture.last(.dialogReply)?.string(.text) == "a\u{0}b")
  }

  @Test func colorAnswersMustBeSevenCharacterHex() throws {
    let fixture = ProtocolFixture()
    for bad in ["", "#", "#12345", "#1234567", "123456#", "#GGGGGG", "#12345\u{0}", "#👩‍👩‍👧‍👦👩‍👩‍👧‍👦"] {
      fixture.recorder.requested.removeAll()
      fixture.sent.removeAll()
      try fixture.receive(.colorChooser, WireEncoder().u64(.promptID, 1))
      guard case .color(let color) = try prompt(fixture) else {
        Issue.record("expected a color prompt")
        return
      }
      color.choose(bad)
      #expect(fixture.webView.lastError?.errorDescription?.contains("#rrggbb") == true)
      #expect(fixture.last(.colorReply)?.bool(.accepted) == false)
      #expect(color.isFinished)
    }
    try fixture.receive(.colorChooser, WireEncoder().u64(.promptID, 2))
    guard case .color(let color) = try prompt(fixture) else {
      Issue.record("expected a color prompt")
      return
    }
    #expect(color.initialColor == "#000000")
    color.choose("#aBc123")
    #expect(fixture.last(.colorReply)?.string(.color) == "#aBc123")
  }

  @Test(
    "A color's digits are ASCII")
  func fullWidthColorDigits() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.colorChooser, WireEncoder().u64(.promptID, 1))
    guard case .color(let color) = try prompt(fixture) else {
      Issue.record("expected a color prompt")
      return
    }
    color.choose("#１２３４５６")
    #expect(fixture.last(.colorReply)?.bool(.accepted) == false)
  }

  @Test func fileChooserRefusesWhatIsNotAFile() throws {
    let fixture = ProtocolFixture()
    let https = try #require(URL(string: "https://a.example/x"))
    for answer in [[], [https], [URL(fileURLWithPath: "/tmp/a"), https]] {
      fixture.sent.removeAll()
      fixture.recorder.requested.removeAll()
      try fixture.receive(.fileChooser, WireEncoder().u64(.promptID, 1))
      guard case .fileChooser(let chooser) = try prompt(fixture) else {
        Issue.record("expected a file chooser")
        return
      }
      chooser.choose(answer)
      #expect(fixture.last(.fileChooserReply)?.bool(.accepted) == false)
      #expect(fixture.webView.lastError != nil)
    }
    try fixture.receive(.fileChooser, WireEncoder().u64(.promptID, 1).string(.acceptTypes, "{}"))
    #expect(fixture.webView.lastError?.errorDescription?.contains("AcceptTypes") == true)
  }

  @Test(
    "An authentication port past Int is refused or kept, never a trap")
  func hugeAuthPort() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.authRequest, WireEncoder().u64(.promptID, 1).u64(.port, .max))
    #expect(fixture.recorder.requested.count == 1)
  }

  @Test func certificateDatesAndCodesOfAnySize() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .certificateError,
      WireEncoder().u64(.promptID, 1).i64(.errorCode, .min).double(.certValidStart, .nan)
        .double(.certValidExpiry, .infinity).bool(.overridable, true))
    guard case .certificateError(let certificate) = try prompt(fixture) else {
      Issue.record("expected a certificate prompt")
      return
    }
    #expect(certificate.errorCode == Int(Int64.min))
    #expect(certificate.validFrom == nil)
    #expect(certificate.validUntil != nil)
    certificate.cancel()
    #expect(fixture.last(.certificateReply)?.bool(.accepted) == false)
  }

  @Test func aCertificateErrorThatCannotBeOverriddenSendsNothing() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .certificateError,
      WireEncoder().u64(.promptID, 1).double(.certValidStart, -1).double(.certValidExpiry, 0))
    guard case .certificateError(let certificate) = try prompt(fixture) else {
      Issue.record("expected a certificate prompt")
      return
    }
    #expect(certificate.validFrom == nil && certificate.validUntil == nil)
    certificate.proceed()
    #expect(fixture.webView.lastError != nil)
    #expect(fixture.last(.certificateReply) == nil)
    #expect(certificate.isFinished)
    certificate.cancel()
    #expect(fixture.webView.pendingPrompts.isEmpty)
  }

  @Test func withoutADelegateEveryPromptIsDeniedAndReported() throws {
    let fixture = ProtocolFixture()
    fixture.webView.uiDelegate = nil
    var events: [WebViewEvent] = []
    fixture.webView.onEvent = { events.append($0) }
    let menu = WireEncoder().u64(.promptID, 6).string(.menuItems, "[]").string(
      .menuParams,
      #"{"linkURL":"","sourceURL":"","pageURL":"","frameURL":"","selectionText":"","isEditable":false}"#
    )
    try fixture.receive(.jsDialog, WireEncoder())
    try fixture.receive(.permissionRequest, WireEncoder())
    try fixture.receive(.fileChooser, WireEncoder())
    try fixture.receive(.downloadRequest, WireEncoder())
    try fixture.receive(.authRequest, WireEncoder())
    try fixture.receive(.certificateError, WireEncoder())
    try fixture.receive(.contextMenu, menu)
    try fixture.receive(.colorChooser, WireEncoder())
    #expect(events.count == 8)
    #expect(fixture.webView.pendingPrompts.isEmpty)
    #expect(
      fixture.sent.map(\.kind) == [
        .dialogReply, .permissionReply, .fileChooserReply, .downloadReply, .authReply,
        .contextMenuReply, .colorReply,
      ])
  }

  @Test func contextMenusTakeNestedAndOddItems() throws {
    let fixture = ProtocolFixture()
    let params =
      #"{"linkURL":"","sourceURL":"","pageURL":"","frameURL":"","selectionText":"","isEditable":true}"#
    let items = #"""
      [{"id":1,"kind":"command","label":"","enabled":true,"checked":false},
       {"id":-9223372036854775808,"kind":"check","label":"c","enabled":false,"checked":true},
       {"id":9223372036854775807,"kind":"radio","label":"r","enabled":true,"checked":false},
       {"id":0,"kind":"separator","label":"","enabled":false,"checked":false},
       {"id":0,"kind":"submenu","label":"s","enabled":true,"checked":false,
        "items":[{"id":2,"kind":"submenu","label":"t","enabled":false,"checked":false}]}]
      """#
    try fixture.receive(
      .contextMenu,
      WireEncoder().u64(.promptID, 1).double(.X, .nan).string(.menuItems, items).string(
        .menuParams, params))
    guard case .contextMenu(let menu) = try prompt(fixture) else {
      Issue.record("expected a context menu")
      return
    }
    #expect(menu.location.x.isNaN)
    let nsMenu = NSMenu(title: "")
    WebContextMenuPresenter.add(menu.items, to: nsMenu, target: NSObject())
    #expect(nsMenu.items.count == 5)
    #expect(nsMenu.items[1].tag == .min)
    #expect(nsMenu.items[1].state == .on)
    #expect(!nsMenu.items[1].isEnabled)
    #expect(nsMenu.items[3].isSeparatorItem)
    #expect(nsMenu.items[4].submenu?.items.first?.submenu != nil)
    menu.select(commandID: .min)
    #expect(fixture.last(.contextMenuReply)?.i64(.commandID) == .min)
    let deep = String(
      repeating: #"{"id":1,"kind":"submenu","label":"","enabled":true,"checked":false,"items":["#,
      count: 5000)
    try? fixture.receive(
      .contextMenu, WireEncoder().string(.menuItems, "[\(deep)").string(.menuParams, params))
    #expect(fixture.webView.lastError?.errorDescription?.contains("MenuItems") == true)
  }

  @Test func popupsFromTheHostWithOddFields() throws {
    let fixture = ProtocolFixture()
    fixture.session.views[999]?.close()
    // No opener: the host is told to close it.
    try fixture.receive(.popupCreated, target: 500, WireEncoder())
    #expect(fixture.last(.viewClose) != nil)
    // A target that already exists is not replaced.
    fixture.sent.removeAll()
    try fixture.receive(
      .popupCreated, target: fixture.webView.id, WireEncoder().u64(.openerID, fixture.webView.id))
    #expect(fixture.recorder.opened.isEmpty)
    try fixture.receive(
      .popupCreated, target: 501,
      WireEncoder().u64(.openerID, fixture.webView.id).double(.width, .nan).double(
        .height, -.infinity
      )
      .string(.URL, "http://[bad"))
    let popup = try #require(fixture.recorder.opened.first)
    #expect(popup.targetURL == nil)
    #expect(popup.requestedSize?.width.isNaN == true)
    #expect(popup.webView.status == .creating)
    #expect(popup.webView.opener === fixture.webView)
    // Without a delegate the popup is closed and reported.
    fixture.webView.uiDelegate = nil
    try fixture.receive(
      .popupCreated, target: 502, WireEncoder().u64(.openerID, fixture.webView.id))
    #expect(fixture.session.views[502] == nil)
    #expect(
      fixture.webView.lastError
        == .featureBlocked(
          feature: "Popup", detail: "No WebViewUIDelegate adopted the popup for a page."))
    try fixture.receive(.popupBlocked, WireEncoder())
    #expect(
      fixture.webView.lastError == .popupBlocked(url: nil, reason: "Blocked by the popup policy."))
  }
}

@MainActor
@Suite("Downloads from a broken host")
struct HostileDownloadTests {
  private func started(_ fixture: ProtocolFixture, id: UInt64 = 7) throws -> WebDownload {
    try fixture.receive(
      .downloadRequest, WireEncoder().u64(.promptID, 1).u64(.downloadID, id).i64(.totalBytes, 100))
    guard case .download(let request)? = fixture.recorder.requested.last else {
      throw WebLayerError.notReady
    }
    return try #require(request.save(to: URL(fileURLWithPath: "/tmp/never-written")))
  }

  @Test func updatesWithOddFields() throws {
    let fixture = ProtocolFixture()
    let download = try started(fixture)
    var changes = 0
    fixture.session.downloads.onChange = { _ in changes += 1 }
    #expect(download.fractionCompleted == 0)
    fixture.session.downloads.update(try WireDecoder([]))
    try fixture.receive(.downloadUpdated, WireEncoder().u64(.downloadID, 999))
    #expect(changes == 0)
    try fixture.receive(
      .downloadUpdated,
      WireEncoder().u64(.downloadID, 7).i64(.receivedBytes, .max).i64(.totalBytes, 1))
    #expect(download.fractionCompleted == 1)
    try fixture.receive(.downloadUpdated, WireEncoder().u64(.downloadID, 7).i64(.totalBytes, -1))
    #expect(download.totalBytes == nil)
    #expect(download.fractionCompleted == nil)
    try fixture.receive(
      .downloadUpdated,
      WireEncoder().u64(.downloadID, UInt64(UInt32.max) + 8).u64(
        .downloadState, OWLDownloadState.complete.rawValue))
    #expect(download.state == .complete)
    #expect(download.fractionCompleted == 1)
    #expect(changes == 3)
    #expect(throws: WebLayerError.self) { try download.cancel() }
    fixture.session.downloads.clearFinished()
    #expect(fixture.session.downloads.items.isEmpty)
  }

  @Test(
    "Progress stays in 0...1")
  func negativeProgress() throws {
    let fixture = ProtocolFixture()
    let download = try started(fixture)
    try fixture.receive(
      .downloadUpdated,
      WireEncoder().u64(.downloadID, 7).i64(.receivedBytes, -50).i64(.totalBytes, 100))
    #expect((download.fractionCompleted ?? 0) >= 0)
  }

  @Test func controlsReachTheHostUntilTheDownloadStops() throws {
    let fixture = ProtocolFixture()
    let download = try started(fixture)
    try download.pause()
    try download.resume()
    try download.cancel()
    #expect(fixture.sent.filter { $0.kind == .downloadControl }.count == 3)
    #expect(fixture.last(.downloadControl)?.u64(.downloadID) == 7)
    download.session = nil
    #expect(throws: WebLayerError.notReady) { try download.pause() }
    download.state = .cancelled
    #expect(throws: WebLayerError.self) { try download.resume() }
  }

  @Test func aDestinationThatIsNotAFileIsRefused() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(.downloadRequest, WireEncoder().u64(.promptID, 1).i64(.totalBytes, .min))
    guard case .download(let request)? = fixture.recorder.requested.last else {
      Issue.record("expected a download")
      return
    }
    #expect(request.totalBytes == nil)
    #expect(request.save(to: try #require(URL(string: "https://a.example/"))) == nil)
    #expect(fixture.last(.downloadReply)?.bool(.accepted) == false)
    #expect(fixture.session.downloads.items.isEmpty)
  }
}
