internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// Whether the frame on screen is the page's latest: a page that keeps running while its last
/// frame never arrives looks frozen, and counts frames like a healthy one until then.
extension SoakRun {
  /// Compares the state the presented frame spells with the state the page's script is in.
  /// Fails when they still differ after a second; a frame that was only late is counted.
  func checkShownState() async throws {
    var drawn = -1
    var current = -1
    var waited = 0
    // A frame takes a moment to follow the script; one still missing after 100 ms is late.
    for pause in [40, 60, 150, 250, 500] {
      let before = Int(try await proofs.number("window.soak.shown"))
      drawn = try await drawnState()
      current = Int(try await proofs.number("window.soak.shown"))
      if drawn == before || drawn == current {
        if waited > 100 { monitor.noteLateFrame(milliseconds: Double(waited)) }
        return
      }
      try await Task.sleep(for: .milliseconds(pause))
      waited += pause
    }
    monitor.fail("the frame on screen shows state \(drawn) while the page is at \(current)")
  }

  /// Reads the state strip out of a snapshot of the frame the host last presented.
  private func drawnState() async throws -> Int {
    let script =
      "(() => { const r = document.querySelector('#state').getBoundingClientRect();"
      + " return [r.x, r.y, r.width, r.height, innerWidth]; })()"
    guard case .array(let values) = try await proofs.webView.evaluateJavaScript(script),
      values.count == 5, case .number(let left) = values[0], case .number(let top) = values[1],
      case .number(let width) = values[2], case .number(let height) = values[3],
      case .number(let pageWidth) = values[4], width > 0, pageWidth > 0
    else { throw ProofFailure("The page has no state strip.") }
    let png = try await proofs.webView.snapshotPNG()
    guard let image = NSBitmapImageRep(data: png) else {
      throw ProofFailure("The snapshot is not an image.")
    }
    let scale = Double(image.pixelsWide) / pageWidth
    var state = 0
    for index in 0..<16 {
      let pointX = (left + (Double(index) + 0.5) * width / 16) * scale
      let pointY = (top + height / 2) * scale
      guard let color = image.colorAt(x: Int(pointX), y: Int(pointY)) else {
        throw ProofFailure("The state strip is outside the snapshot.")
      }
      if color.redComponent > 0.5 { state |= 1 << index }
    }
    return state
  }
}
