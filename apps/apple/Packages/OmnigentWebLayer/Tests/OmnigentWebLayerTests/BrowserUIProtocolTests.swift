import AppKit
import Foundation
import OWLProtocol
import OmnigentViewTesting
import Testing

@testable import OmnigentWebLayer

/// A view in a session that records what it would send to a 1.1 host.
@MainActor
final class ProtocolFixture {
  let session: Session
  let webView: WebView
  let recorder = RecordingUIDelegate()
  var sent: [SentMessage] = []

  struct SentMessage {
    let kind: OWLMessageKind
    let target: UInt64
    let fields: WireDecoder
  }

  init(
    configuration: SessionConfiguration = SessionConfiguration(
      hostAppURL: URL(fileURLWithPath: "/nonexistent/Omnigent Web Host.app"),
      rootCacheURL: FileManager.default.temporaryDirectory)
  ) {
    SystemSideEffects.install()
    session = Session(configuration: configuration)
    webView = session.profile(identifier: "tests", persistence: .ephemeral).makeWebView()
    webView.status = .live
    webView.uiDelegate = recorder
    session.hostMinor = UInt64(OWL_PROTOCOL_MINOR)
    session.state = .ready(
      HostInfo(
        pid: 1, cefVersion: "test", chromiumVersion: "test", protocolVersion: "1.1",
        renderMode: .ioSurface, spawnDuration: .zero, helloDuration: .zero, readyDuration: .zero,
        hostInitMilliseconds: 0))
    session.outgoingTap = { [weak self] kind, target, fields in
      self?.sent.append(SentMessage(kind: kind, target: target, fields: fields))
    }
  }

  /// Delivers a host message to the view (or the session for session-level kinds).
  func receive(_ kind: OWLMessageKind, target: UInt64? = nil, _ fields: WireEncoder) throws {
    let message = IncomingMessage(
      kindValue: kind.rawValue, request: 0, target: target ?? webView.id,
      protocolMajor: UInt16(OWL_PROTOCOL_MAJOR), fields: try WireDecoder(fields.bytes), port: nil)
    session.handle(message)
  }

  func last(_ kind: OWLMessageKind) -> WireDecoder? {
    sent.last { $0.kind == kind }?.fields
  }
}

@MainActor
final class RecordingUIDelegate: WebViewUIDelegate {
  var requested: [WebPrompt] = []
  var cancelled: [(WebPrompt, String)] = []
  var opened: [WebPopup] = []
  var blocked: [WebBlockedPopup] = []

  func webView(_ webView: WebView, didRequest prompt: WebPrompt) { requested.append(prompt) }
  func webView(_ webView: WebView, didCancel prompt: WebPrompt, reason: String) {
    cancelled.append((prompt, reason))
  }
  func webView(_ webView: WebView, didOpen popup: WebPopup) { opened.append(popup) }
  func webView(_ webView: WebView, didBlock popup: WebBlockedPopup) { blocked.append(popup) }
}

@MainActor
@Suite("Protocol 1.1 schema")
struct ProtocolSchemaTests {
  @Test func versionAndNumberingAreStable() {
    #expect(OWL_PROTOCOL_MAJOR == 1)
    #expect(OWL_PROTOCOL_MINOR == 3)
    #expect(OWL_PROTOCOL_MINOR_PROMPTS == 1)
    // Kinds and tags are never renumbered; these pin the 1.1 ranges.
    #expect(OWLMessageKind.setPopupPolicy.rawValue == 81)
    #expect(OWLMessageKind.colorReply.rawValue == 100)
    #expect(OWLMessageKind.jsDialog.rawValue == 110)
    #expect(OWLMessageKind.textSelectionChanged.rawValue == 126)
    #expect(OWLField.promptID.rawValue == 74)
    #expect(OWLField.agentInput.rawValue == 124)
    #expect(OWLPermission.other.rawValue == 1 << 30)
  }

  @Test func helloAckAdvertisesTheClientMinor() throws {
    let fixture = ProtocolFixture()
    let ack = try WireDecoder(fixture.session.helloAck().bytes)
    #expect(ack.u64(.protocolMinor) == UInt64(OWL_PROTOCOL_MINOR))
  }

  @Test func browserUIIsOnlyUsedWithA11Host() {
    let fixture = ProtocolFixture()
    #expect(fixture.session.supportsBrowserUI)
    fixture.session.hostMinor = 0
    #expect(!fixture.session.supportsBrowserUI)
    fixture.webView.renderer.commitText("x", replacementRange: nil)
    #expect(fixture.sent.isEmpty)
  }

