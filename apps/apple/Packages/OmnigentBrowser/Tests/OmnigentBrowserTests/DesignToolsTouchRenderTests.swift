#if os(iOS)
  import CoreGraphics
  import SwiftUI
  import Testing
  import UIKit

  @testable import OmnigentBrowser

  /// The design tools on iPhone and iPad, light and dark, for checking their look.
  /// `OMNIGENT_UI_RENDER_DIR` keeps the PNGs; `OMNIGENT_LOOK_SCREENS` picks screens by prefix.
  @MainActor
  @Suite("Design tools drawn on iPhone and iPad", .serialized)
  struct DesignToolsTouchRenderTests {
    nonisolated static let screens = [
      "sweep-g-browser-touch-annotate", "sweep-g-browser-touch-draw",
      "sweep-g-browser-touch-buttons",
    ]

    @Test("draws the screen", arguments: screens, [false, true])
    func render(screen: String, pad: Bool) throws {
      let environment = ProcessInfo.processInfo.environment
      if let list = environment["OMNIGENT_LOOK_SCREENS"], !list.isEmpty,
        !list.split(separator: ",").contains(where: { screen.hasPrefix($0) })
      {
        return
      }
      let size =
        screen.hasSuffix("buttons")
        ? CGSize(width: pad ? 820 : 390, height: 120)
        : (pad ? CGSize(width: 820, height: 620) : CGSize(width: 390, height: 640))
      for dark in [false, true] {
        let view = Self.view(screen, pad: pad)
        let image = try Self.draw(view, size: size, pad: pad, dark: dark)
        guard let directory = environment["OMNIGENT_UI_RENDER_DIR"] else { continue }
        let device = pad ? "ipad" : "iphone"
        let url = URL(filePath: directory).appending(
          path: "\(screen)-\(device)\(dark ? "-dark" : "").png")
        try FileManager.default.createDirectory(
          at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #require(image.pngData()).write(to: url)
      }
    }

    private static func view(_ screen: String, pad: Bool) -> AnyView {
      let page = FakeDesignPage()
      page.hits = [Self.hit]
      let tools = BrowserDesignTools()
      page.install(in: tools)
      switch screen {
      case "sweep-g-browser-touch-annotate": return annotate(tools)
      case "sweep-g-browser-touch-draw": return draw(tools, pad: pad)
      default: return buttons(tools)
      }
    }

    /// Annotate's bar over the page with the button outlined, and a sent request's notice.
    private static func annotate(_ tools: BrowserDesignTools) -> AnyView {
      tools.open(.annotate)
      tools.show("Sent to agent.", isError: false)
      return AnyView(
        ZStack(alignment: .top) {
          TouchSamplePage()
          GeometryReader { geometry in
            BrowserDesignOutline(hit: Self.hit, size: geometry.size, picked: false)
          }
          BrowserDesignPickHint {}.padding(.top, 12)
        }
        .overlay(alignment: .bottom) {
          if let notice = tools.notice { BrowserDesignNoticeView(notice: notice) {} }
        })
    }

    /// Draw with a rectangle and words, its dock along the top on iPad and the bottom on iPhone.
    private static func draw(_ tools: BrowserDesignTools, pad: Bool) -> AnyView {
      tools.open(.draw)
      tools.shape = .rectangle
      tools.beginMark(at: CGPoint(x: 20, y: 150))
      tools.endMark(at: CGPoint(x: 220, y: 205))
      tools.shape = .text
      tools.addText("More space here", at: CGPoint(x: 30, y: 250))
      tools.note = "Move Buy up"
      return AnyView(
        ZStack {
          TouchSamplePage()
          Canvas { context, _ in
            context.withCGContext { BrowserDesignMarkDrawing.draw(tools.marks, in: $0) }
          }
        }
        .overlay(alignment: pad ? .top : .bottom) {
          BrowserDrawDock(tools: tools, compact: !pad, send: {}).padding(12)
        })
    }

    /// The tools' buttons as the iPad's address row shows them, Draw on.
    private static func buttons(_ tools: BrowserDesignTools) -> AnyView {
      tools.open(.draw)
      return AnyView(
        HStack(spacing: 14) {
          Spacer()
          BrowserDesignToolButtons(tools: tools)
          Image(systemName: "square.and.arrow.up")
          Image(systemName: "ellipsis.circle")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .tint(.primary)
        .font(.title3)
        .padding(16))
    }

    private static let hit = BrowserDesignHit(
      element: BrowserDesignElement(tag: "button", text: "Buy now"),
      rect: CGRect(x: 20, y: 150, width: 200, height: 54),
      viewport: CGSize(width: 390, height: 640),
      key: "e1")

    private static func draw(_ view: AnyView, size: CGSize, pad: Bool, dark: Bool) throws
      -> UIImage
    {
      let root =
        view
        .environment(\.horizontalSizeClass, pad ? .regular : .compact)
        .frame(width: size.width, height: size.height)
        .background(Color(uiColor: .systemBackground))
      let controller = UIHostingController(rootView: root)
      controller.overrideUserInterfaceStyle = dark ? .dark : .light
      controller.traitOverrides.horizontalSizeClass = pad ? .regular : .compact
      let bounds = CGRect(origin: .zero, size: size)
      let window = Self.window(bounds)
      window.overrideUserInterfaceStyle = dark ? .dark : .light
      window.rootViewController = controller
      window.isHidden = false
      for _ in 0..<8 {
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        CATransaction.flush()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
      }
      let image = UIGraphicsImageRenderer(bounds: bounds).image { context in
        if !window.drawHierarchy(in: bounds, afterScreenUpdates: true) {
          window.layer.render(in: context.cgContext)
        }
      }
      window.isHidden = true
      return image
    }

    private static func window(_ bounds: CGRect) -> UIWindow {
      if let scene = UIApplication.shared.connectedScenes.first(where: { $0 is UIWindowScene })
        as? UIWindowScene
      {
        let window = UIWindow(windowScene: scene)
        window.frame = bounds
        return window
      }
      let type: UIView.Type = UIWindow.self
      guard let window = type.init(frame: bounds) as? UIWindow else {
        preconditionFailure("a window type makes a window")
      }
      return window
    }
  }

  /// A plain storefront page, light as most sites are, to draw the tools over.
  private struct TouchSamplePage: View {
    var body: some View {
      VStack(alignment: .leading, spacing: 14) {
        Text("Example Store").font(.title2.bold())
        Text("Your order").font(.title3.weight(.semibold)).padding(.top, 20)
        Text("Two items ship in two days.").foregroundStyle(Color(white: 0.35))
        Text("Buy now")
          .font(.headline)
          .foregroundStyle(.white)
          .frame(width: 200, height: 54)
          .background(Color(red: 0.2, green: 0.4, blue: 0.9), in: RoundedRectangle(cornerRadius: 8))
        Spacer()
      }
      .padding(20)
      .foregroundStyle(Color(white: 0.1))
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.white)
      .environment(\.colorScheme, .light)
    }
  }
#endif
