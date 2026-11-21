internal import CoreGraphics
internal import SwiftUI

/// Draw: pen, rectangle, arrow and text marks over the page, kept in its CSS pixels so they
/// follow its scroll and zoom; the dock with the shape, color, Undo, the note and Send (along
/// the top, or the bottom on iPhone).
struct BrowserDrawLayer: View {
  @Bindable var tools: BrowserDesignTools
  let size: CGSize
  let page: BrowserDesignPageViews
  @State private var textDraft: TextDraft?
  #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
  #endif

  /// Words being typed for a text mark, at their point in the layer.
  struct TextDraft: Equatable, Identifiable {
    /// Each draft its own field, so one ending can't put away the next.
    let id = UUID()
    var point: CGPoint
    var text = ""
  }

  /// Two fingers scroll the page on iPhone and iPad; the Mac's wheel leaves it, as the web's.
  private static var scrollsPage: Bool {
    #if os(macOS)
      false
    #else
      true
    #endif
  }

  /// The dock along the bottom, in two rows, within a thumb's reach on iPhone.
  private var compactDock: Bool {
    #if os(iOS)
      sizeClass == .compact
    #else
      false
    #endif
  }

  var body: some View {
    let viewport = tools.shownViewport(viewWidth: size.width)
    ZStack(alignment: .topLeading) {
      BrowserDesignInputLayer(
        handlers: handlers, aims: !tools.isPreparing, scrolls: Self.scrollsPage, draws: true,
        page: page)
      Canvas { context, _ in
        let marks = tools.marks + (tools.drawing.map { [$0] } ?? [])
        context.withCGContext { drawing in
          drawing.concatenate(viewport.transform(toWidth: size.width))
          BrowserDesignMarkDrawing.draw(marks, in: drawing)
        }
      }
      .allowsHitTesting(false)
      .accessibilityHidden(true)
      if let textDraft, !tools.isPreparing {
        BrowserDrawTextField(
          draft: Binding(get: { textDraft }, set: { self.textDraft = $0 }),
          color: tools.colors[.text] ?? .red,
          commit: { commitText(textDraft.id, andSend: $0) },
          cancel: { if self.textDraft?.id == textDraft.id { self.textDraft = nil } }
        )
        .id(textDraft.id)
      }
    }
    .overlay(alignment: compactDock ? .bottom : .top) {
      BrowserDrawDock(tools: tools, compact: compactDock, send: send)
        .padding(compactDock ? .bottom : .top, 12)
        .padding(.horizontal, 12)
    }
    .task { await followPage() }
  }

  private var handlers: BrowserDesignInputHandlers {
    BrowserDesignInputHandlers(
      press: { point in
        guard tools.shape == .text else {
          tools.beginMark(at: pagePoint(point))
          return
        }
        commitText(textDraft?.id, andSend: false)
        if !tools.isPreparing { textDraft = TextDraft(point: point) }
      },
      drag: { tools.continueMark(to: pagePoint($0)) },
      release: { tools.endMark(at: pagePoint($0)) },
      escape: {
        if textDraft != nil { textDraft = nil } else { tools.close() }
      },
      scrolled: { Task { await tools.refreshViewport() } },
      undo: { tools.undo() },
      previousTool: { tools.switchToPreviousShape() })
  }

  /// The page's CSS pixel under `point` in the layer.
  private func pagePoint(_ point: CGPoint) -> CGPoint {
    tools.pagePoint(point, viewWidth: size.width)
  }

  /// Reads where the page sits now, then again every quarter second while Draw is open, so the
  /// marks follow the page as it scrolls or zooms.
  private func followPage() async {
    while !Task.isCancelled {
      await tools.refreshViewport()
      do {
        try await Task.sleep(for: .milliseconds(250))
      } catch {
        // Cancelled: Draw closed.
        return
      }
    }
  }

  /// Puts draft `id`'s words on the page if it is still the one being typed; with `andSend`,
  /// then sends.
  private func commitText(_ id: UUID?, andSend: Bool) {
    if let textDraft, textDraft.id == id {
      tools.addText(textDraft.text, at: pagePoint(textDraft.point))
      self.textDraft = nil
    }
    if andSend { send() }
  }

  private func send() {
    // Words still being typed go on the page first.
    commitText(textDraft?.id, andSend: false)
    Task { await tools.sendDrawing() }
  }
}

/// The field a text mark is typed in, where it will go.
struct BrowserDrawTextField: View {
  @Binding var draft: BrowserDrawLayer.TextDraft
  let color: BrowserDesignMarkColor
  let commit: (_ andSend: Bool) -> Void
  let cancel: () -> Void
  @FocusState private var focused: Bool

  var body: some View {
    TextField("Type, then Return", text: $draft.text)
      .textFieldStyle(.roundedBorder)
      .font(.body.weight(.semibold))
      .foregroundStyle(Color(cgColor: color.cgColor))
      .frame(width: 220)
      .focused($focused)
      .onSubmit { commit(false) }
      #if os(macOS)
        .onExitCommand(perform: cancel)
      #endif
      .background {
        // Command-Return puts the words on the page and sends.
        Button("Add and Send") { commit(true) }
          .keyboardShortcut(.return, modifiers: .command)
          .hidden()
      }
      .offset(x: draft.point.x, y: draft.point.y - 12)
      .onAppear { focused = true }
      .onChange(of: focused) { _, isFocused in
        if !isFocused { commit(false) }
      }
      .accessibilityIdentifier("browser.design.textMark")
  }
}
