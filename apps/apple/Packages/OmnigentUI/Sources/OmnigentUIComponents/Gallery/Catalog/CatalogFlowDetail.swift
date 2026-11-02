import SwiftUI

/// A flow: the step list beside the current step's canvas, with Back and Next.
struct CatalogFlowDetail: View {
  let entry: CatalogEntry
  @Bindable var settings: CatalogSettings
  @Binding var stepID: String?
  @Environment(\.horizontalSizeClass) private var sizeClass

  private var navigator: CatalogFlowNavigator {
    CatalogFlowNavigator(stepIDs: entry.states.map(\.id), current: stepID)
  }

  private var step: CatalogState? { entry.state(navigator.currentID) }

  var body: some View {
    HStack(spacing: 0) {
      if sizeClass != .compact {
        steps.frame(width: 260)
        Divider()
      }
      VStack(spacing: 0) {
        if let step {
          CatalogStepCanvas(entry: entry, step: step, settings: settings)
            .id(step.id)
        }
        Divider()
        controls
      }
    }
  }

  private var steps: some View {
    List(selection: $stepID) {
      ForEach(Array(entry.states.enumerated()), id: \.element.id) { index, step in
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.small) {
          Text("\(index + 1)")
            .font(.callout.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 20, alignment: .trailing)
          VStack(alignment: .leading, spacing: Theme.Spacing.tiny) {
            Text(step.title).font(.callout.weight(.medium))
            if let note = step.note {
              Text(note).font(.caption).foregroundStyle(.secondary)
            }
          }
        }
        .padding(.leading, step.branchesFrom == nil ? 0 : Theme.Spacing.large)
        .tag(step.id)
        .accessibilityIdentifier("gallery-step-\(step.id)")
      }
    }
  }

  private var controls: some View {
    HStack(spacing: Theme.Spacing.medium) {
      Button {
        move { $0.back() }
      } label: {
        Label("Back", systemImage: "chevron.backward")
      }
      .keyboardShortcut("[", modifiers: .command)
      .disabled(!navigator.canGoBack)
      .accessibilityIdentifier("gallery-flow-back")
      Spacer()
      VStack(spacing: Theme.Spacing.tiny) {
        Text(navigator.position).font(.callout.weight(.medium))
        if let step {
          Text(step.title).font(.caption).foregroundStyle(.secondary)
        }
      }
      .accessibilityElement(children: .combine)
      .accessibilityIdentifier("gallery-flow-position")
      Spacer()
      Button {
        move { $0.next() }
      } label: {
        Label("Next", systemImage: "chevron.forward")
      }
      .keyboardShortcut("]", modifiers: .command)
      .disabled(!navigator.canGoNext)
      .primaryActionStyle()
      .accessibilityIdentifier("gallery-flow-next")
    }
    .padding(Theme.Spacing.medium)
  }

  private func move(_ change: (inout CatalogFlowNavigator) -> Void) {
    var navigator = navigator
    change(&navigator)
    stepID = navigator.currentID
  }
}

/// One step's canvases, in device frames scaled to fit.
private struct CatalogStepCanvas: View {
  let entry: CatalogEntry
  let step: CatalogState
  @Bindable var settings: CatalogSettings

  private var screen: CatalogScreen { settings.screen(for: entry.canvas) }
  private var layout: CatalogLayout {
    CatalogLayout(canvas: entry.canvas, screen: screen, framed: settings.showsFrame)
  }

  var body: some View {
    GeometryReader { proxy in
      let scale = scale(for: proxy.size)
      ScrollView([.vertical, .horizontal]) {
        HStack(alignment: .top, spacing: Theme.Spacing.extraLarge) {
          ForEach(settings.appearance.schemes, id: \.self) { scheme in
            CatalogPageFrame(
              layout: layout,
              label: "\(screen.title) \u{00B7} \(scheme == .dark ? "Dark" : "Light")"
            ) {
              CatalogCanvasView(
                state: step, context: settings.context(screen),
                traits: settings.traits(scheme, screen: screen), layout: layout
              )
              .id(CatalogCanvasID(state: step.id, scheme: scheme, layout: layout))
              .scaleEffect(scale, anchor: .topLeading)
              .frame(
                width: layout.width * scale, height: (layout.height ?? 0) * scale,
                alignment: .topLeading)
            }
          }
        }
        .padding(Theme.Spacing.extraLarge)
        .frame(minWidth: proxy.size.width, minHeight: proxy.size.height, alignment: .topLeading)
      }
    }
  }

  private func scale(for available: CGSize) -> CGFloat {
    settings.fitsPages
      ? layout.fitScale(in: available, columns: settings.appearance.schemes.count) : 1
  }
}
