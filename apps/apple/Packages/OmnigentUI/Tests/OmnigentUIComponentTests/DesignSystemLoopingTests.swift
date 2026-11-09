#if os(macOS)
  import AppKit
  import OmnigentViewTesting
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Looping indicator layers")
  @MainActor
  struct DesignSystemLoopingTests {
    private let colors = LoopingColors(.secondary, in: EnvironmentValues())
    private let fade = LoopingMotion.fade(low: 0.25, duration: 0.5, stagger: 0.15)

    private func host(
      _ shape: LoopingShape, motion: LoopingMotion? = nil, isAnimating: Bool = false
    ) -> LoopingLayerHost {
      let host = LoopingLayerHost()
      host.frame = CGRect(x: 0, y: 0, width: 40, height: 20)
      host.configure(
        shape: shape, motion: motion ?? fade, colors: colors, isAnimating: isAnimating)
      host.layout()
      return host
    }

    private func content(_ host: LoopingLayerHost) throws -> CALayer {
      try #require(host.layer?.sublayers?.first)
    }

    private func parts(_ host: LoopingLayerHost) throws -> [CALayer] {
      try content(host).sublayers ?? []
    }

    @Test("one dot is centered at its diameter")
    func dot() throws {
      let parts = try parts(host(.dot(diameter: 8)))
      try #require(parts.count == 1)
      let path = try #require((parts[0] as? CAShapeLayer)?.path)
      #expect(path.boundingBox == CGRect(x: 16, y: 6, width: 8, height: 8))
    }

    @Test("a row of dots is centered and evenly spaced")
    func dots() throws {
      let parts = try parts(host(.dots(count: 3, diameter: 6, spacing: 4)))
      #expect(parts.map(\.frame.minX) == [7, 17, 27])
      #expect(parts.allSatisfy { $0.frame.minY == 7 && $0.frame.width == 6 })
    }

    @Test("no dots draws nothing rather than failing")
    func noDots() throws {
      #expect(try parts(host(.dots(count: 0, diameter: 6, spacing: 4))).isEmpty)
      #expect(try parts(host(.dots(count: -2, diameter: 6, spacing: 4))).isEmpty)
    }

    @Test("a glyph fills the view at its size")
    func glyph() throws {
      let text = try #require(try parts(host(.glyph("●", size: 12))).first as? CATextLayer)
      #expect(text.string as? String == "●")
      #expect(text.fontSize == 12)
      #expect(text.frame.size == CGSize(width: 40, height: 20))
    }

    @Test("Otto draws every part inside the view, in its own colors")
    func otto() throws {
      let parts = try parts(host(.otto))
      #expect(parts.count == OttoArt.parts.count)
      for (index, part) in parts.enumerated() {
        let shape = try #require(part as? CAShapeLayer)
        let box = try #require(shape.path).boundingBox
        #expect(!box.isEmpty && box.maxX <= 40 && box.maxY <= 20)
        #expect(shape.fillColor == colors.otto[index])
      }
    }

    @Test("a new color repaints the same layers; a new shape replaces them")
    func reconfigure() throws {
      let host = host(.dot(diameter: 8))
      let part = try #require(try parts(host).first as? CAShapeLayer)
      let changed = LoopingColors(.accent, in: EnvironmentValues())
      host.configure(shape: .dot(diameter: 8), motion: fade, colors: changed, isAnimating: false)
      #expect(try parts(host).first === part)
      #expect(part.fillColor == changed.tint)
      host.configure(shape: .dot(diameter: 4), motion: fade, colors: changed, isAnimating: false)
      #expect(try parts(host).first !== part)
    }

    @Test("a fade loops each dot, staggered, and leaves a running loop alone")
    func fadeLoop() throws {
      let host = host(.dots(count: 2, diameter: 6, spacing: 4))
      host.runLoop(fade, restart: true)
      let animations = try parts(host).map {
        try #require($0.animation(forKey: "loop") as? CABasicAnimation)
      }
      try #require(animations.count == 2)
      #expect(animations[0].keyPath == "opacity")
      #expect(animations[0].toValue as? Float == 0.25)
      #expect(animations[0].repeatCount == .infinity)
      #expect(animations[0].autoreverses)
      #expect(abs(animations[1].beginTime - animations[0].beginTime - 0.15) < 0.001)
      let begun = animations[0].beginTime
      host.runLoop(fade, restart: false)
      let kept = try parts(host)[0].animation(forKey: "loop")
      #expect(kept?.beginTime == begun)
    }

    @Test("a bob moves the whole mark up and back, once")
    func bobLoop() throws {
      let bob = LoopingMotion.bob(amplitude: 2, duration: 0.8)
      let host = host(.otto, motion: bob)
      let content = try content(host)
      host.runLoop(bob, restart: true)
      let animation = try #require(content.animation(forKey: "loop") as? CABasicAnimation)
      #expect(animation.keyPath == "transform.translation.y")
      #expect(animation.toValue as? CGFloat == -2)
      host.runLoop(bob, restart: false)
      #expect(content.animation(forKey: "loop")?.duration == 0.8)
    }

    @Test("off screen or asked to stop, every loop is removed")
    func stops() throws {
      let host = host(.dots(count: 2, diameter: 6, spacing: 4), isAnimating: true)
      #expect(!host.isAnimating, "no window")
      host.runLoop(fade, restart: true)
      host.configure(
        shape: .dots(count: 2, diameter: 6, spacing: 4), motion: fade, colors: colors,
        isAnimating: true)
      #expect(try parts(host).allSatisfy { $0.animation(forKey: "loop") == nil })
    }

    @Test("a window's visibility changing is followed")
    func occlusion() throws {
      let screen = OffscreenWindow(OttoView(isWorking: true).frame(width: 40, height: 40))
      defer { screen.close() }
      let host = try #require(screen.allViews.lazy.compactMap { $0 as? LoopingLayerHost }.first)
      #expect(try parts(host).count == OttoArt.parts.count)
      NotificationCenter.default.post(
        name: NSWindow.didChangeOcclusionStateNotification, object: screen.window)
      let bobbing = try content(host).animation(forKey: "loop") != nil
      #expect(bobbing == host.isAnimating)
    }

    @Test("the working marks use the shapes they promise", arguments: [(false, 1), (true, 3)])
    func marks(typing: Bool, count: Int) throws {
      let screen = OffscreenWindow(
        Group { if typing { TypingIndicator() } else { LiveIndicator() } }.frame(width: 40))
      defer { screen.close() }
      let host = try #require(screen.allViews.lazy.compactMap { $0 as? LoopingLayerHost }.first)
      #expect(try parts(host).count == count)
    }
  }
#endif
