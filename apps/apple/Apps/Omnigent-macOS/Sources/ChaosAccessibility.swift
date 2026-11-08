#if DEBUG
  import AppKit

  /// Accessibility actions ``ChaosDriver`` performs on a window's controls, as VoiceOver or
  /// Switch Control would: they reach handlers no click does, such as a message's actions.
  @MainActor
  enum ChaosAccessibility {
    /// An action a control offers.
    struct Action {
      let name: String
      let perform: @MainActor () -> Void
    }

    /// The actions `element` offers: press, its custom actions, and increment and decrement on
    /// sliders and steppers. Show Menu is left out: its menu would hold the driver until a
    /// person closes it.
    static func actions(of element: any NSAccessibilityProtocol) -> [Action] {
      guard let object = element as? NSObject else { return [] }
      var actions: [Action] = []
      // Optional protocol methods: called only when the element implements them.
      if object.responds(to: NSSelectorFromString("accessibilityPerformPress")) {
        actions.append(Action(name: "press") { _ = element.accessibilityPerformPress() })
      }
      // Every control answers increment and decrement; only these change a value with them.
      let adjustable: Set<NSAccessibility.Role> = [.slider, .incrementor, .scrollBar]
      if let role = element.accessibilityRole(), adjustable.contains(role) {
        actions.append(Action(name: "increment") { _ = element.accessibilityPerformIncrement() })
        actions.append(Action(name: "decrement") { _ = element.accessibilityPerformDecrement() })
      }
      let customs = NSSelectorFromString("accessibilityCustomActions")
      if object.responds(to: customs) {
        for custom in element.accessibilityCustomActions() ?? [] {
          actions.append(Action(name: "custom \"\(custom.name)\"") { perform(custom) })
        }
      }
      return actions
    }

    /// Performs one action of a control in `window`, after `log` says which; `pick(count)`
    /// chooses an index below `count`. Tries a few controls, since most offer none.
    static func act(in window: NSWindow, pick: (Int) -> Int, log: (String) -> Void) {
      let controls = ChaosTargets.controls(in: window)
      guard !controls.isEmpty else {
        log("accessibility: no controls")
        return
      }
      for _ in 0..<10 {
        let control = controls[pick(controls.count)]
        let offered = actions(of: control.element)
        guard !offered.isEmpty else { continue }
        let action = offered[pick(offered.count)]
        log("accessibility \(action.name) on \(control.name) in \(ChaosLog.describe(window))")
        // Later, as a click's event is: the action may run a modal panel.
        DispatchQueue.main.async { action.perform() }
        return
      }
      log("accessibility: no actions")
    }

    /// Runs a custom action through its handler, or its target and selector.
    private static func perform(_ custom: NSAccessibilityCustomAction) {
      if let handler = custom.handler {
        _ = handler()
      } else if let target = custom.target as? NSObject, let selector = custom.selector,
        target.responds(to: selector)
      {
        _ = unsafe target.perform(selector, with: custom)
      }
    }
  }
#endif
