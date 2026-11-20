public import CoreGraphics
internal import Foundation
public import Observation

/// The element Annotate picked, and where: the point it was picked at, as a fraction of the
/// viewport, finds it again before its screenshot is taken.
nonisolated public struct BrowserDesignPick: Hashable, Sendable {
  /// The element as picked.
  public var hit: BrowserDesignHit
  /// The click, as a fraction of the viewport each way.
  public var point: CGPoint
}

/// What the tools need from the tab's page; the tab model supplies its live tab's.
struct BrowserDesignPageAccess {
  /// The element at a point given as a fraction of the viewport, or `nil`.
  var hitTest: (CGPoint) async throws(BrowserError) -> BrowserDesignHit?
  /// A snapshot of the page alone.
  var snapshot: () async throws(BrowserError) -> CGImage
  /// Where the visible page sits in its document now.
  var viewport: () async throws(BrowserError) -> BrowserDesignViewport
}

/// One browser tab's design tools: which tool is open, its drafts, and its notices. Every open
/// and close starts a new opening, so work started in one never lands in a tool opened since.
@Observable
public final class BrowserDesignTools {
  /// Sending's notice once the request is handed to the app.
  public static let sendingNotice = "Sending to agent\u{2026}"
  /// Annotate's notice when its request goes without the element's screenshot.
  public static let withoutScreenshotNotice =
    "Sending to agent without the element's screenshot, which couldn't be taken."
  /// The notice when the page navigates under an open tool.
  public static let pageChangedNotice = "The page changed, so the tool closed."

  /// The open tool, if any.
  public private(set) var tool: BrowserDesignTool?
  /// A send is taking its screenshot; the drafts are frozen.
  public private(set) var isPreparing = false
  /// The element under the pointer, before one is picked.
  public private(set) var hover: BrowserDesignHit?
  /// The picked element.
  public private(set) var picked: BrowserDesignPick?
  /// What should change about the picked element.
  public var request = ""
  /// Draw's marks, oldest first, in the page's CSS pixels.
  public private(set) var marks: [BrowserDesignMark] = []
  /// The mark being drawn.
  public private(set) var drawing: BrowserDesignMark?
  /// Draw's note for the agent.
  public var note = ""
  /// The shape the next mark takes.
  public var shape = BrowserDesignMarkKind.pen {
    didSet { if shape != oldValue { previousShape = oldValue } }
  }
  /// The shape chosen before this one, which Apple Pencil's double tap goes back to.
  @ObservationIgnored public private(set) var previousShape: BrowserDesignMarkKind?
  /// Each shape's color.
  public var colors = Dictionary(
    uniqueKeysWithValues: BrowserDesignMarkKind.allCases.map { ($0, BrowserDesignMarkColor.red) })
  /// The latest notice, until it is dismissed.
  public private(set) var notice: BrowserDesignNotice?
  /// Where the visible page sat when Draw last read it; `nil` before the first read.
  public private(set) var viewport: BrowserDesignViewport?

  @ObservationIgnored private(set) var opening = 0
  @ObservationIgnored var page: BrowserDesignPageAccess?
  @ObservationIgnored var send: ((BrowserDesignRequest) throws(BrowserError) -> Void)?
  @ObservationIgnored var pageURL: () -> URL? = { nil }
  /// The page the tool opened on, to close it when the page changes.
  @ObservationIgnored private(set) var openedURL: URL?
  @ObservationIgnored private var hoverPoint: CGPoint?
  @ObservationIgnored private var isHovering = false
  @ObservationIgnored private var isReadingViewport = false
  @ObservationIgnored private var viewportFailed = false
  /// The stand-in marks were placed under before the page's viewport was read.
  @ObservationIgnored private var provisionalViewport: BrowserDesignViewport?

  /// Creates closed tools.
  public init() {}

  /// Whether the tools can work here: an app takes their requests.
  public var isAvailable: Bool { send != nil }

  /// The color of the shape the next mark takes.
  public var color: BrowserDesignMarkColor {
    get { colors[shape] ?? .red }
    set { colors[shape] = newValue }
  }

  // MARK: Opening and closing

