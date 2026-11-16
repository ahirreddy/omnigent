#if os(macOS)
  import OmnigentViewTesting
  import OmnigentViewTextReading

  extension OffscreenWindow {
    /// Whether any text on screen contains this, for long lines.
    func shows(containing text: String) throws -> Bool {
      try shownText().contains { $0.contains(text) }
    }
  }
#endif
