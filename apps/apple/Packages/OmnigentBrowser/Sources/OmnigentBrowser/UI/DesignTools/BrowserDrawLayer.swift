#if os(macOS)
  internal import AppKit
  internal import SwiftUI

  /// Draw: pen, rectangle, arrow and text marks over the page, the dock with the shape, color,
  /// Undo, the note and Send.
  struct BrowserDrawLayer: View {
    @Bindable var tools: BrowserDesignTools
    let size: CGSize
    let page: BrowserDesignPageViews
    @State private var textDraft: TextDraft?

    /// Words being typed for a text mark, at their point.
    struct TextDraft: Equatable {
      var point: CGPoint
      var text = ""
    }

    var body: some View {
      ZStack(alignment: .topLeading) {
        BrowserDesignInput(
          handlers: handlers, cursor: tools.isPreparing ? .arrow : .crosshair, scrolls: false,
          page: page.view, pageKeyboard: page.keyboard)
        Canvas { context, _ in
          let marks = tools.marks + (tools.drawing.map { [$0] } ?? [])
          context.withCGContext { BrowserDesignMarkDrawing.draw(marks, in: $0) }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        if let textDraft, !tools.isPreparing {
          BrowserDrawTextField(
            draft: Binding(get: { textDraft }, set: { self.textDraft = $0 }),
            color: tools.colors[.text] ?? .red, commit: commitText, cancel: { self.textDraft = nil }
          )
        }
        BrowserDrawDock(tools: tools, send: send)
          .frame(maxWidth: .infinity)
          .padding(.top, 12)
          .padding(.horizontal, 12)
      }
    }

    private var handlers: BrowserDesignInputHandlers {
      BrowserDesignInputHandlers(
        press: { point in
          guard tools.shape == .text else {
            tools.beginMark(at: point)
            return
          }
          commitText(andSend: false)
          if !tools.isPreparing { textDraft = TextDraft(point: point) }
        },
        drag: { tools.continueMark(to: $0) },
        release: { tools.endMark(at: $0) },
        escape: {
          if textDraft != nil { textDraft = nil } else { tools.close() }
        })
    }

    /// Puts the words being typed on the page; with `andSend`, then sends.
    private func commitText(andSend: Bool) {
      if let textDraft {
        tools.addText(textDraft.text, at: textDraft.point)
        self.textDraft = nil
      }
      if andSend { send() }
    }

    private func send() {
      // Words still being typed go on the page first.
      if textDraft != nil {
        commitText(andSend: false)
      }
      let size = size
      Task { await tools.sendDrawing(viewSize: size) }
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
        .onExitCommand(perform: cancel)
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
#endif