  /// Opens `tool`, or closes it when it's the open one.
  public func toggle(_ tool: BrowserDesignTool) {
    if self.tool == tool { close() } else { open(tool) }
  }

  /// Opens `tool`, dropping the previous tool's drafts.
  public func open(_ tool: BrowserDesignTool) {
    reset()
    self.tool = tool
    openedURL = pageURL()
    notice = nil
  }

  /// Closes the open tool. Anything it started is dropped with its opening.
  public func close() {
    guard tool != nil else { return }
    reset()
  }

  /// The tab's page or its zoom changed: an open tool closes when it is another page now.
  public func pageMayHaveChanged() {
    guard tool != nil, pageURL() != openedURL else { return }
    close()
    show(Self.pageChangedNotice, isError: false)
  }

  /// The page started loading a document (a reload too): an open tool closes.
  public func pageStartedLoading() {
    guard tool != nil else { return }
    close()
    show(Self.pageChangedNotice, isError: false)
  }

  private func reset() {
    opening += 1
    tool = nil
    isPreparing = false
    hover = nil
    picked = nil
    request = ""
    marks = []
    drawing = nil
    note = ""
    hoverPoint = nil
    viewport = nil
    provisionalViewport = nil
    viewportFailed = false
  }

  // MARK: Notices

  /// Shows `message` over the page.
  public func show(_ message: String, isError: Bool) {
    notice = BrowserDesignNotice(message, isError: isError)
  }

  /// Hides `notice`, unless a newer one replaced it.
  public func dismiss(_ notice: BrowserDesignNotice) {
    if self.notice?.id == notice.id { self.notice = nil }
  }

  /// A failure in the page: the tool closes and says why.
  func fail(_ error: BrowserError, opening: Int) {
    guard opening == self.opening else { return }
    let tool = self.tool
    close()
    show("\(tool?.title ?? "The tool") stopped: \(error.localizedDescription)", isError: true)
  }

  // MARK: Annotate

  /// Outlines the element at `point` (a fraction of the viewport). Hit tests run one at a
  /// time, each at the latest point the pointer moved to.
  public func hover(at point: CGPoint) async {
    guard tool == .annotate, picked == nil, !isPreparing, let page else { return }
    hoverPoint = point
    guard !isHovering else { return }
    isHovering = true
    defer { isHovering = false }
    let opening = self.opening
    while let next = hoverPoint, opening == self.opening, picked == nil {
      hoverPoint = nil
      do throws(BrowserError) {
        let hit = try await page.hitTest(next)
        guard opening == self.opening, picked == nil else { return }
        hover = hit
      } catch {
        fail(error, opening: opening)
        return
      }
    }
  }

  /// Picks the element at `point` (a fraction of the viewport), asked again rather than taken
  /// from the outline, which can lag.
  public func pick(at point: CGPoint) async {
    guard tool == .annotate, picked == nil, !isPreparing, let page else { return }
    let opening = self.opening
    do throws(BrowserError) {
      let hit = try await page.hitTest(point)
      guard opening == self.opening, picked == nil, let hit else { return }
      picked = BrowserDesignPick(hit: hit, point: point)
      hover = nil
    } catch {
      fail(error, opening: opening)
    }
  }

  /// Lets go of the picked element, to pick another; what was typed stays.
  public func unpick() {
    guard tool == .annotate, !isPreparing else { return }
    picked = nil
  }

