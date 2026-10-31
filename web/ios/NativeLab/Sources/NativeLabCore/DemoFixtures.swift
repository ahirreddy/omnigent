import Foundation

public enum DemoFixtures {
  public static let snapshots: [ConversationSnapshot] = [
    ConversationSnapshot(
      revision: 1,
      session: SessionSummary(
        id: "demo-design", title: "Native mobile design",
        preview: "Review the proposed session screen.", status: .needsResponse,
        updatedAt: Date().addingTimeInterval(-240), workspace: "Omni / iOS", isPinned: true
      ),
      messages: [
        ConversationMessage(
          id: "design-request", role: .user,
          text: "Help me make the mobile session screen easier to scan."
        ),
        ConversationMessage(
          id: "design-proposal", role: .assistant,
          text: """
            I suggest a short session list with the latest message and a clear status. \
            Requests that need your response should also appear in Attention.

            This sample is ready for your review. Approving it only changes this offline demo.
            """
        ),
      ],
      decisions: [
        DecisionRequest(
          id: "decision-design", targetSessionID: "demo-design",
          title: "Apply the sample design?",
          detail: "Use the simpler session list and keep pending requests easy to find."
        )
      ]
    ),
    ConversationSnapshot(
      revision: 1,
      session: SessionSummary(
        id: "demo-question", title: "Choose the first release",
        preview: "Which mobile workflow should come first?", status: .needsResponse,
        updatedAt: Date().addingTimeInterval(-3600), workspace: "Omni / Planning"
      ),
      messages: [
        ConversationMessage(
          id: "question-request", role: .user,
          text: "Let's keep the first mobile release focused."
        ),
        ConversationMessage(
          id: "question-context", role: .assistant,
          text: """
            Both options use native screens. Sessions and chat would emphasize reading \
            and continuing work; approvals would emphasize quick decisions while away \
            from your computer.
            """
        ),
      ],
      decisions: [
        DecisionRequest(
          id: "decision-question", targetSessionID: "demo-question",
          title: "What should we build first?",
          detail: "Choose one focus for this sample plan.",
          options: ["Sessions and chat", "Approvals first"]
        )
      ]
    ),
    ConversationSnapshot(
      revision: 1,
      session: SessionSummary(
        id: "demo-notes", title: "Project notes",
        preview: "A shared conversation you can read.", isReadOnly: true,
        updatedAt: Date().addingTimeInterval(-86400), workspace: "Omni / Shared"
      ),
      messages: [
        ConversationMessage(
          id: "notes-request", role: .user,
          text: "Summarize the mobile prototype's boundaries."
        ),
        ConversationMessage(
          id: "notes-summary", role: .assistant,
          text: """
            The prototype has native session lists, conversations, and decisions. \
            Its replies are simulated. Sessions and drafts are saved only on this device.

            This shared session is read-only. Open another session or create one to try sending.
            """
        ),
      ]
    ),
  ]
}
