#if os(macOS)
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("Sub-agent and phone posture rendering", .serialized)
  struct SubagentRenderTests {
    private func group(_ state: ConversationViewState) -> some View {
      ScrollView {
        SubagentGroupView(
          state: state,
          actions: ConversationActions(openSession: { _ in }, respond: { _, _ in })
        )
        .padding(Theme.Spacing.large)
      }
      .themeCanvas()
      .omnigentTheme(.omni)
    }

    @Test("the group, the child's route back and the phone posture render at Mac and phone widths")
    func render() throws {
      for width in [390.0, 760.0] {
        for scheme in [ColorScheme.light, .dark] {
          let layout: LayoutWidth = width < 600 ? .compact : .regular
          let suffix = "\(Int(width))-\(scheme == .dark ? "dark" : "light")"
          let expanded = try RenderSupport.render(
            group(PreviewData.subagentConversation), width: width, height: 560, scheme: scheme,
            layout: layout)
          #expect(RenderSupport.inkCoverage(expanded) > 0.01)
          try RenderSupport.write(expanded, name: "rm-wave2a-subagents-\(suffix)")

          var answered = PreviewData.subagentConversation
          answered.decisionPhases[PreviewData.subagentCommand.id] = .answered(summary: "Approved")
          let collapsed = try RenderSupport.render(
            group(answered), width: width, height: 120, scheme: scheme, layout: layout)
          try RenderSupport.write(collapsed, name: "rm-wave2a-subagents-collapsed-\(suffix)")

          let parent = try RenderSupport.render(
            SubagentPlayground().omnigentTheme(.omni), width: width, height: 844,
            scheme: scheme, layout: layout)
          #expect(RenderSupport.inkCoverage(parent) > 0.01)
          try RenderSupport.write(parent, name: "rm-wave2a-parent-\(suffix)")

          let child = try RenderSupport.render(
            TranscriptView(
              state: PreviewData.childConversation,
              actions: ConversationActions(openSession: { _ in })
            )
            .themeCanvas()
            .omnigentTheme(.omni),
            width: width, height: 520, scheme: scheme, layout: layout)
          try RenderSupport.write(child, name: "rm-wave2a-child-\(suffix)")

          let inbox = try RenderSupport.render(
            NavigationStack { InboxTriagePlayground() }.omnigentTheme(.omni),
            width: width, height: 844, scheme: scheme, layout: layout)
          try RenderSupport.write(inbox, name: "rm-wave2a-inbox-\(suffix)")
        }
      }
      let phone = try RenderSupport.render(
        PhoneReadingPlayground().omnigentTheme(.omni), width: 440, height: 900, scheme: .light,
        layout: .compact)
      #expect(RenderSupport.inkCoverage(phone) > 0.01)
      try RenderSupport.write(phone, name: "rm-wave2a-phone-reading-light")
    }
  }
#endif
