import Foundation
import OWLProtocol
import Testing

@testable import OmnigentWebLayer

/// A repeatable random source, so a failing payload can be reproduced.
struct SeededGenerator: RandomNumberGenerator {
  var state: UInt64

  mutating func next() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
}

@Suite("Wire payloads a broken host could send")
struct HostileWireTests {
  private func header(tag: UInt16, type: UInt8, length: UInt32) -> [UInt8] {
    [
      UInt8(tag & 0xFF), UInt8(tag >> 8), type, 0, UInt8(length & 0xFF),
      UInt8((length >> 8) & 0xFF), UInt8((length >> 16) & 0xFF), UInt8(length >> 24),
    ]
  }

  @Test func randomBytesDecodeOrThrowButNeverTrap() {
    var generator = SeededGenerator(state: 0x1234_5678_9ABC_DEF1)
    var decoded = 0
    for _ in 0..<3000 {
      let count = Int.random(in: 0...64, using: &generator)
      let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &generator) }
      guard let fields = try? WireDecoder(bytes) else { continue }
      decoded += 1
      _ = fields.u64(.width)
      _ = fields.i64(.errorCode)
      _ = fields.double(.scale)
      _ = fields.bool(.visible)
      _ = fields.string(.URL)
      _ = fields.data(.PNG)
    }
    // Only the empty payload and the rare well-formed ones get through.
    #expect(decoded > 0)
  }

  @Test func aFieldClaimingFourGigabytesIsAnError() {
    let bytes = header(tag: OWLField.URL.rawValue, type: 5, length: .max)
    #expect(throws: WebLayerError.self) { try WireDecoder(bytes) }
    #expect(throws: WebLayerError.self) { try WireDecoder(bytes + [1, 2, 3]) }
  }

  @Test func theLastOfARepeatedFieldWins() throws {
    let fields = try WireDecoder(WireEncoder().u64(.width, 1).u64(.width, 2).bytes)
    #expect(fields.u64(.width) == 2)
    let retyped = try WireDecoder(WireEncoder().u64(.width, 1).string(.width, "x").bytes)
    #expect(retyped.u64(.width) == nil)
    #expect(retyped.string(.width) == "x")
  }

  @Test func scalarsOfTheWrongLengthReadAsMissing() throws {
    let u64Type = OWLFieldType.uInt64.rawValue
    let boolType = OWLFieldType.bool.rawValue
    let doubleType = OWLFieldType.double.rawValue
    let int64Type = OWLFieldType.int64.rawValue
    var bytes: [UInt8] = []
    bytes +=
      header(tag: OWLField.width.rawValue, type: u64Type, length: 7)
      + [UInt8](repeating: 1, count: 7)
    bytes +=
      header(tag: OWLField.scale.rawValue, type: doubleType, length: 9)
      + [UInt8](repeating: 1, count: 9)
    bytes += header(tag: OWLField.errorCode.rawValue, type: int64Type, length: 0)
    bytes += header(tag: OWLField.visible.rawValue, type: boolType, length: 2) + [1, 1]
    bytes += header(tag: OWLField.focused.rawValue, type: boolType, length: 0)
    let fields = try WireDecoder(bytes)
    #expect(fields.u64(.width) == nil)
    #expect(fields.double(.scale) == nil)
    #expect(fields.i64(.errorCode) == nil)
    #expect(!fields.bool(.visible))
    #expect(fields.bool(.visible, missing: true))
    #expect(fields.bool(.focused, missing: true))
  }

  @Test func textThatIsNotUTF8ReadsAsMissing() throws {
    let stringType = OWLFieldType.string.rawValue
    let bytes =
      header(tag: OWLField.title.rawValue, type: stringType, length: 3) + [0xFF, 0xFE, 0xC0]
    #expect(try WireDecoder(bytes).string(.title) == nil)
    #expect(try WireDecoder(WireEncoder().string(.title, "").bytes).string(.title)?.isEmpty == true)
    #expect(
      try WireDecoder(WireEncoder().string(.title, "a\u{0}b").bytes).string(.title) == "a\u{0}b")
  }

  @Test func extremeScalarsRoundTrip() throws {
    let fields = try WireDecoder(
      WireEncoder().u64(.width, .max).i64(.errorCode, .min).double(.scale, .nan)
        .double(.X, -.infinity).double(.Y, .leastNonzeroMagnitude).bytes)
    #expect(fields.u64(.width) == .max)
    #expect(fields.i64(.errorCode) == .min)
    #expect(fields.double(.scale)?.isNaN == true)
    #expect(fields.double(.X) == -.infinity)
    #expect(fields.double(.Y) == .leastNonzeroMagnitude)
  }

  @Test func everyEmptyPayloadReadsAsMissing() throws {
    let fields = try WireDecoder([])
    #expect(fields.u64(.width) == nil)
    #expect(fields.data(.PNG) == nil)
    #expect(fields.string(.URL) == nil)
  }
}

