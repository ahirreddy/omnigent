import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import UniformTypeIdentifiers

/// What the composer reads from the core's usage section: how full the context is, and the
/// model the session has been running on.
extension ComposerAdapter {
  /// How full the context window is, from the core's usage section; `nil` until both the
  /// tokens in context and the window are reported.
  static func contextFraction(_ sections: [OmnigentCoreFFI.EventSection]) -> Double? {
    guard let tokens = contextTokens(sections) else { return nil }
    return min(1, max(0, Double(tokens.used) / Double(tokens.window)))
  }

  /// The tokens in context and the window, from the core's usage section.
  static func contextTokens(_ sections: [OmnigentCoreFFI.EventSection]) -> ContextTokens? {
    guard let usage = sections.first(where: { $0.id == "usage" }) else { return nil }
    func value(_ id: String) -> Double? {
      usage.details.first { $0.id == id }.flatMap { Double($0.text) }
    }
    guard let tokens = value("context_tokens"), let window = value("context_window"),
      tokens.isFinite, window.isFinite, window > 0
    else { return nil }
    return ContextTokens(used: count(tokens), window: count(window))
  }

  /// `value` as a count; the server's unsigned 64-bit numbers can be past what `Int` holds.
  static func count(_ value: Double) -> Int {
    let rounded = value.rounded()
    if rounded >= 0x1p63 { return .max }
    return rounded < -0x1p63 ? .min : Int(rounded)
  }

  /// The model the session's usage report says it has run on most.
  static func modelInUse(_ sections: [OmnigentCoreFFI.EventSection]) -> String? {
    sections.first { $0.id == "usage" }?.details.first { $0.id == "model_in_use" }?.text
  }
}
