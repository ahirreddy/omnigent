import Foundation

/// Only selected by the isolated UI-test launch flag, never the normal workspace.
public enum EventGalleryFixtures {
  public static var snapshots: [ConversationSnapshot] {
    [
      lifecycleConversation,
      stateConversation,
      conversation("gallery-activities", title: "Event gallery", messages: activityMessages),
      conversation(
        "gallery-attachments", title: "Native attachments",
        messages: [
          ConversationMessage(
            id: "gallery-input", role: .user, text: "Review the attached design and notes.",
            attachments: [
              .init(
                id: "gallery-image", kind: .image, title: "Mobile design reference.png",
                reference: "https://example.invalid/design.png", mimeType: "image/png"),
              .init(
                id: "gallery-file", kind: .file, title: "Session event contract.txt",
                reference: "file-gallery-contract", mimeType: "text/plain"),
              .init(
                id: "gallery-audio", kind: .audio, title: "Voice note", mimeType: "audio/wav",
                isEmbedded: true),
            ])
        ]),
      conversation(
        "gallery-form", title: "Typed request", messages: [],
        decisions: [
          DecisionRequest(
            id: "gallery-form-request", targetSessionID: "gallery-form",
            title: "Release preferences",
            detail: "These answers only update this isolated offline fixture.",
            form: DecisionForm(fields: [
              .init(key: "name", title: "Release name", kind: .text, minLength: 2),
              .init(
                key: "count", title: "Number of reviewers", kind: .integer, minimum: 1, maximum: 5),
              .init(key: "notify", title: "Notify reviewers?", kind: .boolean),
            ]))
        ]),
      conversation(
        "gallery-question", title: "Structured questions", messages: [],
        decisions: [
          DecisionRequest(
            id: "gallery-question-request", targetSessionID: "gallery-question",
            title: "Choose release scope",
            detail: "Select multiple answers or write a custom answer.",
            form: DecisionForm(fields: [
              .init(
                key: "focus", title: "What should we test?", kind: .multipleChoice,
                options: [.init(value: "Messaging"), .init(value: "Event details")],
                allowsCustom: true),
              .init(
                key: "platform", title: "Which phone?", kind: .singleChoice,
                options: [.init(value: "Small iPhone"), .init(value: "Large iPhone")],
                allowsCustom: true),
            ]))
        ]),
      conversation(
        "gallery-external", title: "External confirmation", messages: [],
        decisions: [
          DecisionRequest(
            id: "gallery-external-request", targetSessionID: "gallery-external",
            title: "Confirm in browser",
            detail: "No website opens until you choose the confirmation link.",
            unsupportedReason: "Complete this request on its confirmation page.",
            externalURL: "https://example.invalid/confirm")
        ]),
      conversation(
        "gallery-plan", title: "Plan review", messages: [],
        decisions: [
          DecisionRequest(
            id: "gallery-plan-request", targetSessionID: "gallery-plan", title: "Review the plan",
            detail: "1. Implement native activity cards.\n2. Verify the small-phone layouts.",
            allowAllEdits: true, isPlanReview: true)
        ]),
      conversation(
        "gallery-policy", title: "Command approval", messages: [],
        decisions: [
          DecisionRequest(
            id: "gallery-policy-request", targetSessionID: "gallery-policy",
            title: "Approve command?",
            detail:
              "Command: swift test\nWorking directory: /fixture\nSuggested policy: swift test",
            execPolicyAmendment: ["swift", "test"])
        ]),
    ]
  }

  private static var lifecycleConversation: ConversationSnapshot {
    var result = conversation(
      "gallery-lifecycle", title: "Quiet lifecycle",
      messages: [
        .init(id: "lifecycle-user", role: .user, text: "Check the build, then stop."),
        .init(
          id: "lifecycle-created", role: .tool, text: "Terminal created",
          activity: .init(
            kind: .resource, title: "Terminal created", summary: "Build terminal",
            status: "completed",
            details: [.init(id: "id", title: "Resource ID", text: "fixture-terminal")])),
        .init(
          id: "lifecycle-reply", role: .assistant, text: "The build check is complete.",
          interrupted: true),
        .init(
          id: "lifecycle-deleted", role: .tool, text: "Terminal deleted",
          activity: .init(
            kind: .resource, title: "Terminal deleted", summary: "Build terminal",
            status: "completed",
            details: [.init(id: "id", title: "Resource ID", text: "fixture-terminal")])),
      ])
    result.session.failureMessage = "The provider disconnected."
    return result
  }

