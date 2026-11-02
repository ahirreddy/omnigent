import SwiftUI

/// Design system: themes, color roles, surfaces, type, pills and glyphs.
enum DesignSystemCatalog {
  static var entries: [CatalogEntry] {
    [
      .component(
        .designSystem, "themes", "Theme Palettes",
        summary: "Every built-in palette and Custom, light and dark side by side.",
        systemImage: "paintpalette", canvas: .column(width: 1_000),
        keywords: ["palette", "colors"],
        states: [CatalogState("all", "All palettes") { ThemeGalleryView().frame(height: 1_100) }]),
      .component(
        .designSystem, "color-roles", "Color Roles",
        summary: "The theme's semantic roles: one primary action, needs-you, links and status.",
        systemImage: "swatchpalette", canvas: .column(width: 720),
        keywords: ["accent", "brand", "status"],
        states: [
          CatalogState("roles", "Roles", note: "Pink is for needs-you and the primary action only.")
          {
            ColorRoleSheet()
          }
        ]),
      .component(
        .designSystem, "theme-settings", "Theme Settings",
        summary: "The Appearance settings pane, editing the gallery's own palette.",
        systemImage: "slider.horizontal.3", canvas: .fixed(width: 560, height: 720),
        keywords: ["appearance", "custom"],
        states: [
          CatalogState("pane", "Pane", note: "Changes here restyle the whole gallery.") { context in
            AnyView(ThemeSettingsView(preferences: context.preferences))
          }
        ]),
      .component(
        .designSystem, "surfaces", "Card Surfaces",
        summary: "The opaque card with its semantic border and status washes.",
        systemImage: "rectangle.on.rectangle", canvas: .column(width: 640),
        keywords: ["card", "border"],
        states: [CatalogState("tints", "Tints") { SurfaceSheet() }]),
      .component(
        .designSystem, "type", "Type and Reading Column",
        summary: "Prose style and the transcript's readable column.",
        systemImage: "textformat.size", canvas: .column(width: 900),
        keywords: ["typography", "font"],
        states: [
          CatalogState("prose", "Prose") { TypeSheet() },
          CatalogState("long", "Long words", note: "Unbroken paths and URLs must wrap.") {
            TypeSheet(text: CatalogSamples.longText)
          },
        ]),
      .component(
        .designSystem, "buttons", "Buttons",
        summary: "The single primary action, secondary buttons and copy.",
        systemImage: "button.horizontal", canvas: .column(width: 560),
        keywords: ["primary", "copy"],
        states: [
          CatalogState("enabled", "Enabled") { ButtonSheet(isEnabled: true) },
          CatalogState("disabled", "Disabled") { ButtonSheet(isEnabled: false) },
        ]),
      .component(
        .designSystem, "pills", "Pills and Indicators",
        summary: "Status pills, the live dot and the typing indicator.",
        systemImage: "capsule", canvas: .column(width: 560), keywords: ["status", "badge", "live"],
        states: [CatalogState("all", "All") { PillSheet() }]),
      .component(
        .designSystem, "harness-glyphs", "Harness Glyphs",
        summary: "Each harness's glyph and label, plus an unknown harness.",
        systemImage: "seal", canvas: .column(width: 560), keywords: ["codex", "claude", "agent"],
        states: [CatalogState("all", "All") { HarnessSheet() }]),
      .component(
        .designSystem, "otto", "Otto",
        summary: "The mascot, idle, looking around and working.",
        systemImage: "face.smiling", canvas: .column(width: 420), keywords: ["mascot"],
        states: [
          CatalogState("idle", "Idle") { OttoView().padding(Theme.Spacing.extraLarge) },
          CatalogState("gaze", "Looking") {
            OttoView(gaze: CGSize(width: 0.6, height: -0.4)).padding(Theme.Spacing.extraLarge)
          },
          CatalogState("working", "Working") {
            OttoView(isWorking: true).padding(Theme.Spacing.extraLarge)
          },
        ]),
    ]
  }
}

/// Long sample text and other strings shared by catalog states.
enum CatalogSamples {
  static let longText = """
    Updated apps/apple/Packages/OmnigentUI/Sources/OmnigentUIComponents/Gallery/Catalog/\
    CatalogDesignSystem.swift and https://omnigent.example.com/c/sess_7Hq2?message=resp_0123456789abcdef \
    so every unbroken path wraps instead of widening the column. Supercalifragilisticexpialidocious \
    identifiers like refreshTokenExpiryWindowSecondsUntilForcedReauthentication must wrap too.
    """
}

private struct ColorRoleSheet: View {
  private let roles: [(String, ThemeColor)] = [
    ("Accent: the primary action", Theme.accent),
    ("Brand accent: needs you", Theme.brandAccent),
    ("Link", Theme.link),
    ("Running", Theme.running),
    ("Success", Theme.success),
    ("Warning", Theme.warning),
    ("Failure", Theme.failure),
    ("Info and unread", Theme.info),
    ("Selection", Theme.selection),
    ("User bubble", Theme.userBubble),
    ("Diff added", ThemeColor.diffAdded),
    ("Diff removed", ThemeColor.diffRemoved),
  ]

