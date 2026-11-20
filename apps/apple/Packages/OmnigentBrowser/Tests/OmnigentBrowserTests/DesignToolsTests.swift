import CoreGraphics
import Foundation
import Testing

@testable import OmnigentBrowser

/// A page for the tools: hit tests answer from `hits`, in order, then the last one.
@MainActor
final class FakeDesignPage {
  var hits: [BrowserDesignHit?] = []
  var hitFailure: BrowserError?
  var snapshotFailure: BrowserError?
  private(set) var points: [CGPoint] = []
  var sent: [BrowserDesignRequest] = []
  var sendFailure: BrowserError?
  var url = URL(string: "https://app.example.test/settings?token=x")

  func install(in tools: BrowserDesignTools) {
    tools.page = BrowserDesignPageAccess(
      hitTest: { [self] point throws(BrowserError) in
        points.append(point)
        if let hitFailure { throw hitFailure }
        return hits.count > 1 ? hits.removeFirst() : hits.first.flatMap { $0 }
      },
      snapshot: { [self] () throws(BrowserError) -> CGImage in
        if let snapshotFailure { throw snapshotFailure }
        do {
          return try solidImage(width: 200, height: 200)
        } catch {
          throw .snapshotFailed("test image")
        }
      })
    tools.send = { [self] request throws(BrowserError) in
      if let sendFailure { throw sendFailure }
      sent.append(request)
    }
    tools.pageURL = { [self] in url }
  }
}

func designHit(_ tag: String = "button", key: String = "e1") -> BrowserDesignHit {
  BrowserDesignHit(
    element: BrowserDesignElement(tag: tag, text: "Buy"),
    rect: CGRect(x: 10, y: 10, width: 30, height: 20), viewport: CGSize(width: 100, height: 100),
    key: key)
}

/// The tools' state: opening and closing, Annotate's pick and send, Draw's marks and send.
@MainActor
@Suite("Design tools: state")
struct DesignToolsTests {
  private func tools(_ page: FakeDesignPage) -> BrowserDesignTools {
    let tools = BrowserDesignTools()
    page.install(in: tools)
    return tools
  }

  @Test("a tool opens and closes; opening drops the other's drafts")
  func openAndClose() {
    let tools = tools(FakeDesignPage())
    tools.toggle(.draw)
    tools.beginMark(at: .zero)
    tools.endMark(at: CGPoint(x: 5, y: 5))
    tools.note = "Note"
    #expect(tools.tool == .draw && tools.marks.count == 1)
    tools.toggle(.annotate)
    #expect(tools.tool == .annotate && tools.marks.isEmpty && tools.note.isEmpty)
    tools.toggle(.annotate)
    #expect(tools.tool == nil)
  }

  @Test("hovering outlines the element at the latest point; a click picks it")
  func hoverAndPick() async {
    let page = FakeDesignPage()
    page.hits = [designHit("p"), designHit("button")]
    let tools = tools(page)
    tools.open(.annotate)
    await tools.hover(at: CGPoint(x: 0.1, y: 0.1))
    #expect(tools.hover?.element.tag == "p")
    await tools.pick(at: CGPoint(x: 0.2, y: 0.3))
    #expect(tools.picked?.hit.element.tag == "button" && tools.hover == nil)
    #expect(tools.picked?.point == CGPoint(x: 0.2, y: 0.3))
    // Picked: the pointer no longer outlines anything.
    await tools.hover(at: CGPoint(x: 0.5, y: 0.5))
    #expect(page.points.count == 2)
    tools.unpick()
    #expect(tools.picked == nil && tools.tool == .annotate)
  }

  @Test("Annotate's Send needs a pick and words, then sends with the element's screenshot")
  func sendAnnotation() async throws {
    let page = FakeDesignPage()
    page.hits = [designHit()]
    let tools = tools(page)
    tools.open(.annotate)
    #expect(tools.annotationBlocked == "Point at an element on the page first.")
    await tools.pick(at: CGPoint(x: 0.2, y: 0.2))
    #expect(tools.annotationBlocked == "Say what should change first.")
    tools.request = "Make it green"
    await tools.sendAnnotation()
    let sent = try #require(page.sent.first)
    #expect(sent.content == .element(designHit().element, request: "Make it green"))
    #expect(sent.pageURL == page.url && sent.tool == .annotate)
    let png = try #require(sent.screenshotPNG)
    #expect(try BrowserDesignCapture.image(fromPNG: png).width == 92)
    #expect(tools.tool == nil && tools.notice?.message == BrowserDesignTools.sendingNotice)
  }

  @Test("an element that moved away goes without its screenshot, and the notice says why")
  func sendWithoutScreenshot() async throws {
    let page = FakeDesignPage()
    page.hits = [designHit(key: "e1"), designHit(key: "e9")]
    let tools = tools(page)
    tools.open(.annotate)
    await tools.pick(at: CGPoint(x: 0.2, y: 0.2))
    tools.request = "Bigger"
    await tools.sendAnnotation()
    #expect(try #require(page.sent.first).screenshotPNG == nil)
    let notice = try #require(tools.notice)
    #expect(notice.message.hasPrefix(BrowserDesignTools.withoutScreenshotNotice))
    #expect(notice.message.contains("moved or changed") && !notice.isError)
  }

