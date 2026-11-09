#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Values a server or a corrupted store could send, which no screen should crash or hang on.
  nonisolated enum HostileData {
    /// One word too long to wrap anywhere.
    static let unbroken = String(repeating: "W", count: 10_000)
    /// Right-to-left Arabic and Hebrew, an override mark, emoji sequences and stacked accents.
    static let bidirectional =
      "\u{202E}مرحبا بالعالم שלום עולם 👩‍👩‍👧‍👦🏳️‍🌈 e\u{0301}\u{0327}\u{0323} Z\u{0334}\u{0335}\u{0336}"
    /// Embedded newlines, tabs, a carriage return and a NUL.
    static let controlCharacters = "first line\nsecond\tline\r\n\n\t\ttail\u{0}end"
    /// Each kind of hostile text. The unbroken word comes last: rows after it would stay offscreen.
    static let samples = ["", bidirectional, controlCharacters, unbroken]
    /// Row counts that break any layout that isn't lazy.
    static let rowCount = 300
    /// A grouped form builds every row, so its lists stay short; `FormRowScaleRenderTests` has
    /// the few-hundred-row versions, which are too slow to run every time.
    static let formRowCount = 30

    /// A list's text: the hostile samples first, then ordinary rows, which keeps long lists cheap.
    static func text(_ index: Int) -> String {
      samples.indices.contains(index) ? samples[index] : "Row \(index)"
    }

    /// The first rows have out-of-range dates, then an ordinary date.
    static func date(_ index: Int) -> Date {
      switch index {
      case 0: .distantPast
      case 1: .distantFuture
      default: Date(timeIntervalSince1970: 1_793_880_000)
      }
    }
  }

  /// One state of one screen.
  nonisolated struct ScreenCase: CustomTestStringConvertible, Sendable {
    let name: String
    /// `nil` lets the content choose its height, for screens that don't scroll.
    let height: CGFloat?
    /// Realistic states must draw something; a hostile state only has to survive.
    let isRealistic: Bool
    /// A variant of a state rendered elsewhere: narrow only, where layouts break, to stay cheap.
    let isNarrowOnly: Bool
    let make: @MainActor @Sendable () -> AnyView

    var testDescription: String { name }

    init<Content: View>(
      _ name: String, height: CGFloat? = 600, realistic: Bool = false, narrowOnly: Bool = false,
      content: @escaping @MainActor @Sendable () -> Content
    ) {
      self.name = name
      self.height = height
      isRealistic = realistic
      isNarrowOnly = narrowOnly
      make = { AnyView(content()) }
    }
  }

  /// Renders a screen offscreen at a narrow and a normal width and checks the image.
  enum ScreenRenderer {
    static let narrowWidth: CGFloat = 240
    static let normalWidth: CGFloat = 700

    static func check(_ screen: ScreenCase) throws {
      for width in screen.isNarrowOnly ? [narrowWidth] : [narrowWidth, normalWidth] {
        let isNarrow = width == narrowWidth
        let rendered = try RenderSupport.render(
          screen.make(), width: width, height: screen.height, scheme: isNarrow ? .dark : .light,
          layout: isNarrow ? .compact : .regular)
        // The bitmap is in pixels: one to three times the points, by the display's scale.
        #expect(rendered.size.width >= width && rendered.size.width <= width * 3, "\(screen.name)")
        if let height = screen.height {
          #expect(
            rendered.size.height >= height && rendered.size.height <= height * 3, "\(screen.name)")
        }
        if screen.isRealistic {
          #expect(RenderSupport.inkCoverage(rendered) > 0, "\(screen.name) is blank at \(width)")
        }
        try RenderSupport.write(rendered, name: "hostile-\(screen.name)-\(Int(width))")
      }
    }
  }

  /// Keeps a view in a never-shown window across several updates, so what its `task` and
  /// `onChange` start gets to finish, which a single `RenderSupport.render` doesn't wait for.
  enum ViewSettler {
    static func settle(_ view: some View, updates: Int = 6) {
      _ = NSApplication.shared
      let host = NSHostingView(rootView: view.frame(width: 700, height: 600))
      let window = NSWindow(
        contentRect: CGRect(x: 0, y: 0, width: 700, height: 600), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.contentView = host
      for _ in 0..<updates {
        // A hidden window has no display cycle: drawing is what applies a pending update.
        host.layoutSubtreeIfNeeded()
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
          host.cacheDisplay(in: host.bounds, to: bitmap)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      window.contentView = nil
    }
  }

  /// Hosts `Section`-only content the way the app does, in a grouped form.
  struct GroupedFormHost<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
      Form { content }.formStyle(.grouped)
    }
  }
#endif