  private static var stateConversation: ConversationSnapshot {
    var state = SessionEventState(snapshot: [
      "status": .string("idle"), "last_total_tokens": .number(1_248),
      "context_window": .number(128_000),
      "total_cost_usd": .number(0.012), "collaboration_mode": .string("plan"),
      "todos": .array([
        .object(["content": .string("Render native event cards"), "status": .string("completed")]),
        .object([
          "content": .string("Verify small-phone layouts"), "status": .string("in_progress"),
          "activeForm": .string("Verifying layouts"),
        ]),
      ]),
      "mcp_startup": .object(["fixture-docs": .object(["status": .string("ready")])]),
      "sandbox_status": .object(["stage": .string("ready")]),
      "skills": .array([
        .object([
          "name": .string("mobile-accessibility"),
          "description": .string("Review phone layouts and readable controls."),
        ])
      ]),
    ])
    state.values["viewers"] = .array([
      .object(["user_id": .string("Fixture reviewer"), "idle": .bool(false)])
    ])
    state.values["children"] = .object([
      "gallery-attachments": .object([
        "title": .string("Attachment review"), "status": .string("completed"),
      ])
    ])
    state.values["changed_files"] = .object([
      "fixture-workspace": .object([
        "files": .array([
          .object(["path": .string("App/NativeActivityViews.swift"), "status": .string("added")])
        ])
      ])
    ])
    var result = conversation(
      "gallery-state", title: "Session state",
      messages: [
        .init(
          id: "gallery-state-message", role: .assistant,
          text:
            "Open Session activity to inspect the latest usage, tasks, environment and collaborators."
        )
      ])
    result.eventState = state
    return result
  }

  private static func conversation(
    _ id: String, title: String, messages: [ConversationMessage], decisions: [DecisionRequest] = []
  ) -> ConversationSnapshot {
    ConversationSnapshot(
      revision: 1,
      session: SessionSummary(
        id: id, title: title, preview: "Isolated native event test fixture",
        status: decisions.isEmpty ? .idle : .needsResponse,
        updatedAt: Date(timeIntervalSince1970: 1_700_000_000), workspace: "Offline event gallery",
        configuration: .demo), messages: messages, decisions: decisions)
  }

  private static var activityMessages: [ConversationMessage] {
    let entries: [(ConversationActivity.Kind, String, String, String)] = [
      (
        .toolCall, "Tool · search_project", "Search the local project for native views.",
        "{\"query\":\"ConversationView\"}"
      ),
      (
        .toolResult, "Tool result · search_project", "Found 3 matching files.",
        "App/ConversationView.swift\nApp/NativeActivityViews.swift\nApp/RequestFormView.swift"
      ),
      (
        .nativeTool, "Native tool · Read", "Read the event contract.",
        "Path: docs/event-contract.md\nStatus: completed"
      ),
      (
        .reasoning, "Reasoning summary", "Provider-exposed summary: compare native event groups.",
        "Only the summary supplied for display is shown. No hidden reasoning is requested."
      ),
      (
        .compaction, "Conversation compacted", "Earlier context was summarized.",
        "Summary: the user requested a readable native event timeline."
      ),
      (
        .command, "Command · /review", "Review command received.",
        "Command: /review\nSkill: mobile-accessibility"
      ),
      (
        .routing, "Router recommendation", "Would have picked Sample Fast; no route was applied.",
        "Mode: shadow\nRecommended: Sample Fast\nApplied: false"
      ),
      (
        .resource, "Resource · simulator", "Resource released after validation.",
        "Resource ID: fixture-simulator\nState: released"
      ),
      (.file, "File saved", "Created mobile-event-audit.md.", "Path: docs/mobile-event-audit.md"),
      (
        .policy, "Policy decision", "The server requested user confirmation.",
        "Decision: ask\nThis activity does not grant approval."
      ),
      (
        .clientTask, "Client task requested", "This task requires a capable web client.",
        "Task: browser interaction\nNative execution: unavailable"
      ),
      (
        .browser, "Browser action", "Recorded page navigation.",
        "URL: https://example.invalid\nNative execution: unavailable"
      ),
      (
        .retry, "Retry scheduled", "The provider will retry after a transient error.",
        "Attempt: 2\nDelay: 3 seconds"
      ),
      (
        .error, "Provider error", "The previous attempt did not complete.",
        "Code: fixture_transient_failure\nNo real provider was contacted."
      ),
      (
        .terminal, "Terminal output", "Build completed with one warning.",
        "stdout: BUILD SUCCEEDED\nstderr: fixture warning only\nExit code: 0"
      ),
      (
        .unknown, "Unrecognized event · future.progress",
        "New event details remain available for inspection.",
        "{\"type\":\"future.progress\",\"state\":\"recorded\",\"message\":\"Useful future event detail\"}"
      ),
    ]
    return entries.map { kind, title, summary, detail in
      ConversationMessage(
        id: "gallery-\(kind.rawValue)", role: .tool, text: summary,
        activity: .init(
          kind: kind, title: title, summary: summary, status: "Recorded",
          details: [
            .init(id: "details", title: "Details", text: detail, isCode: kind != .reasoning)
          ]))
    }
  }
}