@Suite("DevTools results a broken host could send")
struct HostileScriptValueTests {
  private func evaluate(_ result: String) throws -> WebScriptValue {
    try WebScriptValue.fromEvaluateResult(json: #"{"result":\#(result)}"#)
  }

  @Test func unserializableValues() throws {
    #expect(try evaluate(#"{"unserializableValue":"Infinity"}"#) == .number(.infinity))
    #expect(try evaluate(#"{"unserializableValue":"-Infinity"}"#) == .number(-.infinity))
    #expect(try evaluate(#"{"unserializableValue":"123n"}"#) == .string("123n"))
    guard case .number(let zero) = try evaluate(#"{"unserializableValue":"-0"}"#) else {
      Issue.record("expected a number")
      return
    }
    #expect(zero == 0 && zero.sign == .minus)
  }

  @Test func resultsWithoutAValueNameWhatTheyAre() {
    #expect(throws: WebLayerError.unsupportedScriptResult("Window")) {
      try evaluate(#"{"type":"object","className":"Window"}"#)
    }
    #expect(throws: WebLayerError.unsupportedScriptResult("function")) {
      try evaluate(#"{"type":"function"}"#)
    }
    #expect(throws: WebLayerError.unsupportedScriptResult("unknown")) { try evaluate("{}") }
  }

  @Test func exceptionsFallBackToTheirText() {
    #expect(throws: WebLayerError.scriptFailed("Uncaught")) {
      try WebScriptValue.fromEvaluateResult(json: #"{"exceptionDetails":{"text":"Uncaught"}}"#)
    }
    #expect(throws: WebLayerError.scriptFailed("Uncaught exception")) {
      try WebScriptValue.fromEvaluateResult(json: #"{"exceptionDetails":{}}"#)
    }
    #expect(throws: WebLayerError.self) {
      try WebScriptValue.fromEvaluateResult(json: #"{"result":7}"#)
    }
  }

  @Test(
    "Text that isn't a result object is an error",
    arguments: ["", "1", "null", "[]", "\"text\"", "{", "\u{0}"])
  func notAnObject(json: String) {
    #expect(throws: WebLayerError.self) { try WebScriptValue.fromEvaluateResult(json: json) }
  }

  /// Parsers either refuse these or return something; neither may trap.
  @Test(
    "Numbers and text at the edge of what JSON holds",
    arguments: [
      "1e400", "-1e400", "1e-400", "18446744073709551616", "-9223372036854775809",
      "123456789012345678901234567890.5", "\"\\ud800\"", "\"\\u0000\"", "true", "false", "0",
      "{\"\":{\"\":[null]}}",
    ])
  func edgeValues(value: String) {
    _ = try? evaluate(#"{"value":\#(value)}"#)
  }

  @Test func deepNestingIsRefusedOrParsed() {
    let depth = 100_000
    let nested = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
    #expect(throws: WebLayerError.self) { try evaluate(#"{"value":\#(nested)}"#) }
  }

  @Test func valuesThatAreNotJSONAreReported() {
    #expect(throws: WebLayerError.unsupportedScriptResult("__NSTaggedDate")) {
      do {
        _ = try WebScriptValue(json: Date(timeIntervalSinceReferenceDate: 0))
      } catch WebLayerError.unsupportedScriptResult {
        throw WebLayerError.unsupportedScriptResult("__NSTaggedDate")
      }
    }
    #expect(WebScriptValue.string("x").stringValue == "x")
    #expect(WebScriptValue.null.stringValue == nil)
  }

  @Test func failureMessagesKeepWhateverTheyCannotParse() {
    #expect(DevToolsJSON.failureMessage("").isEmpty)
    #expect(DevToolsJSON.failureMessage("[1]") == "[1]")
    #expect(DevToolsJSON.failureMessage(#"{"message":7}"#) == #"{"message":7}"#)
    #expect(DevToolsJSON.failureMessage(#"{"message":""}"#).isEmpty)
  }
}

@Suite("Error text and classification")
struct WebLayerErrorTests {
  private static let url = URL(string: "https://example.com/")

  nonisolated private static let everyError: [WebLayerError] = [
    .hostNotBundled(path: ""), .launchFailed(""), .channelFailed(""), .handshakeFailed(""),
    .protocolMismatch(host: "", client: ""), .hostInitializationFailed(""),
    .hostTimedOut(phase: "", seconds: 0), .hostExited(status: .min, reason: ""),
    .hostUnresponsive(seconds: -1), .hostError(code: .max, message: ""), .notReady, .viewClosed,
    .navigationFailed(url: nil, code: .min, message: ""), .navigationCancelled(url: nil),
    .rendererTerminated(""), .scriptFailed(""), .unsupportedScriptResult(""),
    .devToolsFailed(method: "", message: ""), .snapshotFailed(""), .downloadBlocked(url: nil),
    .featureBlocked(feature: "", detail: ""), .renderingUnavailable(""), .invalidArgument(""),
    .navigationBlocked(url: nil, reason: ""), .popupBlocked(url: nil, reason: ""),
    .promptFinished(""),
  ]

  @Test("Every error has text", arguments: everyError)
  func everyErrorHasText(error: WebLayerError) {
    #expect(error.errorDescription?.isEmpty == false)
  }

  @Test func onlyHostFailuresAreRecoverableByRestart() {
    let recoverable = Self.everyError.filter(\.isRecoverableByRestart)
    #expect(recoverable.count == 5)
    #expect(WebLayerError.hostExited(status: 1, reason: "").isRecoverableByRestart)
    #expect(!WebLayerError.notReady.isRecoverableByRestart)
    #expect(Self.everyError.filter(\.isCancellation) == [.navigationCancelled(url: nil)])
  }

  @Test func urlsAppearInTheText() {
    let text = WebLayerError.navigationBlocked(url: Self.url, reason: "r").localizedDescription
    #expect(text.contains("https://example.com/"))
  }

  @Test(
    "A timeout of no real length still describes itself",
    arguments: [Double.nan, .infinity, -.infinity, 1e300, Double(Int64.max)])
  func timeoutsOfNoRealLength(seconds: Double) {
    #expect(
      WebLayerError.hostTimedOut(phase: "x", seconds: seconds).errorDescription?.isEmpty == false)
  }

  @Test(
    "A hang of no real length still describes itself",
    arguments: [Double.nan, .infinity, 1e300])
  func hangsOfNoRealLength(seconds: Double) {
    #expect(WebLayerError.hostUnresponsive(seconds: seconds).errorDescription?.isEmpty == false)
  }
}
