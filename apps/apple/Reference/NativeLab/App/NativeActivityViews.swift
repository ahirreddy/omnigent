import NativeLabCore
import QuickLook
import SwiftUI

struct NativeActivityCard: View {
  let activity: ConversationActivity
  let messageID: String
  let isStreaming: Bool
  var onReviewSession: (() -> Void)? = nil
  var failureIdentifier: String? = nil
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        expanded.toggle()
      } label: {
        HStack(alignment: .top, spacing: 10) {
          Image(systemName: symbol).frame(width: 22)
          VStack(alignment: .leading, spacing: 4) {
            Text(activity.title).font(.subheadline.weight(.semibold))
              .fixedSize(horizontal: false, vertical: true)
            if let status = activity.status, !status.isEmpty, !activity.isFailure {
              Text(status).font(.caption).foregroundStyle(.secondary)
            } else if isStreaming {
              Text("In progress").font(.caption).foregroundStyle(.secondary)
            }
          }
          Spacer(minLength: 0)
          Image(systemName: expanded ? "chevron.up" : "chevron.down")
            .font(.caption.weight(.semibold))
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(activity.title)
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityHint("Shows activity details")
      .accessibilityIdentifier("activity-toggle-\(messageID)")

      if !activity.summary.isEmpty {
        Text(String(activity.summary.prefix(expanded ? 4_000 : 600)))
          .font(activity.isFailure ? .footnote : .callout)
          .lineLimit(expanded ? nil : (activity.isFailure ? 1 : 3))
          .textSelection(.enabled)
          .accessibilityIdentifier(failureIdentifier ?? "activity-summary-\(messageID)")
      }
      if expanded {
        if [.terminal, .browser, .clientTask].contains(activity.kind) {
          Label(
            "Recorded activity only. No action runs on this device.", systemImage: "info.circle"
          )
          .font(.caption).foregroundStyle(.secondary)
        }
        NativeDetailSections(sections: activity.details, identifier: messageID)
        if let onReviewSession {
          Text(
            "Check the server or provider connection before trying again. Your conversation is preserved."
          )
          .font(.footnote).foregroundStyle(.secondary)
          Button("Review session activity", action: onReviewSession)
            .font(.footnote)
        }
      }
    }
    .padding(activity.isFailure ? 10 : 14)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
  }

  private var symbol: String {
    switch activity.kind {
    case .toolCall, .toolResult, .nativeTool: return "wrench.and.screwdriver"
    case .reasoning: return "text.bubble"
    case .compaction: return "arrow.down.right.and.arrow.up.left"
    case .command: return "command"
    case .terminal: return "terminal"
    case .routing: return "arrow.triangle.branch"
    case .resource: return "externaldrive"
    case .error: return "exclamationmark.triangle"
    case .retry: return "arrow.clockwise"
    case .file: return "doc"
    case .policy: return "hand.raised"
    case .clientTask: return "laptopcomputer"
    case .browser: return "globe"
    case .unknown: return "doc.text.magnifyingglass"
    }
  }
}

struct NativeFailureNotice: View {
  let message: String
  let sessionID: String
  let reviewSession: () -> Void
  @State private var expanded = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Button {
        expanded.toggle()
      } label: {
        HStack(alignment: .top) {
          Label(message, systemImage: "exclamationmark.triangle")
            .font(.footnote).lineLimit(2)
            .foregroundStyle(.orange)
          Spacer(minLength: 0)
          Image(systemName: expanded ? "chevron.up" : "chevron.down").font(.caption)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(message)
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("provider-failure-\(sessionID)")
      if expanded {
        VStack(alignment: .leading, spacing: 10) {
          Text(message).textSelection(.enabled)
          Text(
            "Check the server or provider connection before trying again. Your conversation is preserved."
          )
          .foregroundStyle(.secondary)
          Button("Review session activity", action: reviewSession)
            .accessibilityIdentifier("failure-review-\(sessionID)")
        }
        .font(.footnote)
      }
    }
    .padding(.vertical, 6)
  }
}

struct NativeDetailSections: View {
  let sections: [ConversationDetailSection]
  let identifier: String

  var body: some View {
    ForEach(sections.prefix(24)) { section in
      VStack(alignment: .leading, spacing: 8) {
        Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        Text(String(section.text.prefix(16_000)))
          .font(section.isCode ? .system(.footnote, design: .monospaced) : .callout)
          .textSelection(.enabled)
          .fixedSize(horizontal: false, vertical: true)
          .frame(maxWidth: .infinity, alignment: .leading)
          .accessibilityIdentifier("activity-detail-\(identifier)-\(section.id)")
        if section.text.count > 16_000 {
          Text("Showing the first 16,000 characters. Full output is available in the web app.")
            .font(.caption).foregroundStyle(.secondary)
        }
        Button("Copy \(section.title)", systemImage: "doc.on.doc") {
          UIPasteboard.general.string = String(section.text.prefix(16_000))
        }
        .font(.caption)
        .accessibilityIdentifier("activity-copy-\(identifier)-\(section.id)")
      }
      .padding(.top, 6)
    }
    if sections.count > 24 {
      Text("Additional details are available in the web app.")
        .font(.caption).foregroundStyle(.secondary)
    }
  }
}

