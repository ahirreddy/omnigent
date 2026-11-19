#if os(macOS)
  import AppKit
  import QuartzCore

  extension SidebarSlide {
    /// The nearest split view controller whose split view holds `view`.
    static func controller(holding view: NSView) -> NSSplitViewController? {
      // AppKit declares `superview` unowned(unsafe); the chain is only walked here.
      var ancestor = unsafe view.superview
      while let current = ancestor {
        if let split = current as? NSSplitView,
          let controller = split.delegate as? NSSplitViewController
        {
          return controller
        }
        ancestor = unsafe current.superview
      }
      return nil
    }

    /// A picture of `rect` of `view` (all of it by default) as it shows now, at the display's
    /// scale or at `scale` pixels a point, or `nil` when it has no size.
    static func picture(of view: NSView, in rect: NSRect? = nil, scale: CGFloat? = nil)
      -> CALayer?
    {
      let bounds = rect ?? view.bounds
      guard bounds.width > 0, bounds.height > 0,
        let bitmap = scale.map({ bitmap(of: bounds.size, scale: $0) })
          ?? view.bitmapImageRepForCachingDisplay(in: bounds)
      else { return nil }
      view.cacheDisplay(in: bounds, to: bitmap)
      let layer = CALayer()
      layer.contents = bitmap.cgImage
      // The window server draws glass and materials, not the picture: an opaque ground.
      layer.backgroundColor = NSColor.windowBackgroundColor.cgColor
      return layer
    }

    /// An empty bitmap of `size` points at `scale` pixels a point.
    private static func bitmap(of size: NSSize, scale: CGFloat) -> NSBitmapImageRep? {
      // With no planes given, AppKit allocates and owns the pixels.
      let bitmap = unsafe NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int((size.width * scale).rounded(.up)),
        pixelsHigh: Int((size.height * scale).rounded(.up)), bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0)
      bitmap?.size = size
      return bitmap
    }

    /// The view holding the titlebar's controls and toolbar: the traffic lights' ancestor as
    /// wide as the window.
    static func titlebar(in window: NSWindow) -> NSView? {
      // AppKit declares `superview` unowned(unsafe); the chain is only walked here.
      var view = unsafe window.standardWindowButton(.closeButton)?.superview
      while let current = view, current.frame.width < window.frame.width - 1 {
        view = unsafe current.superview
      }
      return view
    }

    /// The titlebar and its toolbar as they show now, with no ground of their own.
    static func titlebarPicture(in window: NSWindow) -> CALayer? {
      guard let titlebar = titlebar(in: window), let picture = picture(of: titlebar) else {
        return nil
      }
      picture.backgroundColor = nil
      return picture
    }
  }
#endif
