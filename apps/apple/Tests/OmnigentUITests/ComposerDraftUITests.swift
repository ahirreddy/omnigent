import UIKit
import XCTest

/// The composer's draft on the local server's fixture session: images pasted from the Add menu
/// attach whatever form the pasteboard holds them in, and a draft with a quote block comes back
/// with the block after the app is relaunched.
///
/// Set `TEST_RUNNER_DRAFT_SHOTS_DIR` to also write each state as `draft-<device>-<state>.png`.
final class ComposerDraftUITests: XCTestCase {
  /// Each way an image reaches the pasteboard, and whether it attaches: an image object (as
  /// screenshots copy), PNG or JPEG bytes (as Safari copies), HEIC bytes (as Photos copies), and
  /// an item whose PNG its source fails to give, which must show an error, not vanish.
  private struct PasteboardForm {
    let name: String
    let attaches: Bool
    let write: @MainActor (UIImage) -> Void

    init(_ name: String, _ attaches: Bool, _ write: @escaping @MainActor (UIImage) -> Void) {
      self.name = name
      self.attaches = attaches
      self.write = write
    }
  }

  private static let pasteboardForms: [PasteboardForm] = [
    .init("image object", true) { UIPasteboard.general.image = $0 },
    .init("PNG data", true) { write($0.pngData(), as: "public.png") },
    .init("JPEG data", true) { write($0.jpegData(compressionQuality: 0.9), as: "public.jpeg") },
    .init("HEIC data", true) { write($0.heicData(), as: "public.heic") },
    .init("a PNG that never arrives", false) { _ in writeFailingPNG() },
  ]

  private static func write(_ data: Data?, as type: String) {
    UIPasteboard.general.setData(data ?? Data(), forPasteboardType: type)
  }

  /// One item offering a PNG whose loader fails, as an app that quit leaves it.
  private static func writeFailingPNG() {
    let provider = NSItemProvider()
    provider.registerDataRepresentation(
      forTypeIdentifier: "public.png", visibility: .all
    ) { completion in
      completion(nil, CocoaError(.fileReadUnknown))
      return nil
    }
    UIPasteboard.general.setItemProviders([provider], localOnly: true, expirationDate: nil)
  }

  @MainActor
  func testPastedImagesAttachInEveryPasteboardForm() throws {
    let support = LiveServerUITestSupport(self)
    let sessionID = try support.fixtureSession()
    let app = support.launch(opening: sessionID)
    support.waitForTranscript(sessionID, in: app)
    let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { context in
      UIColor.systemPink.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
    }
    let chips = app.descendants(matching: .any).matching(
      NSPredicate(
        format: "identifier BEGINSWITH 'draft-attachment-' "
          + "AND NOT identifier BEGINSWITH 'draft-attachment-remove-'"))
    let error = support.element("composer-attachment-error", in: app)
    var attachedCount = 0
    for form in Self.pasteboardForms {
      form.write(image)
      support.tap(app.buttons["composer-add"], "the Add menu")
      support.tap(app.buttons["Paste"].firstMatch, "Paste in the Add menu")
      let attached = support.waitUntil(timeout: 15) {
        chips.count == attachedCount + 1 || error.exists
      }
      if !form.attaches {
        XCTAssertTrue(error.exists, "\(form.name) failed without a word")
        XCTAssertTrue(error.label.contains("could not be read as an image"), error.label)
        try shot(support, "paste-error")
        support.tap(app.buttons["composer-attachment-error-dismiss"], "the error's Dismiss")
        continue
      }
      XCTAssertFalse(error.exists, "\(form.name): \(error.label)")
      XCTAssertTrue(attached && !error.exists, "\(form.name) did not attach")
      guard attached, !error.exists else { continue }
      // Every format arrives as one the server reads as an image.
      let name = chips.element(boundBy: attachedCount).staticTexts.firstMatch.label
      attachedCount += 1
      XCTAssertTrue(
        [".png", ".jpeg", ".gif", ".webp"].contains { name.hasSuffix($0) },
        "\(form.name) attached as \(name)")
    }
    try shot(support, "pasted-images")
    // Leave the fixture's draft empty for other tests.
    let remove = support.element(prefix: "draft-attachment-remove-", in: app)
    while remove.waitForExistence(timeout: 2) { remove.tap() }
  }

  @MainActor
  func testQuoteBlockSurvivesRelaunch() throws {
    let support = LiveServerUITestSupport(self)
    let sessionID = try support.fixtureSession()
    var app = support.launch(opening: sessionID)
    support.waitForTranscript(sessionID, in: app)
    // The fixture's answer.
    let reply = app.descendants(matching: .any)
      .matching(
        NSPredicate(format: "identifier BEGINSWITH 'message-' AND label CONTAINS 'Swift sources'")
      ).firstMatch
    XCTAssertTrue(reply.waitForExistence(timeout: 15), "no reply to quote")
    reply.press(forDuration: 1.2)
    support.tap(app.buttons["Reply"].firstMatch, "the Reply action", timeout: 5)
    XCTAssertTrue(
      support.element("composer-quote-0", in: app).waitForExistence(timeout: 5), "no quote block")
    support.type("Kept across launches", into: app.textViews["composer-input"])
    try shot(support, "quote-before-relaunch")
    // The draft file is written shortly after the last change; going home also writes it.
    XCUIDevice.shared.press(.home)
    sleep(2)
    app.terminate()

    app = support.launch(opening: sessionID)
    support.waitForTranscript(sessionID, in: app)
    let quote = support.element("composer-quote-0", in: app)
    XCTAssertTrue(quote.waitForExistence(timeout: 15), "the quote block was not restored")
    let input = app.textViews["composer-input"]
    XCTAssertEqual(input.value as? String, "Kept across launches", "the reply text changed")
    try shot(support, "quote-after-relaunch")
    // Leave the fixture's draft empty for other tests.
    support.tap(app.buttons["composer-quote-remove-0"], "Remove quote")
    input.tap()
    input.press(forDuration: 1.2)
    let selectAll = app.menuItems["Select All"].firstMatch
    if selectAll.waitForExistence(timeout: 3) {
      selectAll.tap()
      input.typeText(XCUIKeyboardKey.delete.rawValue)
    }
  }

  @MainActor
  private func shot(_ support: LiveServerUITestSupport, _ state: String) throws {
    support.shot(state)
    guard let directory = ProcessInfo.processInfo.environment["DRAFT_SHOTS_DIR"] else { return }
    let device = support.isPhone ? "iphone" : "ipad"
    try XCUIScreen.main.screenshot().pngRepresentation.write(
      to: URL(fileURLWithPath: directory).appendingPathComponent("draft-\(device)-\(state).png"))
  }
}
