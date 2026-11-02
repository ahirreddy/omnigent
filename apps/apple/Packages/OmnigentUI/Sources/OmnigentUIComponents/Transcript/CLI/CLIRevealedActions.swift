import SwiftUI

/// One control a CLI block reveals on hover or focus, also offered in its context menu and as a
/// VoiceOver action.
struct CLIAction: Identifiable {
  let title: String
  let systemImage: String
  /// The button's accessibility identifier.
  let identifier: String
  let perform: @MainActor () -> Void

  var id: String { identifier }
}

/// The CLI's floating action cluster: a small surface centered on the block's top edge at the
/// trailing side, so revealing it never moves text. Rendered only while
/// ``EnvironmentValues/messageActionsRevealed`` is on, the same switch the chat's
/// ``MessageActionRow`` uses.
struct CLIActionCluster<Content: View>: View {
  @ViewBuilder let content: Content
  @Environment(\.messageActionsRevealed) private var revealed
  @Environment(\.cliPalette) private var palette

  var body: some View {
    if revealed {
      HStack(spacing: Theme.Spacing.tiny) { content }
        .buttonStyle(.borderless)
        .labelStyle(.iconOnly)
        .foregroundStyle(palette.body.color)
        .padding(.horizontal, Theme.Spacing.extraSmall)
        .background(palette.composerBand.color, in: RoundedRectangle(cornerRadius: 6))
        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(palette.rule.color) }
        .alignmentGuide(.top) { $0[VerticalAlignment.center] }
        .transition(.opacity)
    }
  }
}

/// Reveals a non-message CLI block's ``CLIActionCluster`` on hover or keyboard focus (Mac), and
/// offers the same actions in the context menu (long press on touch) and to VoiceOver. A
/// message uses ``View/messageActionsHost(row:actions:pinned:showsOnTouch:focus:)`` instead.
private struct CLIActionsHost: ViewModifier {
  let actions: [CLIAction]
  @State private var isHovered = false
  @FocusState private var isFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private var revealed: Bool {
    #if os(macOS)
      isHovered || isFocused
    #else
      false
    #endif
  }

  func body(content: Content) -> some View {
    if actions.isEmpty {
      content
    } else {
      content
        .overlay(alignment: .topTrailing) {
          CLIActionCluster {
            ForEach(actions) { action in
              Button(action.title, systemImage: action.systemImage, action: action.perform)
                .frame(minWidth: Theme.Control.target, minHeight: Theme.Control.target)
                .contentShape(Rectangle())
                .focused($isFocused)
                .help(action.title)
                .accessibilityIdentifier(action.identifier)
            }
          }
        }
        #if os(macOS)
          .focusable(interactions: .activate)
          .focused($isFocused)
        #endif
        .onHover { isHovered = $0 }
        .environment(\.messageActionsRevealed, revealed)
        .animation(reduceMotion ? nil : Theme.Motion.feedback, value: revealed)
        .contextMenu {
          ForEach(actions) { action in
            Button(action.title, systemImage: action.systemImage, action: action.perform)
          }
        }
        .accessibilityActions {
          ForEach(actions) { action in
            Button(action.title, action: action.perform)
          }
        }
    }
  }
}

extension View {
  /// Hosts a CLI block's hover-revealed actions.
  /// - Parameter actions: The actions, in cluster order.
  /// - Returns: The host.
  func cliActions(_ actions: [CLIAction]) -> some View {
    modifier(CLIActionsHost(actions: actions))
  }

  /// Hangs `marker` in the gutter before the block's first line, so text stays on the column.
  func cliMarker(_ marker: some View) -> some View {
    modifier(CLIMarkerModifier(marker: marker))
  }
}

private struct CLIMarkerModifier<Marker: View>: ViewModifier {
  let marker: Marker
  private let size = CLIFontSize()

  func body(content: Content) -> some View {
    content.overlay(alignment: .topLeading) {
      marker
        .cliFont()
        .frame(width: size.character * CGFloat(CLIMetrics.markerColumns), alignment: .leading)
        .offset(x: -size.character * CGFloat(CLIMetrics.markerColumns))
        .accessibilityHidden(true)
    }
  }
}
