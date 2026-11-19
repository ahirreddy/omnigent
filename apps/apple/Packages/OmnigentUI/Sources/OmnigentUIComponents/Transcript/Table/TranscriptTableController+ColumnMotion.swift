#if os(macOS)
  import AppKit

  extension TranscriptTableController {
    // MARK: Columns sliding in and out

    /// How long after the viewport's last width step a column's slide counts as ended.
    static let columnMotionQuiet: TimeInterval = 0.15
    /// How long a slide that moves no width keeps text at snapped widths: past AppKit's
    /// 0.25 s collapse.
    static let columnMotionLimit: TimeInterval = 0.4

    /// Watches the split view columns around the transcript (the sidebar, the right panel). A
    /// split view controller animates a column's collapse by setting the transcript's width
    /// once a frame, so meanwhile text lays out as in a live resize, and no wider than it was.
    func watchColumns() {
      columnWatches = []
      guard unsafe scrollView.window != nil else { return }
      // AppKit declares `superview` unowned(unsafe); the chain is only walked here.
      var ancestor = unsafe scrollView.superview
      while let view = ancestor {
        if let split = view as? NSSplitView,
          let controller = split.delegate as? NSSplitViewController
        {
          // A collapsed column's view may not be loaded, and the transcript isn't in it.
          for item in controller.splitViewItems
          where
            !(item.viewController.isViewLoaded
            && scrollView.isDescendant(of: item.viewController.view))
          {
            columnWatches.append(
              item.observe(\.isCollapsed, options: [.old, .new]) { [weak self] item, change in
                // AppKit sets the item's state as the collapse starts, on the main thread, and
                // says so again as it ends.
                guard change.oldValue != change.newValue else { return }
                // A column that collapses in one step gives one new width: nothing to hold.
                guard !SidebarSlide.collapsesAtOnce(item) else { return }
                MainActor.assumeIsolated { self?.columnMotionBegan() }
              })
          }
        }
        ancestor = unsafe view.superview
      }
    }

    /// A column beside the transcript started to collapse or expand: text keeps the width it
    /// has now as the most it lays out at, so a widening slide lays nothing out again.
    func columnMotionBegan() {
      guard Self.holdsColumnMotion, isShown else { return }
      probe("transcript column motion", "began")
      if !widthHolds.contains(.columnMotion), model.width > 0 {
        textStyle.columnCeiling = textStyle.metrics(width: model.width).columnWidth
        cli.style.contentCeiling = cli.style.column(width: model.width).width
      }
      holdWidths(.columnMotion, true)
      scheduleColumnMotionEnd(after: Self.columnMotionLimit)
    }

    /// The viewport took a width step while a column slides: the slide ends once the steps
    /// stop.
    func columnMotionStepped() {
      guard widthHolds.contains(.columnMotion) else { return }
      scheduleColumnMotionEnd(after: Self.columnMotionQuiet)
    }

    /// Whether text at `width` lays out other than it will once every hold ends, so their end
    /// has to lay it out again.
    func heldTextDiffers(at width: CGFloat) -> Bool {
      if isCLI {
        return cli.style.column(width: width) != cli.style.column(width: width, exact: true)
      }
      return textStyle.metrics(width: width) != textStyle.exactMetrics(width: width)
    }

    private func scheduleColumnMotionEnd(after delay: TimeInterval) {
      columnMotionGeneration += 1
      let generation = columnMotionGeneration
      MainRunLoop.perform(after: delay) { [weak self] in
        MainActor.assumeIsolated {
          guard let self, generation == self.columnMotionGeneration else { return }
          self.probe("transcript column motion", "ended")
          self.textStyle.columnCeiling = nil
          self.cli.style.contentCeiling = nil
          self.holdWidths(.columnMotion, false)
        }
      }
    }

    /// Whether a column's slide lays text out at snapped widths. `omnigent:transcript-column-
    /// motion exact` lays it out at each width the slide passes.
    static let holdsColumnMotion = holdsColumnMotion(in: .standard)

    static func holdsColumnMotion(in defaults: UserDefaults) -> Bool {
      defaults.string(forKey: "omnigent:transcript-column-motion") != "exact"
    }
  }
#endif