  @Test func viewCreateCarriesPoliciesForTheFirstNavigation() throws {
    let fixture = ProtocolFixture()
    fixture.webView.status = .waitingForHost
    fixture.webView.popupPolicy = .block
    fixture.webView.navigationRules = WebNavigationRules(
      allow: ["example.com"], allowLoopback: true)
    fixture.webView.hostReady()
    let create = try #require(fixture.last(.viewCreate))
    #expect(create.u64(.popupPolicy) == OWLPopupPolicy.block.rawValue)
    let rules = try JSONDecoder().decode(
      WebNavigationRules.self, from: Data(try #require(create.string(.rules)).utf8))
    #expect(rules.allow == ["example.com"])
    #expect(rules.schemes == ["http", "https"])
    #expect(rules.blockPrivateAddresses && rules.allowLoopback)
  }
}

@MainActor
@Suite("Protocol 1.1 prompts")
struct PromptProtocolTests {
  @Test func dialogRoundTrip() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .jsDialog,
      WireEncoder().u64(.promptID, 7).u64(.dialogKind, OWLDialogKind.prompt.rawValue)
        .string(.origin, "https://example.com").string(.message, "Name?")
        .string(.defaultText, "owl"))
    guard case .dialog(let dialog)? = fixture.recorder.requested.first else {
      Issue.record("no dialog")
      return
    }
    #expect(dialog.kind == .prompt && dialog.message == "Name?" && dialog.defaultText == "owl")
    #expect(fixture.webView.pendingPrompts.count == 1)
    dialog.accept(text: "answer")
    let reply = try #require(fixture.last(.dialogReply))
    #expect(reply.u64(.promptID) == 7 && reply.bool(.accepted) && reply.string(.text) == "answer")
    #expect(fixture.webView.pendingPrompts.isEmpty)
    dialog.cancel()
    #expect(fixture.sent.count == 1)
    #expect(fixture.webView.lastError == .promptFinished("prompt 7"))
  }

  @Test func permissionDecisionsCarryTheGrantedBits() throws {
    let fixture = ProtocolFixture()
    let bits = OWLPermission.camera.rawValue | OWLPermission.microphone.rawValue
    try fixture.receive(
      .permissionRequest,
      WireEncoder().u64(.promptID, 3).string(.origin, "https://meet.example").u64(
        .permissions, bits))
    guard case .permission(let request)? = fixture.recorder.requested.first else {
      Issue.record("no permission prompt")
      return
    }
    #expect(request.permissions == [.camera, .microphone])
    request.allow()
    let reply = try #require(fixture.last(.permissionReply))
    #expect(reply.u64(.permissionResult) == OWLPermissionResult.allow.rawValue)
    #expect(reply.u64(.permissions) == bits)
  }

  @Test func fileChooserParsesAcceptTypesAndSendsPaths() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .fileChooser,
      WireEncoder().u64(.promptID, 4).u64(
        .fileChooserMode, OWLFileChooserMode.openMultiple.rawValue
      )
      .string(.acceptTypes, #"[{"filter":"image/*","extensions":["png","jpg"],"description":""}]"#))
    guard case .fileChooser(let chooser)? = fixture.recorder.requested.first else {
      Issue.record("no chooser")
      return
    }
    #expect(chooser.mode == .openMultiple)
    #expect(chooser.acceptTypes.first?.extensions == ["png", "jpg"])
    chooser.choose([URL(fileURLWithPath: "/tmp/a b.png")])
    let reply = try #require(fixture.last(.fileChooserReply))
    #expect(reply.bool(.accepted) && reply.string(.paths) == #"["/tmp/a b.png"]"#)
  }

