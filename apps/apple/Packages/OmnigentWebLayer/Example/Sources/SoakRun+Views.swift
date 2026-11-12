internal import AppKit
internal import Foundation
internal import OmnigentWebLayer

/// Pages in no window next to the one on screen: an agent's page, and tabs opened behind.
extension SoakRun {
  func offscreen(_ seconds: Double) async throws {
    let profile = proofs.model.session.makeEphemeralProfile(label: "soak-offscreen")
    defer { profile.close() }
    let view = profile.makeWebView(initialURL: try await proofs.pageURL("soak-animation"))
    view.rendersOffscreen = true
    try await proofs.waitForLoad(view, title: "OWL soak animation")
    let half = seconds / 2
    try await proofs.settle(half)
    let middle = view.statistics
    try await proofs.settle(half)
    let end = view.statistics
    let late = end.framesPresented - middle.framesPresented
    Clock.log(
      "soak offscreen view: \(end.framesPresented) frames, \(Int(Double(late) / half)) fps in "
        + "the second half, \(end.framesDropped) dropped")
    if late == 0 { monitor.fail("a page in no window stopped presenting frames") }
  }

  /// Six animating pages in no window, as tabs opened behind are, while the page on screen is
  /// used. Each must keep its frame rate, and so must the one on screen.
  func crowd(_ seconds: Double) async throws {
    let profile = proofs.model.session.makeEphemeralProfile(label: "soak-crowd")
    defer { profile.close() }
    var views: [WebView] = []
    for _ in 0..<6 {
      let view = profile.makeWebView(initialURL: try await proofs.pageURL("soak-animation"))
      view.rendersOffscreen = true
      views.append(view)
    }
    for view in views {
      try await proofs.waitForLoad(view, title: "OWL soak animation")
    }
    let before = views.map(\.statistics.framesPresented)
    try await active(seconds)
    let rates = zip(views, before).map { view, frames in
      Int(Double(view.statistics.framesPresented - frames) / seconds)
    }
    let dropped = views.map { Int($0.statistics.framesDropped) }
    Clock.log("soak crowd: frames a second \(rates), dropped \(dropped)")
    if rates.contains(0) { monitor.fail("a page in no window stopped presenting frames") }
  }
}
