internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// A drag the page starts has to be ended, however the gesture went: until Chromium is told the
/// drag is over, Blink ignores every click, key and wheel step sent to the page, which keeps
/// drawing and looks frozen. See DESIGN.md, "Input".
extension Proofs {
  static let dragEndPages: [String: String] = [
    "drag-end": """
    <!doctype html><title>OWL drag end</title>\(pageStyle)<h2>Drags that end</h2>
    <button id=tap>Tap</button> <span id=result>0</span> <input id=field placeholder="type">
    <p><a id=link href="/page/drag-end?again">A link that can be dragged</a></p>
    <p><img id=image width=160 height=90 alt="" src="data:image/svg+xml,%3Csvg
    xmlns='http://www.w3.org/2000/svg' width='160' height='90'%3E%3Crect width='160' height='90'
    fill='%2336f'/%3E%3C/svg%3E"></p>
    <div id=source draggable=true style="width: 200px; padding: 12px; border: 2px solid #36f">
    drag me out</div>
    <p id=text>Words to select and then drag away from where they are.</p>
    <script>
    window.dragEnd = { taps: 0, starts: 0, ends: 0 };
    document.querySelector('#tap').addEventListener('click', () => {
      document.querySelector('#result').textContent = ++window.dragEnd.taps;
    });
    document.addEventListener('dragstart', () => { window.dragEnd.starts++; });
    document.addEventListener('dragend', () => { window.dragEnd.ends++; });
    </script>
    """
  ]

  /// One way a person's drag can go: where it starts, how far it moves, how long the button
  /// stays down after the last movement, and whether the text under it is selected first.
  private struct DragGesture {
    let name: String
    let selector: String
    let distance: Double
    let holdMilliseconds: Int
    var selectsFirst = false
  }

  private static let dragGestures = [
    DragGesture(
      name: "a flick of a draggable box", selector: "#source", distance: 30, holdMilliseconds: 0),
    DragGesture(
      name: "a held drag of a draggable box", selector: "#source", distance: 60,
      holdMilliseconds: 700),
    DragGesture(name: "a flick of a link", selector: "#link", distance: 90, holdMilliseconds: 0),
    DragGesture(name: "a flick of an image", selector: "#image", distance: 30, holdMilliseconds: 0),
    DragGesture(
      name: "a flick of selected text", selector: "#text", distance: 40, holdMilliseconds: 0,
      selectsFirst: true),
    DragGesture(
      name: "a second flick of a draggable box", selector: "#source", distance: 30,
      holdMilliseconds: 0),
  ]

  func dragEnds() async throws {
    try await load(try await pageURL("drag-end"), title: "OWL drag end")
    try await settle(0.5)
    for gesture in Self.dragGestures {
      try await dragAndLetGo(gesture)
      try await settle(1)
      let starts = Int(try await number("window.dragEnd.starts"))
      let ends = Int(try await number("window.dragEnd.ends"))
      let answers = try await pageAnswersInput()
      Clock.log(
        "after \(gesture.name): \(starts) drag(s) started, \(ends) ended, the page "
          + (answers ? "answers" : "IGNORES") + " a click and a key")
      guard answers, starts == ends else {
        throw ProofFailure(
          "After \(gesture.name) the page \(answers ? "answers" : "ignores") input; "
            + "\(starts) drag(s) started and \(ends) ended.")
      }
    }
  }

  /// Selects the text first when the gesture says so, then drags from the element.
  private func dragAndLetGo(_ gesture: DragGesture) async throws {
    let start = try await center(of: gesture.selector)
    if gesture.selectsFirst {
      _ = try await webView.evaluateJavaScript(
        "getSelection().selectAllChildren(document.querySelector('\(gesture.selector)')); true")
      try await settle(0.2)
    }
    try await dragAndLetGo(
      from: start, distance: gesture.distance, holdMilliseconds: gesture.holdMilliseconds)
  }

  /// Presses at `start`, moves `distance` points and lets go, as events through the window.
  func dragAndLetGo(from start: CGPoint, distance: Double, holdMilliseconds: Int) async throws {
    try sendMouse(.leftMouseDown, at: start, pressure: 1)
    try await Task.sleep(for: .milliseconds(30))
    let steps = 4
    for step in 1...steps {
      let moved = distance * Double(step) / Double(steps)
      try sendMouse(
        .leftMouseDragged, at: CGPoint(x: start.x + moved, y: start.y + moved / 3), pressure: 1)
      try await Task.sleep(for: .milliseconds(8))
    }
    try await Task.sleep(for: .milliseconds(holdMilliseconds))
    try sendMouse(
      .leftMouseUp, at: CGPoint(x: start.x + distance, y: start.y + distance / 3), pressure: 0)
  }

  private func sendMouse(
    _ type: NSEvent.EventType, at viewPoint: CGPoint, pressure: Float
  ) throws {
    guard let surface, let window else { throw ProofFailure("No window to send the mouse to.") }
    guard
      let event = NSEvent.mouseEvent(
        with: type, location: surface.convert(viewPoint, to: nil), modifierFlags: [],
        timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
        context: nil, eventNumber: 0, clickCount: 1, pressure: pressure)
    else { throw ProofFailure("Cannot synthesize \(type).") }
    window.sendEvent(event)
  }

  /// Whether a click on the button and a key in the field both reach the page's script.
  private func pageAnswersInput() async throws -> Bool {
    let taps = try await number("window.dragEnd.taps")
    click(at: try await center(of: "#tap"))
    try await settle(0.4)
    let tapped = try await number("window.dragEnd.taps") == taps + 1
    _ = try await webView.evaluateJavaScript("document.querySelector('#field').value = ''; true")
    click(at: try await center(of: "#field"))
    key(keyCode: Self.keyCodes["k"] ?? 0, characters: "k")
    try await settle(0.4)
    let typed = try await webView.evaluateJavaScript("document.querySelector('#field').value")
    return tapped && typed == .string("k")
  }
}