  /// Why Annotate's Send can't run now; `nil` when it can.
  public var annotationBlocked: String? {
    if isPreparing { return "Annotate is still taking its screenshot." }
    if picked == nil { return "Point at an element on the page first." }
    if request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      return "Say what should change first."
    }
    return nil
  }

  // MARK: Draw

  /// The viewport marks show under in a view `viewWidth` points wide: the page's, or until it
  /// is read, the unscrolled page that marks placed meanwhile move from once it is.
  public func shownViewport(viewWidth: CGFloat) -> BrowserDesignViewport {
    if let viewport { return viewport }
    if let provisionalViewport { return provisionalViewport }
    let stand = BrowserDesignViewport.unscrolled(viewWidth: viewWidth)
    provisionalViewport = stand
    return stand
  }

  /// The page point under `point` in an overlay `viewWidth` points wide.
  public func pagePoint(_ point: CGPoint, viewWidth: CGFloat) -> CGPoint {
    shownViewport(viewWidth: viewWidth).pagePoint(point, viewWidth: viewWidth)
  }

  /// Reads where the visible page sits, so Draw's marks follow its scroll and zoom. A read
  /// already in flight answers for this one.
  public func refreshViewport() async {
    guard tool == .draw, !isReadingViewport, let page else { return }
    isReadingViewport = true
    defer { isReadingViewport = false }
    let opening = self.opening
    do throws(BrowserError) {
      let read = try await page.viewport()
      guard opening == self.opening else { return }
      if viewport == nil, let provisionalViewport {
        marks = marks(under: read)
        drawing = drawing?.mapped { read.rebased($0, from: provisionalViewport) }
        self.provisionalViewport = nil
      }
      if viewport != read { viewport = read }
      viewportFailed = false
    } catch {
      // The marks stay; the next read tries again, and a run of failures says so once.
      guard opening == self.opening, !viewportFailed else { return }
      viewportFailed = true
      show("Draw can't follow the page: \(error.localizedDescription)", isError: true)
    }
  }

  /// The marks under the page's viewport `read`: those placed before the page's viewport was
  /// first read move to where they were drawn on screen.
  func marks(under read: BrowserDesignViewport) -> [BrowserDesignMark] {
    guard viewport == nil, let provisionalViewport else { return marks }
    return marks.map { $0.mapped { read.rebased($0, from: provisionalViewport) } }
  }

  /// Starts a mark of the chosen shape at `point` (the page's CSS pixels).
  public func beginMark(at point: CGPoint) {
    guard tool == .draw, !isPreparing, shape != .text else { return }
    drawing = BrowserDesignMark(kind: shape, points: [point], color: color)
  }

  /// Draws the mark on to `point`.
  public func continueMark(to point: CGPoint) {
    guard tool == .draw, let drawing else { return }
    self.drawing = drawing.extended(to: point)
  }

  /// Ends the mark, at `point` when the pointer let go there; it is kept if it went anywhere.
  public func endMark(at point: CGPoint?) {
    guard let drawing else { return }
    self.drawing = nil
    let mark = point.map(drawing.extended(to:)) ?? drawing
    guard tool == .draw, !isPreparing, mark.isDrawn else { return }
    marks.append(mark)
  }

  /// Adds a text mark at `point` (the page's CSS pixels); blank words add nothing.
  /// - Returns: Whether a mark was added.
  @discardableResult
  public func addText(_ text: String, at point: CGPoint) -> Bool {
    let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard tool == .draw, !isPreparing, !words.isEmpty else { return false }
    marks.append(
      BrowserDesignMark(kind: .text, points: [point], color: colors[.text] ?? .red, text: words))
    return true
  }

  /// Goes back to the shape chosen before this one, as Apple Pencil's "switch to previous tool".
  public func switchToPreviousShape() {
    guard tool == .draw, let previousShape else { return }
    shape = previousShape
  }

  /// Removes the newest mark.
  public func undo() {
    guard tool == .draw, !isPreparing, !marks.isEmpty else { return }
    marks.removeLast()
  }

  /// Why Draw's Undo can't run now; `nil` when it can.
  public var undoBlocked: String? {
    if isPreparing { return "Draw is still taking its screenshot." }
    return marks.isEmpty ? "There's nothing to undo." : nil
  }

  /// Why Draw's Send can't run now; `nil` when it can.
  public var drawingBlocked: String? {
    if isPreparing { return "Draw is still taking its screenshot." }
    return marks.isEmpty ? "Draw on the page first." : nil
  }

  /// Freezes the drafts for a send; `false` when the tool can't send now.
  func beginSend(_ tool: BrowserDesignTool) -> Bool {
    guard self.tool == tool, !isPreparing else { return false }
    isPreparing = true
    return true
  }

  /// Back to editing after a failed send, saying why, if the opening is still current.
  func sendFailed(_ error: BrowserError, opening: Int) {
    guard opening == self.opening else { return }
    isPreparing = false
    show(error.localizedDescription, isError: true)
  }
}
