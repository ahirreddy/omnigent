import AppKit
import Foundation
import OWLProtocol
import OmnigentInput
import Testing

@testable import OmnigentWebLayer

@Suite("Wire values outside their enums")
struct WireEnumTests {
  private static let outOfRange: [UInt64] = [99, .max]

  @Test func unknownValuesPickTheSafeDefault() {
    for value in Self.outOfRange {
      #expect(WebFileChooserMode(wire: value) == .open)
      #expect(WebDownloadState(wire: value) == .inProgress)
      #expect(WebDialogKind(wire: value) == .alert)
      #expect(WebPopupDisposition(wire: value) == .foregroundTab)
      #expect(WebCursor(wire: value) == .pointer)
      #expect(RenderMode(wireValue: value) == .remoteLayer)
    }
  }

  @Test func knownValuesMap() {
    #expect(WebFileChooserMode(wire: OWLFileChooserMode.openMultiple.rawValue) == .openMultiple)
    #expect(WebFileChooserMode(wire: OWLFileChooserMode.openFolder.rawValue) == .openFolder)
    #expect(WebFileChooserMode(wire: OWLFileChooserMode.save.rawValue) == .save)
    #expect(WebDownloadState(wire: OWLDownloadState.paused.rawValue) == .paused)
    #expect(WebDownloadState(wire: OWLDownloadState.complete.rawValue).isFinal)
    #expect(WebDownloadState(wire: OWLDownloadState.cancelled.rawValue).isFinal)
    #expect(WebDownloadState(wire: OWLDownloadState.interrupted.rawValue).isFinal)
    #expect(!WebDownloadState.paused.isFinal)
    #expect(WebDialogKind(wire: OWLDialogKind.confirm.rawValue) == .confirm)
    #expect(WebDialogKind(wire: OWLDialogKind.prompt.rawValue) == .prompt)
    #expect(WebDialogKind(wire: OWLDialogKind.beforeUnload.rawValue) == .beforeUnload)
    #expect(WebPopupDisposition(wire: OWLDisposition.currentTab.rawValue) == .currentTab)
    #expect(WebPopupDisposition(wire: OWLDisposition.backgroundTab.rawValue) == .backgroundTab)
    #expect(WebPopupDisposition(wire: OWLDisposition.popup.rawValue) == .popup)
    #expect(WebPopupDisposition(wire: OWLDisposition.window.rawValue) == .window)
    #expect(WebCursor(wire: OWLCursor.hand.rawValue) == .hand)
    #expect(WebCursor(wire: OWLCursor.none.rawValue) == .none)
    #expect(RenderMode(wireValue: OWLRenderMode.ioSurface.rawValue) == .ioSurface)
    #expect(RenderMode.ioSurface.wireValue == .ioSurface)
    #expect(RenderMode.remoteLayer.wireValue == .remoteLayer)
    #expect(WebPopupPolicy.allow.wire == .allow)
    #expect(WebPopupPolicy.block.wire == .block)
    #expect(WebPopupPolicy.requireUserGesture.wire == .requireGesture)
  }
}

@Suite("Plain values")
struct PlainValueTests {
  @Test func frameStatisticsKeepTheLastSixHundredFrames() {
    var statistics = FrameStatistics()
    for index in 0..<1000 { statistics.record(latency: Double(index), copy: .nan) }
    #expect(statistics.framesPresented == 1000)
    #expect(statistics.latencyMicroseconds.count == 600)
    #expect(statistics.copyMicroseconds.count == 600)
    #expect(statistics.latencyMicroseconds.first == 400)
  }

  @Test func findResultsWithOddCounts() {
    #expect(!FindResult(matchCount: 0, activeMatch: nil).matchFound)
    #expect(!FindResult(matchCount: .min, activeMatch: .max).matchFound)
    #expect(FindResult(matchCount: .max, activeMatch: nil).matchFound)
  }

  @Test func storageKeysAreFixedWidthHexForAnyIdentifier() {
    for identifier in ["", "/../..", "\u{0}", String(repeating: "x", count: 100_000), "👩‍👩‍👧‍👦"] {
      let key = Profile.storageKey(for: identifier)
      #expect(key.count == 32)
      #expect(key.allSatisfy { "0123456789abcdef".contains($0) })
    }
    #expect(UInt8(0).hexByte == "00")
    #expect(UInt8(255).hexByte == "ff")
  }