  @Test func malformedStructuredFieldsAreReported() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .fileChooser, WireEncoder().u64(.promptID, 5).string(.acceptTypes, "not json"))
    #expect(fixture.recorder.requested.isEmpty)
    guard case .channelFailed(let message)? = fixture.webView.lastError else {
      Issue.record("expected channelFailed, got \(String(describing: fixture.webView.lastError))")
      return
    }
    #expect(message.contains("AcceptTypes"))
  }

  @Test func downloadsAreTrackedAfterSaving() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .downloadRequest,
      WireEncoder().u64(.promptID, 9).u64(.downloadID, 42).string(.URL, "https://x.test/f.zip")
        .string(.suggestedName, "f.zip").i64(.totalBytes, 100))
    guard case .download(let request)? = fixture.recorder.requested.first else {
      Issue.record("no download")
      return
    }
    let download = try #require(request.save(to: URL(fileURLWithPath: "/tmp/f.zip")))
    #expect(fixture.last(.downloadReply)?.string(.path) == "/tmp/f.zip")
    try fixture.receive(
      .downloadUpdated,
      WireEncoder().u64(.downloadID, 42).i64(.receivedBytes, 50).i64(.totalBytes, 100)
        .u64(.downloadState, OWLDownloadState.inProgress.rawValue))
    #expect(download.fractionCompleted == 0.5)
    try download.cancel()
    let control = try #require(fixture.last(.downloadControl))
    #expect(control.u64(.downloadCommand) == OWLDownloadCommand.cancel.rawValue)
    try fixture.receive(
      .downloadUpdated,
      WireEncoder().u64(.downloadID, 42).u64(.downloadState, OWLDownloadState.complete.rawValue))
    #expect(download.state == .complete)
    #expect(throws: WebLayerError.self) { try download.cancel() }
  }

  @Test func authAndCertificateReplies() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .authRequest,
      WireEncoder().u64(.promptID, 11).string(.host, "intranet").u64(.port, 443)
        .string(.realm, "Corp").string(.scheme, "basic").bool(.isProxy, false))
    try fixture.receive(
      .certificateError,
      WireEncoder().u64(.promptID, 0).string(.URL, "https://hsts.test/").i64(.errorCode, -202)
        .bool(.overridable, false))
    guard case .authentication(let auth)? = fixture.recorder.requested.first,
      case .certificateError(let certificate)? = fixture.recorder.requested.last
    else {
      Issue.record("missing prompts")
      return
    }
    #expect(auth.host == "intranet" && auth.port == 443 && auth.realm == "Corp")
    auth.respond(username: "u", password: "p")
    let reply = try #require(fixture.last(.authReply))
    #expect(reply.string(.username) == "u" && reply.string(.password) == "p")
    certificate.proceed()  // Not overridable: no proceed is sent.
    #expect(fixture.last(.certificateReply) == nil)
    #expect(certificate.isFinished)
    #expect(fixture.webView.pendingPrompts.isEmpty)
  }

  @Test func withdrawnPromptsAreDismissedAndNotAnswered() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .jsDialog, WireEncoder().u64(.promptID, 2).u64(.dialogKind, OWLDialogKind.alert.rawValue))
    try fixture.receive(.promptCancelled, WireEncoder().u64(.promptID, 2).string(.reason, "nav"))
    #expect(fixture.recorder.cancelled.first?.1 == "nav")
    #expect(fixture.webView.pendingPrompts.isEmpty)
    guard case .dialog(let dialog)? = fixture.recorder.requested.first else { return }
    #expect(dialog.cancellationReason == "nav")
    dialog.accept()
    #expect(fixture.last(.dialogReply) == nil)
  }

  @Test func withoutADelegatePromptsAreDeniedAndReported() throws {
    let fixture = ProtocolFixture()
    fixture.webView.uiDelegate = nil
    var events: [WebViewEvent] = []
    fixture.webView.onEvent = { events.append($0) }
    try fixture.receive(
      .permissionRequest, WireEncoder().u64(.promptID, 1).u64(.permissions, 1))
    #expect(
      fixture.last(.permissionReply)?.u64(.permissionResult) == OWLPermissionResult.deny.rawValue)
    #expect(events.contains { if case .featureBlocked = $0 { true } else { false } })
  }

  @Test func contextMenuModelAndReplies() throws {
    let fixture = ProtocolFixture()
    let items = #"""
      [{"id":100,"kind":"command","label":"Back","enabled":false,"checked":false},
       {"id":0,"kind":"separator","label":"","enabled":true,"checked":false},
       {"id":5,"kind":"submenu","label":"More","enabled":true,"checked":false,
        "items":[{"id":110,"kind":"check","label":"Spell","enabled":true,"checked":true}]}]
      """#
    let params = #"""
      {"x":10,"y":20,"linkURL":"https://l.test/","sourceURL":"","pageURL":"https://p.test/",
       "frameURL":"","selectionText":"","isEditable":false,"mediaType":0,"editFlags":0}
      """#
    try fixture.receive(
      .contextMenu,
      WireEncoder().u64(.promptID, 6).double(.X, 10).double(.Y, 20).string(.menuItems, items)
        .string(.menuParams, params))
    guard case .contextMenu(let menu)? = fixture.recorder.requested.first else {
      Issue.record("no menu")
      return
    }
    #expect(menu.location == CGPoint(x: 10, y: 20) && menu.context.linkURL == "https://l.test/")
    let nsMenu = NSMenu()
    WebContextMenuPresenter.add(menu.items, to: nsMenu, target: NSObject())
    #expect(nsMenu.items.map(\.title) == ["Back", "", "More"])
    #expect(!nsMenu.items[0].isEnabled && nsMenu.items[0].tag == 100)
    #expect(nsMenu.items[2].submenu?.items.first?.state == .on)
    menu.select(commandID: 110)
    #expect(fixture.last(.contextMenuReply)?.i64(.commandID) == 110)
  }
}

@MainActor
@Suite("Protocol 1.1 popups, rules and input")
struct PopupAndInputProtocolTests {
  @Test func hostCreatedPopupsAreAdoptedWithTheirOpener() throws {
    let fixture = ProtocolFixture()
    let popupID: UInt64 = 1 << 48
    try fixture.receive(
      .popupCreated, target: popupID,
      WireEncoder().u64(.openerID, fixture.webView.id).string(.URL, "https://child.test/")
        .u64(.disposition, OWLDisposition.popup.rawValue).bool(.userGesture, true)
        .double(.width, 400).double(.height, 300))
    let popup = try #require(fixture.recorder.opened.first)
    #expect(popup.webView.id == popupID && popup.opener === fixture.webView)
    #expect(popup.disposition == .popup && popup.requestedSize == CGSize(width: 400, height: 300))
    #expect(fixture.session.views[popupID] === popup.webView)
    try fixture.receive(
      .popupCreated, target: popupID + 1, WireEncoder().u64(.openerID, 999))
    #expect(fixture.sent.last?.kind == .viewClose && fixture.sent.last?.target == popupID + 1)
  }

  @Test func blockedPopupsAndNavigationsAreReported() throws {
    let fixture = ProtocolFixture()
    try fixture.receive(
      .popupBlocked,
      WireEncoder().string(.URL, "https://ads.test/").u64(.disposition, 2).bool(.userGesture, false)
        .string(.reason, "no gesture"))
    #expect(fixture.recorder.blocked.first?.reason == "no gesture")
    try fixture.receive(
      .navigationBlocked, WireEncoder().string(.URL, "http://10.0.0.1/").string(.reason, "private"))
    try fixture.receive(
      .loadError, WireEncoder().i64(.errorCode, -3).string(.URL, "http://10.0.0.1/"))
    guard case .navigationBlocked(_, let reason)? = fixture.webView.lastError else {
      Issue.record("the abort replaced the reason")
      return
    }
    #expect(reason == "private")
  }

  @Test func imeAndAgentTextEncodeRanges() throws {
    let fixture = ProtocolFixture()
    fixture.webView.renderer.setComposition(
      "日本", selectedRange: NSRange(location: 2, length: 0),
      replacementRange: NSRange(location: 1, length: 3))
    let composition = try #require(fixture.last(.imeSetComposition))
    #expect(composition.string(.text) == "日本")
    #expect(composition.i64(.rangeStart) == 2 && composition.i64(.rangeEnd) == 2)
    #expect(composition.i64(.replaceStart) == 1 && composition.i64(.replaceEnd) == 4)
    try fixture.webView.renderer.agentInsertText("typed")
    let commit = try #require(fixture.last(.imeCommitText))
    #expect(commit.bool(.agentInput) && commit.string(.text) == "typed")
    #expect(commit.i64(.replaceStart) == nil)
    try fixture.receive(
      .imeCompositionChanged,
      WireEncoder().i64(.rangeStart, 0).i64(.rangeEnd, 2).string(.rects, "[[1,2,3,4],[5,6,7,8]]"))
    #expect(
      fixture.webView.compositionCharacterRects.last == CGRect(x: 5, y: 6, width: 7, height: 8))
  }

  @Test func dragDataCrossesAsJSON() throws {
    let fixture = ProtocolFixture()
    fixture.webView.renderer.dragEntered(
      WebDragData(text: "hi", paths: ["/tmp/a"]), at: CGPoint(x: 3, y: 4),
      operations: [.copy, .move])
    let enter = try #require(fixture.last(.dragEnter))
    #expect(enter.u64(.dragOperations) == WebDragOperations([.copy, .move]).rawValue)
    let data = try JSONDecoder().decode(
      WebDragData.self, from: Data(try #require(enter.string(.dragData)).utf8))
    #expect(data == WebDragData(text: "hi", paths: ["/tmp/a"]))
    var started: WebDragStart?
    fixture.webView.onStartDrag = { started = $0 }
    try fixture.receive(
      .startDrag,
      WireEncoder().u64(.dragOperations, 1).double(.X, 9).double(.Y, 8)
        .string(.dragData, #"{"url":"https://l.test/","urlTitle":"L"}"#))
    #expect(started?.data.url == "https://l.test/" && started?.location == CGPoint(x: 9, y: 8))
    #expect(WebDragOperations(NSDragOperation([.copy, .link])) == [.copy, .link])
  }
}