  var body: some View {
    CatalogStack {
      LazyVGrid(
        columns: [GridItem(.adaptive(minimum: 200), spacing: Theme.Spacing.medium)],
        alignment: .leading, spacing: Theme.Spacing.medium
      ) {
        ForEach(roles, id: \.0) { name, color in
          HStack(spacing: Theme.Spacing.small) {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
              .fill(color)
              .frame(width: 36, height: 36)
              .overlay {
                RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                  .strokeBorder(.separator)
              }
            Text(name).font(.callout)
          }
        }
      }
    }
    .themeCanvas()
  }
}

private struct SurfaceSheet: View {
  var body: some View {
    CatalogStack {
      ForEach(
        [
          ("Plain", nil), ("Needs you", Theme.brandAccent), ("Failure", Theme.failure),
          ("Warning", Theme.warning), ("Success", Theme.success),
        ] as [(String, ThemeColor?)], id: \.0
      ) { title, tint in
        VStack(alignment: .leading, spacing: Theme.Spacing.extraSmall) {
          Text(title).font(Theme.Typography.label)
          Text("A card surface with \(title.lowercased()) emphasis.")
            .font(.callout).foregroundStyle(.secondary)
        }
        .padding(Theme.Spacing.card)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface(tint: tint, stroke: tint?.opacity(0.4))
      }
    }
    .themeCanvas()
  }
}

private struct TypeSheet: View {
  var text = PreviewData.assistantMarkdown

  var body: some View {
    CatalogStack {
      Text("What should we work on?").font(Theme.Typography.title)
      Text("Section label").font(Theme.Typography.section).foregroundStyle(.secondary)
      TypeRampTable().readingProseStyle()
      MarkdownView(text).readingColumn()
    }
    .themeCanvas()
  }
}

/// The reading ramp itself: each role at its size, with its size and line height.
private struct TypeRampTable: View {
  @Environment(\.typeRamp) private var ramp

  var body: some View {
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: Theme.Spacing.large) {
      ForEach(1...4, id: \.self) { level in
        row(
          "Heading \(level)", size: ramp.heading(level), lineHeight: ramp.headingLineHeight(level),
          font: .system(size: ramp.heading(level), weight: .semibold))
      }
      row(
        "Body", size: ramp.body, lineHeight: ramp.bodyLineHeight, font: .system(size: ramp.body))
      row(
        "Code", size: ramp.code, lineHeight: ramp.codeLineHeight,
        font: .system(size: ramp.code, design: .monospaced))
    }
  }

  private func row(_ name: String, size: CGFloat, lineHeight: CGFloat, font: Font) -> some View {
    GridRow {
      Text(name).font(font)
      Text(verbatim: "\(size.formatted()) / \(lineHeight.formatted()) pt")
        .font(Theme.Typography.section)
        .foregroundStyle(Theme.mutedText)
        .monospacedDigit()
    }
  }
}

private struct ButtonSheet: View {
  let isEnabled: Bool

  var body: some View {
    CatalogStack {
      HStack(spacing: Theme.Spacing.medium) {
        Button("Send") {}.primaryActionStyle()
        Button("Share") {}.buttonStyle(.bordered)
        Button("Cancel", role: .cancel) {}
        Button("Delete", role: .destructive) {}.buttonStyle(.bordered)
      }
      HStack(spacing: Theme.Spacing.medium) {
        Button("Approve") {}.primaryActionStyle().controlSize(.large)
        Button("Reject") {}.buttonStyle(.bordered).controlSize(.large)
        CopyButton(text: "cargo test -p omnigent-core")
      }
    }
    .disabled(!isEnabled)
    .themeCanvas()
  }
}

private struct PillSheet: View {
  var body: some View {
    CatalogStack {
      CatalogSample("Pills") {
        FlowLayout {
          Pill(text: "Needs you", systemImage: "hand.raised", tint: Theme.brandAccent)
          Pill(text: "Running", systemImage: "circle.dotted", tint: Theme.running)
          Pill(text: "Failed", systemImage: "exclamationmark.triangle", tint: Theme.failure)
          Pill(text: "Done", systemImage: "checkmark", tint: Theme.success)
          Pill(text: "Read only", systemImage: "eye")
          Pill(text: "A long pill label that should truncate or wrap gracefully")
        }
      }
      CatalogSample("Live and typing") {
        HStack(spacing: Theme.Spacing.large) {
          LiveIndicator()
          LiveIndicator(color: Theme.brandAccent)
          TypingIndicator()
        }
      }
    }
    .themeCanvas()
  }
}

private struct HarnessSheet: View {
  private let harnesses = [
    "codex", "claude", "claude-sdk", "cursor", "antigravity", "gemini", "pi", "openai-agents",
    "something-new",
  ]

  var body: some View {
    CatalogStack(spacing: Theme.Spacing.medium) {
      ForEach(harnesses, id: \.self) { harness in
        HStack(spacing: Theme.Spacing.small) {
          HarnessGlyph(harness: harness, size: 24)
          Text(HarnessAppearance(harness: harness).label)
          Spacer()
          Text(harness).font(.caption.monospaced()).foregroundStyle(.secondary)
        }
      }
    }
    .themeCanvas()
  }
}
