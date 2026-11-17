#if os(macOS)
  import AppKit

  /// A block's controls at rest as images (``MessageTextChromeStamp``), taken from the controls
  /// themselves once per look and scale, so a drawn run shows them without making them: a code
  /// block's header (Wrap, Download, Copy) and a table's row (Copy, Download, Expand).
  @MainActor
  enum MessageTextChromeStamps {
    /// `omnigent:message-text-chrome views` makes every drawn run's controls as views at once,
    /// to measure what drawing them saves.
    static let isEnabled =
      UserDefaults.standard.string(forKey: "omnigent:message-text-chrome") != "views"

    /// A code header's stamp is this wide: wider than its controls, which keep to its trailing
    /// edge, so it fits any header.
    static let codeWidth: CGFloat = 240
    /// A table's row is at least this wide (``MessageTextLayerCollector``).
    static let tableWidth: CGFloat = 120

    struct Stamps {
      var code: MessageTextChromeStamp?
      var table: MessageTextChromeStamp?
    }

    private struct Key: Hashable {
      var style: MessageTextStyle
      var scale: CGFloat
    }

    private static var made: [Key: Stamps] = [:]

    /// The stamps for `palette`'s look at `scale`, taken on first ask.
    static func stamps(for palette: MessageTextPalette, scale: CGFloat) -> Stamps {
      guard isEnabled, scale > 0 else { return Stamps() }
      let key = Key(style: palette.style, scale: scale)
      if let kept = made[key] { return kept }
      let isDark = palette.style.isDark
      let code = stamp(
        MessageCodeHeaderView(language: nil, code: "", palette: palette),
        size: CGSize(width: codeWidth, height: MessageTextMetrics.codeHeaderHeight),
        scale: scale, isDark: isDark, isTrailing: true)
      let table = stamp(
        MessageTableControlsView(
          table: MarkdownTable(header: [], rows: [], alignments: []), palette: palette),
        size: CGSize(width: tableWidth, height: MessageTextMetrics.tableControlsHeight),
        scale: scale, isDark: isDark, isTrailing: false)
      // A few looks at most: light and dark, a size or two.
      if made.count >= 8 { made.removeAll() }
      let stamps = Stamps(code: code, table: table)
      made[key] = stamps
      return stamps
    }

    /// `view` at rest, `size` points at `scale`, in a window that never shows; `nil` when it
    /// draws nothing there, so its run makes the view instead.
    static func stamp(
      _ view: NSView, size: CGSize, scale: CGFloat, isDark: Bool, isTrailing: Bool
    ) -> MessageTextChromeStamp? {
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
        backing: .buffered, defer: true)
      window.isReleasedWhenClosed = false
      window.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
      let container = NSView(frame: CGRect(origin: .zero, size: size))
      window.contentView = container
      view.frame = container.bounds
      container.addSubview(view)
      container.layoutSubtreeIfNeeded()
      defer { window.contentView = nil }
      // No planes: the rep allocates its own pixels.
      guard
        let rep = unsafe NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
          pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
          samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0)
      else { return nil }
      rep.size = size
      view.cacheDisplay(in: view.bounds, to: rep)
      guard hasInk(rep), let image = rep.cgImage else { return nil }
      return MessageTextChromeStamp(image: image, size: size, isTrailing: isTrailing)
    }

    /// Whether any pixel of `rep` is drawn.
    static func hasInk(_ rep: NSBitmapImageRep) -> Bool {
      for line in 0..<rep.pixelsHigh {
        for column in 0..<rep.pixelsWide
        where rep.colorAt(x: column, y: line)?.alphaComponent ?? 0 > 0 {
          return true
        }
      }
      return false
    }
  }
#endif
