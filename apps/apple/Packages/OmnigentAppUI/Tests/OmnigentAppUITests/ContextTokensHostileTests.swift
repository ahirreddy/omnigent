import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// The core writes these numbers as text from the server's unsigned 64-bit values.
@Suite("Context usage from hostile numbers")
struct ContextTokensHostileTests {
  private func usage(tokens: String, window: String) -> [OmnigentCoreFFI.EventSection] {
    [
      OmnigentCoreFFI.EventSection(
        id: "usage", title: "", summary: "",
        details: [
          OmnigentCoreFFI.DetailSection(
            id: "context_tokens", title: "", text: tokens, isCode: false),
          OmnigentCoreFFI.DetailSection(
            id: "context_window", title: "", text: window, isCode: false),
        ], sessionId: nil)
    ]
  }

  @Test("Text that isn't a number leaves the gauge off")
  func notNumbers() {
    for (tokens, window) in [("abc", "100"), ("100", "abc"), ("", ""), ("1,000", "2,000")] {
      #expect(ComposerAdapter.contextTokens(usage(tokens: tokens, window: window)) == nil)
    }
  }

  @Test("A window that isn't positive leaves the gauge off")
  func emptyWindows() {
    for window in ["0", "-1", "-0.0", "nan"] {
      #expect(ComposerAdapter.contextFraction(usage(tokens: "5", window: window)) == nil)
    }
  }

  @Test("Tokens below zero read as an empty gauge")
  func negativeTokens() {
    #expect(ComposerAdapter.contextFraction(usage(tokens: "-5", window: "100")) == 0)
  }

  @Test("Only the first usage section and detail count")
  func duplicates() {
    let sections = usage(tokens: "1", window: "4") + usage(tokens: "2", window: "4")
    #expect(ComposerAdapter.contextFraction(sections) == 0.25)
  }

  @Test("The largest count an Int holds reads as a full gauge")
  func largestRepresentable() {
    // 2^62 is exactly representable as a Double and fits an Int.
    let tokens = "4611686018427387904"
    #expect(ComposerAdapter.contextFraction(usage(tokens: tokens, window: "1000")) == 1)
  }

  @Test("u64::MAX tokens from the server")
  func tokensPastInt() {
    let tokens = String(UInt64.max)
    #expect(ComposerAdapter.contextFraction(usage(tokens: tokens, window: "1000")) == 1)
  }

  @Test("u64::MAX window from the server")
  func windowPastInt() {
    let window = String(UInt64.max)
    #expect(ComposerAdapter.contextFraction(usage(tokens: "5", window: window)) != nil)
  }

  @Test("NaN tokens")
  func nanTokens() {
    #expect(ComposerAdapter.contextTokens(usage(tokens: "nan", window: "100")) == nil)
  }

  @Test("Infinite window")
  func infiniteWindow() {
    #expect(ComposerAdapter.contextTokens(usage(tokens: "5", window: "inf")) == nil)
  }
}
