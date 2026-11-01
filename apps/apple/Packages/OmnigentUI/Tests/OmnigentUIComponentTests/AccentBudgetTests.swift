#if os(macOS)
  import AppKit
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  /// Emphasis discipline, checked on rendered screens: the accent marks only the single primary
  /// action on a screen, and the brand accent only "needs you". Each screen renders with a probe
  /// theme whose accent and brand accent are colors nothing else uses, and the solid areas of
  /// each are counted. Soft tints such as the row selection stay far below the threshold.
  @Suite("Accent budget", .serialized)
  struct AccentBudgetTests {
    /// Pure green for the accent, pure magenta for the brand accent.
    static let probe: OmnigentTheme = {
      let light = ThemePalette(
        accent: Color(hex: 0x00FF00), brandAccent: Color(hex: 0xFF00FF), link: Color(hex: 0x1967B5),
        selection: Color(hex: 0x00FF00, alpha: 0.12), canvas: nil)
      var dark = light
      dark.canvas = Color(hex: 0x0E0B19)
      return OmnigentTheme(id: "accent-probe", name: "Accent probe", light: light, dark: dark)
    }()

    enum Probe {
      case accent
      case brand

      /// A saturated pixel within 15 degrees of the probe hue. Control bezels shift the hue a
      /// little; soft tints and the status colors stay out.
      func matches(_ color: NSColor) -> Bool {
        guard color.saturationComponent > 0.5, color.brightnessComponent > 0.4 else {
          return false
        }
        let target: CGFloat = self == .accent ? 120 : 300
        let distance = abs(color.hueComponent * 360 - target)
        return min(distance, 360 - distance) < 15
      }
    }

    /// Connected areas of probe color: pixels are bucketed into cells and touching cells merge,
    /// so a button or a word counts once.
    static func regions(_ probe: Probe, in rendered: RenderSupport.Rendered, cell: Int = 12)
      -> Int
    {
      let image = rendered.image
      let columns = (image.pixelsWide + cell - 1) / cell
      let rows = (image.pixelsHigh + cell - 1) / cell
      var hits = [Int](repeating: 0, count: columns * rows)
      for pixelRow in stride(from: 0, to: image.pixelsHigh, by: 2) {
        for pixelColumn in stride(from: 0, to: image.pixelsWide, by: 2) {
          guard let color = image.colorAt(x: pixelColumn, y: pixelRow)?.usingColorSpace(.sRGB),
            probe.matches(color)
          else { continue }
          hits[(pixelRow / cell) * columns + pixelColumn / cell] += 1
        }
      }
      var marked = hits.map { $0 >= 3 }
      var count = 0
      for start in marked.indices where marked[start] {
        count += 1
        var stack = [start]
        marked[start] = false
        while let index = stack.popLast() {
          let row = index / columns
          let column = index % columns
          for (dRow, dColumn) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
            let nextRow = row + dRow
            let nextColumn = column + dColumn
            guard (0..<rows).contains(nextRow), (0..<columns).contains(nextColumn) else {
              continue
            }
            let next = nextRow * columns + nextColumn
            if marked[next] {
              marked[next] = false
              stack.append(next)
            }
          }
        }
      }
      return count
    }

    nonisolated struct Screen: CustomTestStringConvertible, Sendable {
      let name: String
      let size: CGSize
      /// The solid accent areas expected: the one primary action, or none.
      let accent: Int
      let make: @MainActor @Sendable () -> AnyView

      var testDescription: String { name }
    }

    nonisolated static let screens: [Screen] = [
      Screen(name: "sidebar", size: CGSize(width: 300, height: 860), accent: 0) {
        AnyView(GallerySessionList())
      },
      Screen(name: "header", size: CGSize(width: 900, height: 0), accent: 0) {
        AnyView(SessionHeaderView(state: PreviewData.shellConversation))
      },
      Screen(name: "composer-running-empty", size: CGSize(width: 760, height: 0), accent: 0) {
        AnyView(
          ComposerView(
            draft: .constant(""), state: PreviewData.sessionComposer,
            actions: ComposerActions(send: {})))
      },
      Screen(name: "composer-draft", size: CGSize(width: 760, height: 0), accent: 1) {
        AnyView(
          ComposerView(
            draft: .constant("Add a test for the expiry path"),
            state: PreviewData.idleSessionComposer, actions: ComposerActions(send: {})))
      },
      Screen(name: "new-session", size: CGSize(width: 900, height: 700), accent: 1) {
        AnyView(
          NewSessionPage(
            draft: .constant("Fix the flaky test"), composer: PreviewData.startComposer,
            actions: ComposerActions(send: {})))
      },
      Screen(name: "approval-card", size: CGSize(width: 720, height: 0), accent: 1) {
        AnyView(DecisionCardView(card: PreviewData.codexCommand, respond: { _ in }).padding(20))
      },
      Screen(name: "server-settings", size: CGSize(width: 900, height: 600), accent: 0) {
        AnyView(
          ServerSettingsView(
            state: PreviewData.serverSettings, selectedServer: .constant("dbx"),
            actions: ServerSettingsActions()))
      },
      Screen(name: "transcript-running-tool", size: CGSize(width: 760, height: 900), accent: 0) {
        AnyView(
          TranscriptView(
            state: runningTranscript, actions: ConversationActions(openSession: { _ in })))
      },
      // The expanded request's Approve is the one primary action.
      Screen(name: "inbox", size: CGSize(width: 900, height: 700), accent: 1) {
        AnyView(inbox)
      },
    ]

    /// A running turn: a tool still running, a slash command, a side question and the
    /// "continued in a new session" banner, none of which is an action.
    @MainActor static var runningTranscript: ConversationViewState {
      let kept: Set<String> = ["item_cmd", "item_side"]
      var rows = PreviewData.rows.filter { kept.contains($0.id) }
      rows.append(
        PreviewData.tool(
          "item_running", kind: .toolCall, title: "exec_command",
          summary: "cargo test -p omnigent-core auth", details: [], callId: "call_running",
          status: "in_progress", isStreaming: true))
      return ConversationViewState(
        revision: 1, header: PreviewData.header, rows: rows,
        sections: [
          EventSection(
            id: "superseded", title: "Continued in a new session",
            summary: "This session was compacted into a new one.", sessionId: "sess_next")
        ])
    }

    @MainActor static var inbox: some View {
      InboxView(
        state: PreviewData.inbox,
        actions: InboxActions(open: { _ in }, markRead: { _ in }, respond: { _, _ in }))
    }

    @Test("the accent marks exactly the one primary action, or nothing", arguments: screens)
    func accentBudget(screen: Screen) throws {
      for scheme in [ColorScheme.light, .dark] {
        let rendered = try RenderSupport.render(
          screen.make().omnigentTheme(Self.probe).themeCanvas(), width: screen.size.width,
          height: screen.size.height > 0 ? screen.size.height : nil, scheme: scheme,
          layout: .regular)
        try RenderSupport.write(rendered, name: "accent-\(screen.name)-\(scheme)")
        let accent = Self.regions(.accent, in: rendered)
        #expect(
          accent == screen.accent,
          "\(screen.name) \(scheme): \(accent) accent areas, expected \(screen.accent)")
      }
    }

    @Test("the sidebar's brand accent marks only sessions that need you")
    func brandOnlyForNeedsYou() throws {
      let needsYou = PreviewData.sidebar.list.sessions.filter { $0.attention == .needsYou }
      let rendered = try RenderSupport.render(
        GallerySessionList().omnigentTheme(Self.probe).themeCanvas(), width: 300, height: 860,
        scheme: .light, layout: .regular)
      let brand = Self.regions(.brand, in: rendered)
      #expect(brand >= min(needsYou.count, 1), "the Needs you signal should show")
      // The Needs you rows, plus the quick filter's count.
      #expect(brand <= needsYou.count + 1, "\(brand) brand-accent areas")
    }

    @Test("the Inbox's brand accent marks only what needs you")
    func inboxBrandOnlyForNeedsYou() throws {
      let needsYou = PreviewData.inbox.items.filter(\.isUnresolved).count
      for scheme in [ColorScheme.light, .dark] {
        let rendered = try RenderSupport.render(
          Self.inbox.omnigentTheme(Self.probe).themeCanvas(), width: 900, height: 700,
          scheme: scheme, layout: .regular)
        let brand = Self.regions(.brand, in: rendered)
        #expect(brand >= 1, "the Needs you signal should show")
        // Each request's "Needs you" label, plus the header's count.
        #expect(brand <= needsYou + 1, "\(scheme): \(brand) brand-accent areas")
      }
    }

    @Test("selection and focus are softened, never the accent itself")
    func softRoles() {
      var environment = EnvironmentValues()
      environment.omnigentTheme = Self.probe
      for scheme in [ColorScheme.light, .dark] {
        environment.colorScheme = scheme
        let selection = ThemeColor.rowSelection.resolve(in: environment).resolve(in: environment)
        #expect(selection.opacity < 0.2)
        let focus = ThemeColor.focus.resolve(in: environment).resolve(in: environment)
        #expect(!(focus.green > 0.8 && focus.red < 0.3), "focus must not use the accent")
      }
    }
  }
#endif
