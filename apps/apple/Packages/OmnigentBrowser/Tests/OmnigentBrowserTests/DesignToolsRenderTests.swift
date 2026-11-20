#if os(macOS)
  import AppKit
  import CoreGraphics
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentBrowser

  /// The design tools drawn over a sample page, light and dark, for checking their look.
  /// `OMNIGENT_UI_RENDER_DIR` keeps the PNGs; `OMNIGENT_LOOK_SCREENS` picks screens by prefix.
  @MainActor
  @Suite("Design tools drawn on a Mac", .serialized)
  struct DesignToolsRenderTests {
    nonisolated static let screens = [
      "sweep-f-browser-annotate", "sweep-f-browser-annotate-picked", "sweep-f-browser-draw",
      "sweep-f-browser-toolbar",
    ]
    private static let size = CGSize(width: 760, height: 420)

    @Test("draws the screen", arguments: screens)
    func render(screen: String) async throws {
      let environment = ProcessInfo.processInfo.environment
      if let list = environment["OMNIGENT_LOOK_SCREENS"], !list.isEmpty,
        !list.split(separator: ",").contains(where: { screen.hasPrefix($0) })
      {
        return
      }
      let view = try await Self.view(screen)
      for scheme in [ColorScheme.light, .dark] {
        let image = try Self.draw(view, height: screen.hasSuffix("toolbar") ? 60 : nil, scheme)
        guard let directory = environment["OMNIGENT_UI_RENDER_DIR"] else { continue }
        let url = URL(filePath: directory).appending(
          path: "\(screen)-mac\(scheme == .dark ? "-dark" : "").png")
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(image.representation(using: .png, properties: [:])).write(to: url)
      }
    }

    private static func view(_ screen: String) async throws -> AnyView {
      let page = FakeDesignPage()
      page.hits = [Self.hit]
      let tools = BrowserDesignTools()
      page.install(in: tools)
      switch screen {
      case "sweep-f-browser-annotate": return annotate(tools)
      case "sweep-f-browser-annotate-picked": return await annotatePicked(tools)
      case "sweep-f-browser-draw": return draw(tools)
      default: return try toolbar()
      }
    }

    /// Annotate pointing at the page's button, and the notice of a request just sent.
    private static func annotate(_ tools: BrowserDesignTools) -> AnyView {
      tools.open(.annotate)
      tools.show(DesignRequestOutboxCopy.sent, isError: false)
      return AnyView(
        ZStack(alignment: .top) {
          SamplePage()
          BrowserDesignOutline(hit: Self.hit, size: size, picked: false)
          BrowserDesignPickHint {}.padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
          if let notice = tools.notice { BrowserDesignNoticeView(notice: notice) {} }
        })
    }

    /// The picked button and the popover's card asking what should change.
    private static func annotatePicked(_ tools: BrowserDesignTools) async -> AnyView {
      tools.open(.annotate)
      await tools.pick(at: CGPoint(x: 0.1, y: 0.4))
      tools.request = "Make this button green, with more room around its label"
      // The popover, drawn where it opens: below the picked element.
      return AnyView(
        ZStack(alignment: .topLeading) {
          SamplePage()
          BrowserDesignOutline(hit: Self.hit, size: size, picked: true)
          BrowserAnnotateRequestCard(tools: tools)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)
            .offset(x: Self.hit.rect.minX, y: Self.hit.rect.maxY + 12)
        })
    }

    /// Draw with one mark of each shape and a note in the dock.
    private static func draw(_ tools: BrowserDesignTools) -> AnyView {
      tools.open(.draw)
      Self.mark(tools, .rectangle, [CGPoint(x: 24, y: 150), CGPoint(x: 210, y: 200)], .red)
      Self.mark(tools, .arrow, [CGPoint(x: 420, y: 260), CGPoint(x: 230, y: 185)], .blue)
      Self.mark(
        tools, .pen,
        (0..<20).map { CGPoint(x: 30 + Double($0) * 14, y: 98 + sin(Double($0)) * 4) },
        .orange)
      tools.shape = .text
      tools.addText("More space here", at: CGPoint(x: 430, y: 280))
      tools.note = "Tighten the header and move Buy up"
      return AnyView(
        ZStack(alignment: .top) {
          SamplePage()
          Canvas { context, _ in
            context.withCGContext { BrowserDesignMarkDrawing.draw(tools.marks, in: $0) }
          }
          BrowserDrawDock(tools: tools, send: {}).padding(.top, 12)
        })
    }

    /// The tab's toolbar with Annotate on.
    private static func toolbar() throws -> AnyView {
      let fixture = try TabFixture()
      fixture.environment.designRequestSender = { _, _ in }
      fixture.model.designTools.open(.annotate)
      return AnyView(
        BrowserTabToolbar(
          model: fixture.model, environment: fixture.environment, sheet: .constant(nil)))
    }

    private static let hit = BrowserDesignHit(
      element: BrowserDesignElement(tag: "button", text: "Buy now"),
      rect: CGRect(x: 24, y: 142, width: 186, height: 50), viewport: size, key: "e1")

    private static func mark(
      _ tools: BrowserDesignTools, _ kind: BrowserDesignMarkKind, _ points: [CGPoint],
      _ color: BrowserDesignMarkColor
    ) {
      tools.shape = kind
      tools.color = color
      tools.beginMark(at: points[0])
      for point in points.dropFirst() { tools.continueMark(to: point) }
      tools.endMark(at: nil)
    }

    private static func draw(_ view: AnyView, height: CGFloat?, _ scheme: ColorScheme) throws
      -> NSBitmapImageRep
    {
      _ = NSApplication.shared
      let frame = CGSize(width: size.width, height: height ?? size.height)
      let host = NSHostingView(
        rootView: view.environment(\.colorScheme, scheme)
          .environment(\.controlActiveState, .key)
          .frame(width: frame.width, height: frame.height)
          .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.985)))
      host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
      let window = NSWindow(
        contentRect: CGRect(origin: .zero, size: frame), styleMask: [.borderless],
        backing: .buffered, defer: false)
      window.appearance = host.appearance
      window.contentView = host
      host.frame = CGRect(origin: .zero, size: frame)
      MainLoop.settle(limit: 0.2, windows: [window])
      host.layoutSubtreeIfNeeded()
      let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
      host.cacheDisplay(in: host.bounds, to: bitmap)
      window.orderOut(nil)
      return bitmap
    }
  }

  /// The outbox's "sent" notice, as the app's outbox words it.
  private enum DesignRequestOutboxCopy {
    static let sent = "Sent to agent."
  }

  /// A plain storefront page, light as most sites are, to draw the tools over.
  private struct SamplePage: View {
    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Text("Example Store").font(.title2.bold())
          Spacer()
          Text("Cart (2)")
        }
        Text("Your order").font(.title3.weight(.semibold)).padding(.top, 20)
        Text("Two items ship in two days. Taxes are added at checkout.")
          .foregroundStyle(Color(white: 0.35))
        Text("Buy now")
          .font(.headline)
          .foregroundStyle(.white)
          .frame(width: 186, height: 50)
          .background(Color(red: 0.2, green: 0.4, blue: 0.9), in: RoundedRectangle(cornerRadius: 8))
        Spacer()
      }
      .padding(24)
      .foregroundStyle(Color(white: 0.1))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.white)
      .environment(\.colorScheme, .light)
    }
  }
#endif