  @Test("a request the app refuses keeps the tool open with its drafts, saying why")
  func refusedSend() async throws {
    let page = FakeDesignPage()
    page.hits = [designHit()]
    page.sendFailure = .designToolFailed("No session here.")
    let tools = tools(page)
    tools.open(.annotate)
    await tools.pick(at: CGPoint(x: 0.2, y: 0.2))
    tools.request = "Bigger"
    await tools.sendAnnotation()
    #expect(tools.tool == .annotate && tools.request == "Bigger" && !tools.isPreparing)
    let notice = try #require(tools.notice)
    #expect(notice.isError && notice.message == "No session here.")
  }

  @Test("a page the picker can't read closes the tool and says why")
  func pickerFailure() async throws {
    let page = FakeDesignPage()
    page.hitFailure = .scriptFailed(message: "blocked")
    let tools = tools(page)
    tools.open(.annotate)
    await tools.hover(at: CGPoint(x: 0.5, y: 0.5))
    #expect(tools.tool == nil)
    let notice = try #require(tools.notice)
    #expect(notice.isError && notice.message.hasPrefix("Annotate stopped: "))
  }

  @Test("Draw keeps marks that went somewhere, text marks, and Undo")
  func marks() {
    let tools = tools(FakeDesignPage())
    tools.open(.draw)
    tools.beginMark(at: CGPoint(x: 1, y: 1))
    tools.endMark(at: CGPoint(x: 1, y: 1))
    #expect(tools.marks.isEmpty && tools.drawingBlocked == "Draw on the page first.")
    tools.shape = .arrow
    tools.color = .green
    tools.beginMark(at: CGPoint(x: 1, y: 1))
    tools.continueMark(to: CGPoint(x: 4, y: 4))
    #expect(tools.drawing?.points.count == 2)
    tools.endMark(at: nil)
    #expect(tools.marks.first?.kind == .arrow && tools.marks.first?.color == .green)
    #expect(tools.colors[.pen] == .red)
    #expect(!tools.addText("   ", at: .zero))
    #expect(tools.addText(" Wider ", at: CGPoint(x: 9, y: 9)))
    #expect(tools.marks.last?.text == "Wider" && tools.marks.count == 2)
    tools.undo()
    tools.undo()
    #expect(tools.marks.isEmpty && tools.undoBlocked == "There's nothing to undo.")
  }

  @Test("Draw's Send composites the marks onto the page and closes")
  func sendDrawing() async throws {
    let page = FakeDesignPage()
    let tools = tools(page)
    tools.open(.draw)
    tools.beginMark(at: CGPoint(x: 1, y: 1))
    tools.endMark(at: CGPoint(x: 50, y: 50))
    tools.note = "Align these"
    await tools.sendDrawing(viewSize: CGSize(width: 100, height: 100))
    let sent = try #require(page.sent.first)
    #expect(sent.content == .drawing(note: "Align these", marks: 1))
    #expect(try BrowserDesignCapture.image(fromPNG: try #require(sent.screenshotPNG)).width == 200)
    #expect(tools.tool == nil && tools.notice?.message == BrowserDesignTools.sendingNotice)
  }

  @Test("a snapshot that fails keeps the drawing, saying why")
  func failedSnapshot() async throws {
    let page = FakeDesignPage()
    page.snapshotFailure = .snapshotFailed("busy")
    let tools = tools(page)
    tools.open(.draw)
    tools.beginMark(at: .zero)
    tools.endMark(at: CGPoint(x: 9, y: 9))
    await tools.sendDrawing(viewSize: CGSize(width: 100, height: 100))
    #expect(page.sent.isEmpty && tools.marks.count == 1 && !tools.isPreparing)
    #expect(
      try #require(tools.notice).message == BrowserError.snapshotFailed("busy").localizedDescription
    )
  }

  @Test("navigating or reloading the page closes an open tool, saying so")
  func pageChanges() throws {
    let page = FakeDesignPage()
    let tools = tools(page)
    tools.open(.draw)
    tools.pageMayHaveChanged()
    #expect(tools.tool == .draw)
    page.url = URL(string: "https://app.example.test/other")
    tools.pageMayHaveChanged()
    #expect(tools.tool == nil && tools.notice?.message == BrowserDesignTools.pageChangedNotice)
    tools.open(.annotate)
    #expect(tools.notice == nil)
    tools.pageStartedLoading()
    #expect(tools.tool == nil)
    let notice = BrowserDesignNotice("old", isError: false)
    tools.dismiss(notice)
    #expect(tools.notice != nil)
    tools.dismiss(try #require(tools.notice))
    #expect(tools.notice == nil)
  }
}
