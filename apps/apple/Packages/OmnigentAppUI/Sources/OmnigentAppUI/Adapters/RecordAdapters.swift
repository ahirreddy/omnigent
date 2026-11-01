import OmnigentCoreFFI
import OmnigentUIComponents

// Field-by-field copies of the core's records into the components' mirrors. The components'
// types match the generated bindings name for name, so each initializer is a plain copy; when
// either side gains a field, only these initializers change.

nonisolated extension OmnigentUIComponents.Row {
  init(_ row: OmnigentCoreFFI.Row) {
    self.init(
      id: row.id, role: OmnigentUIComponents.RowRole(row.role), text: row.text,
      isStreaming: row.isStreaming, activity: row.activity.map(OmnigentUIComponents.Activity.init),
      attachments: row.attachments.map(OmnigentUIComponents.Attachment.init), callId: row.callId,
      responseId: row.responseId, interrupted: row.interrupted, author: row.author,
      agent: row.agent, isEphemeral: row.isEphemeral, isActivityOnly: row.isActivityOnly)
  }
}

nonisolated extension OmnigentUIComponents.RowRole {
  init(_ role: OmnigentCoreFFI.RowRole) {
    switch role {
    case .user: self = .user
    case .assistant: self = .assistant
    case .tool: self = .tool
    }
  }
}

nonisolated extension OmnigentUIComponents.Activity {
  init(_ activity: OmnigentCoreFFI.Activity) {
    self.init(
      kind: OmnigentUIComponents.ActivityKind(activity.kind), title: activity.title,
      summary: activity.summary, status: activity.status,
      details: activity.details.map(OmnigentUIComponents.DetailSection.init),
      isFailure: activity.isFailure)
  }
}

nonisolated extension OmnigentUIComponents.ActivityKind {
  // One case per core case; a new core case fails to compile here instead of rendering wrong.
  // swiftlint:disable:next cyclomatic_complexity
  init(_ kind: OmnigentCoreFFI.ActivityKind) {
    switch kind {
    case .toolCall: self = .toolCall
    case .toolResult: self = .toolResult
    case .nativeTool: self = .nativeTool
    case .reasoning: self = .reasoning
    case .compaction: self = .compaction
    case .command: self = .command
    case .terminal: self = .terminal
    case .routing: self = .routing
    case .resource: self = .resource
    case .error: self = .error
    case .unknown: self = .unknown
    case .retry: self = .retry
    case .file: self = .file
    case .policy: self = .policy
    case .clientTask: self = .clientTask
    case .browser: self = .browser
    case .sidechat: self = .sidechat
    }
  }
}

nonisolated extension OmnigentUIComponents.DetailSection {
  init(_ section: OmnigentCoreFFI.DetailSection) {
    self.init(id: section.id, title: section.title, text: section.text, isCode: section.isCode)
  }
}

nonisolated extension OmnigentUIComponents.Attachment {
  init(_ attachment: OmnigentCoreFFI.Attachment) {
    self.init(
      id: attachment.id, kind: OmnigentUIComponents.AttachmentKind(attachment.kind),
      title: attachment.title, reference: attachment.reference, mimeType: attachment.mimeType,
      isEmbedded: attachment.isEmbedded)
  }
}

nonisolated extension OmnigentUIComponents.AttachmentKind {
  init(_ kind: OmnigentCoreFFI.AttachmentKind) {
    switch kind {
    case .image: self = .image
    case .file: self = .file
    case .audio: self = .audio
    case .video: self = .video
    }
  }
}

nonisolated extension OmnigentUIComponents.SessionHeader {
  init(_ header: OmnigentCoreFFI.SessionHeader) {
    self.init(
      id: header.id, title: header.title, status: OmnigentUIComponents.TurnStatus(header.status),
      readOnly: header.readOnly, archived: header.archived,
      permissionLevel: header.permissionLevel, failureMessage: header.failureMessage,
      settings: header.settings.map(OmnigentUIComponents.SessionSettings.init))
  }
}

nonisolated extension OmnigentUIComponents.TurnStatus {
  init(_ status: OmnigentCoreFFI.TurnStatus) {
    switch status {
    case .idle: self = .idle
    case .running: self = .running
    case .needsResponse: self = .needsResponse
    }
  }
}

nonisolated extension OmnigentUIComponents.SessionSettings {
  init(_ settings: OmnigentCoreFFI.SessionSettings) {
    self.init(
      agentId: settings.agentId, harness: settings.harness, wrapper: settings.wrapper,
      modelOverride: OmnigentUIComponents.ReportedValue(settings.modelOverride),
      baseModel: settings.baseModel,
      reasoningEffort: OmnigentUIComponents.ReportedValue(settings.reasoningEffort),
      modelOptions: settings.modelOptions.map(OmnigentUIComponents.ModelOption.init),
      hostId: settings.hostId, hostOnline: settings.hostOnline,
      runnerOnline: settings.runnerOnline, runnerBound: settings.runnerBound,
      hostResumable: settings.hostResumable, parentId: settings.parentId,
      routingMode: settings.routingMode)
  }
}

nonisolated extension OmnigentUIComponents.ReportedValue {
  init(_ value: OmnigentCoreFFI.ReportedValue) {
    switch value {
    case .notReported: self = .notReported
    case .harnessDefault: self = .harnessDefault
    case .value(let value): self = .value(value: value)
    }
  }
}

nonisolated extension OmnigentUIComponents.ModelOption {
  init(_ option: OmnigentCoreFFI.ModelOption) {
    self.init(
      id: option.id, model: option.model, displayName: option.displayName,
      defaultReasoningEffort: option.defaultReasoningEffort,
      supportedReasoningEfforts: option.supportedReasoningEfforts, isDefault: option.isDefault,
      hidden: option.hidden)
  }
}

nonisolated extension OmnigentUIComponents.EventSection {
  init(_ section: OmnigentCoreFFI.EventSection) {
    self.init(
      id: section.id, title: section.title, summary: section.summary,
      details: section.details.map(OmnigentUIComponents.DetailSection.init),
      sessionId: section.sessionId)
  }
}

nonisolated extension OmnigentUIComponents.SessionSummary {
  init(_ summary: OmnigentCoreFFI.SessionSummary) {
    self.init(
      id: summary.id, title: summary.title, preview: summary.preview,
      status: OmnigentUIComponents.SessionListStatus(summary.status),
      isReadOnly: summary.isReadOnly, updatedAt: summary.updatedAt, workspace: summary.workspace,
      agentName: summary.agentName, isPinned: summary.isPinned, isArchived: summary.isArchived,
      permissionLevel: summary.permissionLevel, failureMessage: summary.failureMessage,
      canRename: summary.canRename, canPin: summary.canPin, canArchive: summary.canArchive)
  }
}

nonisolated extension OmnigentUIComponents.SessionListStatus {
  init(_ status: OmnigentCoreFFI.SessionListStatus) {
    switch status {
    case .idle: self = .idle
    case .running: self = .running
    case .needsResponse: self = .needsResponse
    }
  }
}

nonisolated extension OmnigentCoreFFI.SessionFilter {
  init(_ filter: OmnigentUIComponents.SessionFilter) {
    switch filter {
    case .all: self = .all
    case .running: self = .running
    case .needsResponse: self = .needsResponse
    case .archived: self = .archived
    }
  }
}

nonisolated extension OmnigentUIComponents.SessionFilter {
  init(_ filter: OmnigentCoreFFI.SessionFilter) {
    switch filter {
    case .all: self = .all
    case .running: self = .running
    case .needsResponse: self = .needsResponse
    case .archived: self = .archived
    }
  }
}