struct NativeAttachmentView: View {
  @EnvironmentObject private var model: AppModel
  let attachment: ConversationAttachment
  let sessionID: String
  @State private var expanded = false
  @State private var previewURL: URL?
  @State private var previewError: String?
  @State private var isLoadingPreview = false

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Button {
        expanded.toggle()
      } label: {
        Label {
          VStack(alignment: .leading, spacing: 4) {
            Text(attachment.title).font(.subheadline.weight(.medium))
              .fixedSize(horizontal: false, vertical: true)
            Text(attachment.mimeType ?? attachment.kind.rawValue.capitalized)
              .font(.caption).foregroundStyle(.secondary)
          }
        } icon: {
          Image(systemName: symbol)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("\(attachment.kind.rawValue.capitalized) attachment: \(attachment.title)")
      .accessibilityValue(expanded ? "Expanded" : "Collapsed")
      .accessibilityIdentifier("attachment-\(attachment.id)")
      if expanded {
        Text(
          attachment.isEmbedded
            ? "Embedded attachment recorded with this message."
            : "Attachment reference. Not downloaded to this device."
        )
        .font(.caption).foregroundStyle(.secondary)
        if let reference = attachment.reference, !reference.isEmpty {
          Text(String(reference.prefix(2_000)))
            .font(.footnote).textSelection(.enabled)
            .accessibilityIdentifier("attachment-reference-\(attachment.id)")
          Button("Copy attachment reference", systemImage: "doc.on.doc") {
            UIPasteboard.general.string = String(reference.prefix(2_000))
          }
          .font(.caption)
        }
        if model.canPreviewAttachment(attachment, sessionID: sessionID) {
          Button("Preview file", systemImage: "doc.text.magnifyingglass") {
            isLoadingPreview = true
            previewError = nil
            Task {
              defer { isLoadingPreview = false }
              do {
                previewURL = try await model.loadAttachmentPreview(attachment, sessionID: sessionID)
              } catch { previewError = error.localizedDescription }
            }
          }
          .disabled(isLoadingPreview)
          .frame(minHeight: 44)
          .accessibilityIdentifier("attachment-preview-\(attachment.id)")
          if isLoadingPreview { ProgressView("Loading preview…") }
          if let previewError {
            Text(previewError).font(.caption).foregroundStyle(.red)
              .accessibilityIdentifier("attachment-error-\(attachment.id)")
          }
        } else {
          Text("Open the web app to view or download the original.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .padding(12)
    .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    .quickLookPreview($previewURL)
  }

  private var symbol: String {
    switch attachment.kind {
    case .image: return "photo"
    case .file: return "doc"
    case .audio: return "waveform"
    case .video: return "video"
    case .unknown: return "paperclip"
    }
  }
}

struct NativeSessionActivityView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var showsLifecycle = false
  let sessionID: String

  private var sections: [SessionEventSection] {
    model.snapshot(for: sessionID)?.eventState?.sections ?? []
  }

  private var lifecycleMessages: [ConversationMessage] {
    model.snapshot(for: sessionID)?.lifecycleMessages ?? []
  }

  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 14) {
          if sections.isEmpty && lifecycleMessages.isEmpty {
            ContentUnavailableView(
              "No activity metadata yet", systemImage: "list.bullet.rectangle",
              description: Text(
                "Usage, tasks and environment details appear here when the server reports them."))
          }
          if !lifecycleMessages.isEmpty {
            Button {
              showsLifecycle.toggle()
            } label: {
              HStack {
                Label("Lifecycle history (\(lifecycleMessages.count))", systemImage: "clock")
                Spacer(minLength: 0)
                Image(systemName: showsLifecycle ? "chevron.up" : "chevron.down")
              }
              .font(.subheadline)
              .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(showsLifecycle ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("lifecycle-history")
            if showsLifecycle {
              Text("Events from loaded history, newest first.")
                .font(.caption).foregroundStyle(.secondary)
              ForEach(lifecycleMessages.reversed()) { message in
                if let activity = message.activity {
                  NativeActivityCard(
                    activity: activity, messageID: message.id, isStreaming: message.isStreaming)
                }
              }
            }
          }
          ForEach(sections) { section in
            VStack(alignment: .leading, spacing: 12) {
              NativeActivityCard(
                activity: .init(
                  kind: .resource, title: section.title, summary: section.summary,
                  details: section.details),
                messageID: "state-\(section.id)", isStreaming: false)
              if let target = section.sessionID, target != sessionID {
                NavigationLink {
                  ConversationView(sessionID: target)
                } label: {
                  Label("Open conversation", systemImage: "arrow.up.forward")
                }
                .accessibilityIdentifier("state-open-\(section.id)")
              }
            }
          }
        }
        .padding()
      }
      .accessibilityIdentifier("session-activity-scroll")
      .navigationTitle("Session activity")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") { dismiss() }.accessibilityIdentifier("session-activity-done")
        }
      }
    }
  }
}
