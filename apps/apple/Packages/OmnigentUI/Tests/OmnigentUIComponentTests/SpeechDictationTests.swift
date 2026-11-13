#if os(iOS)
  import Testing

  @testable import OmnigentUIComponents

  @MainActor
  @Suite("Dictation into the composer")
  struct SpeechDictationTests {
    @Test(
      "recognized words follow the draft that was there, a space apart unless it ends in one",
      arguments: [
        ("", "hello there", "hello there"), ("Fix", "the build", "Fix the build"),
        ("Fix ", "the build", "Fix the build"), ("Line one\n", "two", "Line one\ntwo"),
        ("Draft", "", "Draft "),
      ])
    func appending(base: String, words: String, expected: String) {
      #expect(SpeechDictation.appending(words, to: base) == expected)
    }

    @Test("stopping when nothing is listening changes nothing")
    func stopWhileIdle() {
      let dictation = SpeechDictation()
      #expect(!dictation.isListening)
      dictation.stop()
      dictation.stop()
      #expect(!dictation.isListening)
      #expect(!SpeechDictation.shared.isListening)
    }
  }
#endif