  @Test func sessionStateReportsItsError() {
    #expect(SessionState.failed(.notReady).error == .notReady)
    #expect(SessionState.crashed(.viewClosed).error == .viewClosed)
    #expect(SessionState.idle.error == nil)
    #expect(SessionState.launching.error == nil)
    #expect(SessionState.stopped.error == nil)
  }

  @Test func configurationDerivesPathsFromTheBundle() {
    let standard = SessionConfiguration.standard(bundle: .main)
    #expect(standard.hostAppURL.path.hasSuffix("Contents/Helpers/Omnigent Web Host.app"))
    #expect(standard.rootCacheURL.path.hasSuffix("/Chromium"))
    #expect(standard.keychainServiceName?.hasSuffix("Browser Safe Storage") == true)
    #expect(standard.hostExecutableURL.path.hasSuffix("Contents/MacOS/Omnigent Web Host"))
    #expect(RenderMode.allCases.count == 2)
  }

  @Test func helloAckOmitsWhatIsUnset() throws {
    let root = FileManager.default.temporaryDirectory
    let url = URL(fileURLWithPath: "/nonexistent")
    let bare = Session(configuration: SessionConfiguration(hostAppURL: url, rootCacheURL: root))
    let bareAck = try WireDecoder(bare.helloAck().bytes)
    #expect(bareAck.string(.locale) == nil)
    #expect(bareAck.string(.keychainService) == nil)

    var full = SessionConfiguration(
      hostAppURL: url, rootCacheURL: root, remoteDebuggingPort: .min, useMockKeychain: true,
      keychainServiceName: "k", locale: "en-US", disableSandbox: true)
    full.renderMode = .ioSurface
    let fullAck = try WireDecoder(Session(configuration: full).helloAck().bytes)
    #expect(fullAck.u64(.remoteDebuggingPort) == 0)
    #expect(fullAck.string(.locale) == "en-US")
    #expect(fullAck.string(.keychainService) == "k")
    #expect(fullAck.bool(.useMockKeychain))
    #expect(fullAck.bool(.disableSandbox))
  }

