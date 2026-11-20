public import SwiftUI

/// A session's Terminal view, split into panes by a ``TerminalSplitState`` or showing the
/// agent's pane alone. Panes stay one flat list keyed by pane, so a split never rebuilds a live
/// terminal. Unfocused panes dim, as a Mac terminal's splits do.
public struct TerminalSplitView<Pane: View>: View {
  private let state: TerminalSplitState?
  private let resize: @MainActor ([Int], Double) -> Void
  private let pane: (TerminalPaneKey) -> Pane
  @State private var drag: Drag?
  @Environment(\.colorScheme) private var colorScheme

  private struct Drag: Equatable {
    var path: [Int]
    var ratio: Double
  }

  /// Creates the view.
  /// - Parameters:
  ///   - state: The split; `nil` shows the agent's pane alone.
  ///   - resize: Saves a divider's new ratio when a drag ends or an adjustment steps it.
  ///   - pane: A pane's content.
  public init(
    state: TerminalSplitState?, resize: @escaping @MainActor ([Int], Double) -> Void,
    @ViewBuilder pane: @escaping (TerminalPaneKey) -> Pane
  ) {
    self.state = state
    self.resize = resize
    self.pane = pane
  }

  private static var space: String { "terminal-split" }

  /// The panes and their dividers.
  public var body: some View {
    GeometryReader { proxy in
      let geometry = layout.geometry(in: CGRect(origin: .zero, size: proxy.size))
      ZStack(alignment: .topLeading) {
        ForEach(geometry.panes, id: \.key) { placed in
          pane(placed.key)
            .overlay {
              if let state, placed.key != state.focused { unfocusedFill.allowsHitTesting(false) }
            }
            .accessibilityIdentifier(Self.identifier(placed.key))
            .frame(width: placed.frame.width, height: placed.frame.height)
            .position(x: placed.frame.midX, y: placed.frame.midY)
        }
        if state != nil {
          ForEach(geometry.dividers, id: \.path) { divider in
            TerminalSplitDivider(
              divider: divider,
              drag: { drag = Drag(path: divider.path, ratio: $0) },
              commit: { ratio in
                drag = nil
                resize(divider.path, ratio)
              })
          }
        }
      }
      .coordinateSpace(.named(Self.space))
    }
    .onChange(of: state) { drag = nil }
  }

  /// The tree shown: the saved one with a divider's drag applied, or the agent's pane alone.
  private var layout: TerminalSplitLayout {
    guard let state else { return .pane(.agent) }
    guard let drag else { return state.layout }
    return state.layout.resizing(at: drag.path, to: drag.ratio)
  }

  /// The terminal's own background over an unfocused pane, as Ghostty's unfocused splits.
  private var unfocusedFill: some View {
    Color(white: colorScheme == .dark ? 0.04 : 1).opacity(0.35)
  }

  static func identifier(_ key: TerminalPaneKey) -> String {
    switch key {
    case .agent: "terminal-pane-agent"
    case .shell(let id): "terminal-pane-\(id)"
    }
  }
}

/// The boundary between two panes: a hairline with a wider grip, dragged or adjusted with
/// VoiceOver to resize its split within 25-75%.
private struct TerminalSplitDivider: View {
  let divider: TerminalSplitGeometry.Divider
  let drag: @MainActor (Double) -> Void
  let commit: @MainActor (Double) -> Void

  /// One step of an accessibility adjustment.
  private static let step = 0.05

  private var isColumns: Bool { divider.axis == .columns }

  var body: some View {
    let area = divider.area
    let line = Rectangle().fill(ThemeColor.border)
    return
      line
      .frame(
        width: isColumns ? TabSplitMetrics.divider : area.width,
        height: isColumns ? area.height : TabSplitMetrics.divider
      )
      .overlay {
        Color.clear
          .frame(
            width: isColumns ? TabSplitMetrics.handle : area.width,
            height: isColumns ? area.height : TabSplitMetrics.handle
          )
          .contentShape(Rectangle())
          .gesture(resizing)
          #if os(macOS)
            .pointerStyle(isColumns ? .columnResize : .rowResize)
          #endif
          .accessibilityElement()
          .accessibilityLabel("Resize terminal panes")
          .accessibilityValue("\(Int((divider.ratio * 100).rounded())) percent")
          .accessibilityAdjustableAction { direction in
            commit(divider.ratio + (direction == .increment ? Self.step : -Self.step))
          }
          .accessibilityIdentifier("terminal-split-divider")
      }
      .position(
        x: isColumns ? divider.offset : area.midX, y: isColumns ? area.midY : divider.offset)
  }

  private var resizing: some Gesture {
    DragGesture(minimumDistance: 1, coordinateSpace: .named("terminal-split"))
      .onChanged { drag(divider.ratio(at: $0.location)) }
      .onEnded { commit(divider.ratio(at: $0.location)) }
  }
}
