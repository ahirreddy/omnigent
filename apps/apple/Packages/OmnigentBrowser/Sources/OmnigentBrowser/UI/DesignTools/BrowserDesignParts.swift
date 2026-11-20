internal import SwiftUI

/// The toolbar's Annotate and Draw toggles.
struct BrowserDesignToolButtons: View {
  let tools: BrowserDesignTools

  var body: some View {
    ForEach(BrowserDesignTool.allCases, id: \.self) { tool in
      Toggle(
        isOn: Binding(get: { tools.tool == tool }, set: { _ in tools.toggle(tool) })
      ) {
        Label(tool.title, systemImage: tool.systemImage)
      }
      .toggleStyle(.button)
      .help(tool.help)
      .accessibilityIdentifier("browser.design.\(tool.rawValue)")
    }
  }
}

extension BrowserDesignTool {
  /// The toolbar button's tooltip.
  var help: String {
    switch self {
    case .annotate: "Annotate: pick an element on the page and say what should change"
    case .draw: "Draw: mark up the page and send a screenshot to the agent"
    }
  }
}

/// The outline round a hovered or picked element, with its name.
struct BrowserDesignOutline: View {
  let hit: BrowserDesignHit
  let size: CGSize
  let picked: Bool

  var body: some View {
    let rect = hit.rect(in: size)
    ZStack(alignment: .topLeading) {
      RoundedRectangle(cornerRadius: 4)
        .fill(Color.accentColor.opacity(picked ? 0.06 : 0.12))
        .strokeBorder(Color.accentColor, lineWidth: 2)
        .frame(width: max(rect.width, 2), height: max(rect.height, 2))
        .offset(x: rect.minX, y: rect.minY)
      Text(hit.element.shortName)
        .font(.caption.weight(.medium))
        .lineLimit(1)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(.white)
        .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 4))
        .frame(maxWidth: 260, alignment: .leading)
        .fixedSize()
        .offset(x: rect.minX, y: rect.minY >= 24 ? rect.minY - 22 : rect.minY + 4)
    }
    .frame(width: size.width, height: size.height, alignment: .topLeading)
    .animation(.easeOut(duration: 0.1), value: rect)
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("\(picked ? "Picked" : "Pointing at") \(hit.element.shortName)")
    .accessibilityIdentifier("browser.design.outline")
  }
}

/// Annotate's bar while nothing is picked.
struct BrowserDesignPickHint: View {
  let close: () -> Void

  var body: some View {
    BrowserDesignBar {
      Label("Pick an element to change", systemImage: BrowserDesignTool.annotate.systemImage)
        .labelStyle(.titleAndIcon)
      Text("esc")
        .font(.caption.monospaced())
        .padding(.horizontal, 5)
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(.secondary.opacity(0.5)))
        .foregroundStyle(.secondary)
        .accessibilityHidden(true)
      Button("Close Annotate", systemImage: "xmark.circle.fill", action: close)
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("browser.design.close")
    }
  }
}

/// A floating bar along the top of the page, in the system's material.
struct BrowserDesignBar<Content: View>: View {
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: 8) { content }
      .font(.callout)
      .padding(.horizontal, 12)
      .padding(.vertical, 6)
      .background(.regularMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(.separator))
      .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
      .fixedSize()
  }
}

/// Draw's dock: the shape, its color, Undo, the note, Send and Close.
struct BrowserDrawDock: View {
  @Bindable var tools: BrowserDesignTools
  let send: () -> Void
  @State private var choosingColor = false

  var body: some View {
    BrowserDesignBar {
      Picker("Shape", selection: $tools.shape) {
        ForEach(BrowserDesignMarkKind.allCases, id: \.self) { kind in
          Label(kind.title, systemImage: kind.systemImage).tag(kind)
        }
      }
      .pickerStyle(.segmented)
      .labelStyle(.iconOnly)
      .labelsHidden()
      .accessibilityIdentifier("browser.design.shape")
      Button {
        choosingColor.toggle()
      } label: {
        BrowserDesignSwatch(color: tools.color)
      }
      .buttonStyle(.borderless)
      .help("Color for \(tools.shape.title)")
      .accessibilityLabel("Color for \(tools.shape.title): \(tools.color.title)")
      .popover(isPresented: $choosingColor, arrowEdge: .bottom) {
        BrowserDesignPalette(selection: $tools.color) { choosingColor = false }
      }
      Button("Undo", systemImage: "arrow.uturn.backward") { tools.undo() }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .disabled(tools.undoBlocked != nil)
        .help("Undo the last mark")
        .accessibilityIdentifier("browser.design.undo")
      TextField("Add a note for the agent", text: $tools.note)
        .textFieldStyle(.roundedBorder)
        .frame(width: 200)
        .disabled(tools.isPreparing)
        .onSubmit { if tools.drawingBlocked == nil { send() } }
        .accessibilityIdentifier("browser.design.note")
      Button(tools.isPreparing ? "Capturing\u{2026}" : "Send to Agent", action: send)
        .buttonStyle(.borderedProminent)
        .disabled(tools.drawingBlocked != nil)
        .help(tools.drawingBlocked ?? "Send the marked-up page to the session's agent")
        .accessibilityIdentifier("browser.design.send")
      Button("Close Draw", systemImage: "xmark.circle.fill") { tools.close() }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .accessibilityIdentifier("browser.design.close")
    }
  }
}

/// A mark color's swatch.
struct BrowserDesignSwatch: View {
  let color: BrowserDesignMarkColor
  var selected = false

  var body: some View {
    Circle()
      .fill(Color(cgColor: color.cgColor))
      .overlay(Circle().strokeBorder(.separator))
      .frame(width: 16, height: 16)
      .padding(3)
      .overlay {
        if selected { Circle().strokeBorder(Color.accentColor, lineWidth: 2) }
      }
  }
}

/// The marks' palette.
struct BrowserDesignPalette: View {
  @Binding var selection: BrowserDesignMarkColor
  let done: () -> Void

  var body: some View {
    HStack(spacing: 4) {
      ForEach(BrowserDesignMarkColor.allCases, id: \.self) { color in
        Button {
          selection = color
          done()
        } label: {
          BrowserDesignSwatch(color: color, selected: color == selection)
        }
        .buttonStyle(.borderless)
        .help(color.title)
        .accessibilityLabel(color.title)
        .accessibilityAddTraits(color == selection ? .isSelected : [])
      }
    }
    .padding(8)
  }
}

/// A notice along the bottom of the page; it goes after a few seconds.
struct BrowserDesignNoticeView: View {
  let notice: BrowserDesignNotice
  let dismiss: () -> Void

  var body: some View {
    Label(
      notice.message,
      systemImage: notice.isError ? "exclamationmark.triangle.fill" : "paperplane.fill"
    )
    .symbolRenderingMode(notice.isError ? .multicolor : .hierarchical)
    .font(.callout)
    .lineLimit(3)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
    .background(.regularMaterial, in: Capsule())
    .overlay(Capsule().strokeBorder(.separator))
    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
    .padding(12)
    .task(id: notice.id) {
      do {
        try await Task.sleep(for: .seconds(notice.isError ? 8 : 5))
      } catch {
        return
      }
      dismiss()
    }
    .accessibilityIdentifier("browser.design.notice")
  }
}
