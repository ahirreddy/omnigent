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

/// Reveals a non-message CLI block's ``CLIActionCluster`` on hover or keyboard focus (Mac); touch
/// has no hover, so a visible ``CLITouchActionsButton`` sits at the block's trailing edge. Both
/// also offer the actions in the context menu and to VoiceOver. A message uses
/// ``View/messageActionsHost(row:actions:pinned:showsOnTouch:focus:)`` instead.
private struct CLIActionsHost: ViewModifier {
  let actions: [CLIAction]
  let trailingClearance: CGFloat
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
        #if !os(macOS)
          .padding(.trailing, CLITouchActionsButton.width)
          .overlay(alignment: .topTrailing) { CLITouchActionsButton(actions: actions) }
        #endif
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
          .padding(.trailing, trailingClearance)
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

/// A block's actions on touch, so they don't hide behind an undisclosed long press: one action
/// is a small button with its symbol (a disclosure chevron, Copy); several open from "More".
struct CLITouchActionsButton: View {
  /// The width the block's text leaves free for the button.
  static let width: CGFloat = 28
  let actions: [CLIAction]
  @Environment(\.cliPalette) private var palette

  var body: some View {
    if actions.count == 1, let action = actions.first {
      Button(action: action.perform) { glyph(action.systemImage, label: action.title) }
        .buttonStyle(.plain)
        .accessibilityIdentifier("\(action.identifier)-touch")
    } else {
      Menu {
        ForEach(actions) { action in
          Button(action.title, systemImage: action.systemImage, action: action.perform)
        }
      } label: {
        glyph("ellipsis", label: "Actions")
      }
      .menuStyle(.button)
      .buttonStyle(.plain)
      .menuIndicator(.hidden)
      .accessibilityIdentifier("\(actions.first?.identifier ?? "cli")-more")
    }
  }

  private func glyph(_ systemImage: String, label: String) -> some View {
    Image(systemName: systemImage)
      .accessibilityLabel(label)
      .font(.footnote.weight(.semibold))
      .foregroundStyle(palette.dim.color)
      .frame(width: Self.width, height: CLIFontSize().line)
      // The glyph stays small; the touch target is the standard size.
      .contentShape(Rectangle().inset(by: -(Theme.Control.target - Self.width) / 2))
  }
}

extension View {
  /// Hosts a CLI block's hover-revealed actions.
  /// - Parameters:
  ///   - actions: The actions, in cluster order.
  ///   - trailingClearance: Room left beside the cluster for a nested block's own cluster.
  /// - Returns: The host.
  func cliActions(_ actions: [CLIAction], trailingClearance: CGFloat = 0) -> some View {
    modifier(CLIActionsHost(actions: actions, trailingClearance: trailingClearance))
  }

  /// Hangs `marker` in the gutter before the block's first line, so text stays on the column.
  func cliMarker(_ marker: some View) -> some View {
    modifier(CLIMarkerModifier(marker: marker))
  }
}

private struct CLIMarkerModifier<Marker: View>: ViewModifier {
  let marker: Marker
  private(set) var size = CLIFontSize()

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
