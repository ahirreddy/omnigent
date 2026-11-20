internal import CoreGraphics
public import SwiftUI

/// The open design tool's layer over a tab's page, and the tools' notices. It covers the page
/// view exactly, so it follows the page's bounds and visibility; it closes the tool when the
/// page navigates.
public struct BrowserDesignOverlay: View {
  private let model: BrowserTabModel

  /// Creates the overlay.
  /// - Parameter model: The tab.
  public init(model: BrowserTabModel) {
    self.model = model
  }

  /// The view body.
  public var body: some View {
    let tools = model.designTools
    ZStack {
      if let tool = tools.tool {
        GeometryReader { geometry in
          switch tool {
          case .annotate:
            BrowserAnnotateLayer(tools: tools, size: geometry.size, page: page)
          case .draw:
            BrowserDrawLayer(tools: tools, size: geometry.size, page: page)
          }
        }
        #if os(macOS)
          .onExitCommand { tools.close() }
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("browser.design.\(tool.rawValue)Layer")
      }
    }
    // The page's size with no tool open too, so a notice sits at its bottom; the empty
    // space takes no clicks.
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay(alignment: .bottom) {
      if let notice = tools.notice {
        BrowserDesignNoticeView(notice: notice) { tools.dismiss(notice) }
      }
    }
    .onChange(of: model.url) { tools.pageMayHaveChanged() }
    .onChange(of: model.isLoading) { _, loading in
      if loading { tools.pageStartedLoading() }
    }
    // Draw's marks follow the page's zoom.
    .onChange(of: model.zoomFactor) { Task { await tools.refreshViewport() } }
  }

  private var page: BrowserDesignPageViews {
    BrowserDesignPageViews(view: model.tab?.platformView, keyboard: model.tab?.keyboardView)
  }
}

/// Annotate: the pointer or a finger outlines the element under it; a click or tap picks it
/// and a popover asks what should change.
struct BrowserAnnotateLayer: View {
  let tools: BrowserDesignTools
  let size: CGSize
  let page: BrowserDesignPageViews

  var body: some View {
    ZStack(alignment: .topLeading) {
      BrowserDesignInputLayer(
        handlers: handlers, aims: tools.picked == nil, scrolls: tools.picked == nil, page: page)
      if let hit = tools.picked?.hit ?? tools.hover {
        BrowserDesignOutline(hit: hit, size: size, picked: tools.picked != nil)
          .allowsHitTesting(false)
      }
      if tools.picked == nil {
        BrowserDesignPickHint { tools.close() }
          .frame(maxWidth: .infinity)
          .padding(.top, 12)
      }
    }
    .popover(
      isPresented: pickedBinding, attachmentAnchor: .rect(.rect(pickedRect)),
      arrowEdge: pickedRect.midY > size.height * 0.6 ? .top : .bottom
    ) {
      BrowserAnnotateRequestCard(tools: tools)
    }
  }

  private var handlers: BrowserDesignInputHandlers {
    BrowserDesignInputHandlers(
      move: { point in
        guard let fraction = fraction(point) else { return }
        Task { await tools.hover(at: fraction) }
      },
      press: { point in
        if tools.picked != nil {
          tools.unpick()
          return
        }
        guard let fraction = fraction(point) else { return }
        Task { await tools.pick(at: fraction) }
      },
      escape: { tools.close() })
  }

  private func fraction(_ point: CGPoint) -> CGPoint? {
    guard size.width > 0, size.height > 0 else { return nil }
    return CGPoint(x: point.x / size.width, y: point.y / size.height)
  }

  private var pickedRect: CGRect {
    tools.picked?.hit.rect(in: size) ?? .zero
  }

  private var pickedBinding: Binding<Bool> {
    Binding(
      get: { tools.picked != nil },
      set: { shown in
        if !shown, !tools.isPreparing { tools.unpick() }
      })
  }
}

/// Annotate's popover (a sheet on iPhone): what should change, Cancel and Send.
struct BrowserAnnotateRequestCard: View {
  @Bindable var tools: BrowserDesignTools
  @FocusState private var focused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      if let element = tools.picked?.hit.element {
        Label(element.shortName, systemImage: BrowserDesignTool.annotate.systemImage)
          .font(.callout.weight(.medium))
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      TextField("What should change?", text: $tools.request, axis: .vertical)
        .lineLimit(2...6)
        .textFieldStyle(.roundedBorder)
        .focused($focused)
        .disabled(tools.isPreparing)
        .accessibilityIdentifier("browser.design.request")
      HStack {
        Spacer()
        Button("Cancel") { tools.close() }
          .keyboardShortcut(.cancelAction)
        Button(tools.isPreparing ? "Sending\u{2026}" : "Send to Agent") {
          Task { await tools.sendAnnotation() }
        }
        .keyboardShortcut(.defaultAction)
        .buttonStyle(.borderedProminent)
        .disabled(tools.annotationBlocked != nil)
        .help(tools.annotationBlocked ?? "Send this request to the session's agent")
        .accessibilityIdentifier("browser.design.send")
      }
    }
    .padding(14)
    #if os(macOS)
      .frame(width: 320)
    #else
      .frame(minWidth: 320, idealWidth: 360)
      .presentationDetents([.medium])
    #endif
    .onAppear { focused = true }
  }
}