  @Test func navigationHistoryClampsAndDropsWhatDoesNotParse() throws {
    let empty = try WebNavigationHistory.parse(json: #"{"index":99,"entries":[]}"#)
    #expect(empty.entries.isEmpty && empty.currentIndex == 0)
    #expect(WebNavigationHistory(entries: [], currentIndex: .min).currentIndex == 0)

    let entries =
      #"[{"url":"https://a.example/"},{"url":"http://[bad"},{"url":"https://c.example/","title":"C"}]"#
    let past = try WebNavigationHistory.parse(
      json: #"{"index":9223372036854775807,"entries":\#(entries)}"#)
    #expect(past.entries.count == 2)
    #expect(past.currentIndex == 1)
    #expect(past.entries[1].title == "C")
    let before = try WebNavigationHistory.parse(json: #"{"index":-5,"entries":\#(entries)}"#)
    #expect(before.currentIndex == 0)
    // The current entry was dropped: the one before it stands in.
    let dropped = try WebNavigationHistory.parse(json: #"{"index":1,"entries":\#(entries)}"#)
    #expect(dropped.currentIndex == 0)

    for json in ["", "[]", #"{"index":1e300,"entries":[]}"#, #"{"index":0}"#] {
      #expect(throws: WebLayerError.self) { try WebNavigationHistory.parse(json: json) }
    }
    let onlyBad = try WebNavigationHistory.parse(
      json: #"{"index":0,"entries":[{"url":"http://[bad"}]}"#)
    #expect(onlyBad.entries.isEmpty)
  }

  @Test func dragDataDecodesEveryKeyAsOptional() throws {
    let empty = try WireJSON.decode(WebDragData.self, "{}", field: "DragData")
    #expect(empty == WebDragData())
    let full = WebDragData(
      text: "t", html: "h", url: "u", urlTitle: "ut", fileName: "f", paths: ["/a", ""])
    let text = WireJSON.encode(full)
    #expect(try WireJSON.decode(WebDragData.self, text, field: "DragData") == full)
    #expect(throws: WebLayerError.self) {
      try WireJSON.decode(WebDragData.self, #"{"paths":7}"#, field: "DragData")
    }
  }

  @Test func dragOperationsMapBothWays() {
    let every: WebDragOperations = [.copy, .link, .generic, .move, .delete]
    #expect(WebDragOperations(every.dragOperation) == every)
    #expect(WebDragOperations([]).dragOperation.isEmpty)
    // Bits outside Chromium's mask have no AppKit operation.
    #expect(WebDragOperations(rawValue: 1 << 40).dragOperation.isEmpty)
    #expect(WebDragOperations(.every).contains(.copy))
  }

  @Test func navigationRulesEncodeAsSortedJSON() {
    let json = WebNavigationRules(allow: ["a.example"]).json
    #expect(json.contains(#""allow":["a.example"]"#))
    #expect(json.contains(#""schemes":["http","https"]"#))
  }

  @Test func agentModifiersMapToWireBits() {
    let every: AgentModifiers = [.shift, .control, .option, .command]
    #expect(every.wire == [.shift, .control, .alt, .command])
    #expect(AgentModifiers([]).wire.isEmpty)
    #expect(AgentModifiers(rawValue: .min).wire.isEmpty)
    #expect(AgentMouseButton.left.wire == .left)
    #expect(AgentMouseButton.middle.wire == .middle)
    #expect(AgentMouseButton.right.wire == .right)
  }
}

@MainActor
@Suite("Agent keys")
struct AgentKeyTests {
  private static let namedKeys: [AgentKey] = [
    .enter, .tab, .escape, .backspace, .delete, .arrowLeft, .arrowRight, .arrowUp, .arrowDown,
    .home, .end, .pageUp, .pageDown,
  ]

  @Test func namedKeysHaveDistinctCodesAndUnits() {
    #expect(Set(Self.namedKeys.map(\.nativeKeyCode)).count == Self.namedKeys.count)
    #expect(Set(Self.namedKeys.map(\.characterUnit)).count == Self.namedKeys.count)
    for key in Self.namedKeys {
      #expect(key.keyInputs(modifiers: [.command]).map(\.kind) == [.rawKeyDown, .keyUp])
    }
  }

  @Test(
    "Any character presses without trapping",
    arguments: [
      "a", "A", "İ", "ß", "ﬃ", "\r\n", "\u{0}", "😀", "👩‍👩‍👧‍👦", "🇺🇸", "e\u{0301}\u{0327}", "\u{FEFF}",
      "\u{202E}", "\u{E000}", "Σ", "ǅ",
    ] as [Character])
  func anyCharacter(character: Character) {
    let key = AgentKey.character(character)
    #expect(key.keyInputs(modifiers: []).first?.kind == .rawKeyDown)
    #expect(key.keyInputs(modifiers: []).last?.kind == .keyUp)
    _ = key.nativeKeyCode
    _ = AgentKey.keyCode(for: character)
  }

  @Test func uppercaseLettersShareTheirKey() {
    #expect(AgentKey.keyCode(for: "K") == 40)
    #expect(AgentKey.keyCode(for: "é") == nil)
    #expect(AgentKey.character("é").nativeKeyCode == 0)
  }

  /// `keyCode(for:)` forms a `Character` from a lowercased string, which traps on two graphemes.
  @Test func everyScalarLowercasesToOneGrapheme() {
    var failures: [UInt32] = []
    for value in UInt32(0)...0x10FFFF {
      guard let scalar = Unicode.Scalar(value) else { continue }
      if Character(scalar).lowercased().count != 1 { failures.append(value) }
    }
    #expect(failures.isEmpty)
  }

  @Test func unhandledKeysSurviveOddCharacters() {
    for character in [UInt16(0), 0xD800, 0xDFFF, 0xFFFF] {
      let key = UnhandledKey(
        keyCode: .max, modifiers: InputModifiers(rawValue: .max), character: character,
        unmodifiedCharacter: character)
      let event = InputTranslator.unhandledKeyEvent(key, template: nil, windowNumber: .min)
      #expect(event?.type == .keyDown)
    }
  }
}
