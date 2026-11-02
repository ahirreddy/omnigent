import SwiftUI

/// The CLI transcript style: the transcript, the composer, the settings section and the screen.
enum CLICatalog {
  private static var transcriptStates: [CatalogState] {
    let samples = CLIPreviewScenario.allCases.map { scenario in
      CatalogState(scenario.rawValue, scenario.title) { context in
        AnyView(CLIPreviews.transcript(scenario, theme: context.preferences.theme))
      }
    }
    let renderings = OutputRendering.allCases.filter { $0 != .styled }.map { rendering in
      CatalogState("markdown-\(rendering.rawValue)", "Markdown, \(rendering.title)") { context in
        AnyView(
          CLIPreviews.transcript(.markdown, rendering: rendering, theme: context.preferences.theme))
      }
    }
    return samples + renderings
  }

  static var entries: [CatalogEntry] {
    [
      .component(
        .transcript, "cli-transcript", "CLI Transcript",
        summary: "The transcript in CLI style, in each sample and output rendering.",
        systemImage: "terminal", canvas: .fixed(width: 900, height: 760),
        keywords: ["cli", "terminal style", "plain", "rich", "codex"],
        states: transcriptStates),
      .component(
        .composer, "cli-composer", "CLI Composer",
        summary: "The CLI prompt with its status line.",
        systemImage: "chevron.right.square", canvas: .column(width: 900),
        keywords: ["cli", "prompt", "status line"],
        states: CLIPreviewScenario.allCases.map { scenario in
          CatalogState(scenario.rawValue, scenario.title) { context in
            AnyView(CLIPreviews.composer(scenario, theme: context.preferences.theme))
          }
        }),
      .component(
        .settings, "transcript-settings", "Transcript Settings",
        summary: "Settings > Appearance > Transcript: style, rendering, width and font size.",
        systemImage: "textformat.alt", canvas: .fixed(width: 560, height: 420),
        keywords: ["cli", "chat", "style", "font size"],
        states: [
          CatalogState("section", "Section", note: "Writes to the gallery's scratch defaults.") {
            Form {
              TranscriptSettingsSection(
                preferences: TranscriptPreferences(defaults: CatalogSettings.scratchDefaults))
            }
            .formStyle(.grouped)
          }
        ]),
      .page(
        .transcript, "cli-conversation", "Conversation in CLI Style",
        summary: "The session page with the CLI transcript and prompt.",
        systemImage: "terminal.fill", keywords: ["cli", "terminal style"],
        states: CLIPreviewScenario.allCases.map { scenario in
          CatalogState(scenario.rawValue, scenario.title) { context in
            AnyView(
              CLIPreviews.screen(
                scenario, width: context.screen.layoutWidth == .compact ? .edgeToEdge : .reading,
                theme: context.preferences.theme))
          }
        },
        live: { _ in AnyView(CLIPlayground()) }),
    ]
  }
}
