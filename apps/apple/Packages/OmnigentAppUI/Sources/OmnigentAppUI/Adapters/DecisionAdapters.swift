import OmnigentCoreFFI
import OmnigentUIComponents

// Decision cards in, responses out. A card the components cannot represent still renders: the
// core already turns anything unanswerable into `unsupported`, which maps one to one.

nonisolated extension OmnigentUIComponents.DecisionCard {
  init(_ card: OmnigentCoreFFI.DecisionCard) {
    self.init(
      id: card.id, carryingSessionId: card.carryingSessionId,
      targetSessionId: card.targetSessionId, title: card.title, detail: card.detail,
      kind: OmnigentUIComponents.DecisionKind(card.kind),
      permissions: OmnigentUIComponents.PermissionOptions(card.permissions), phase: card.phase,
      policyName: card.policyName, acceptsFeedback: card.acceptsFeedback, answered: card.answered,
      message: card.message, toolInput: card.toolInput)
  }
}

nonisolated extension OmnigentUIComponents.DecisionKind {
  init(_ kind: OmnigentCoreFFI.DecisionKind) {
    switch kind {
    case .approval:
      self = .approval
    case .choice(let answerKey, let options):
      self = .choice(answerKey: answerKey, options: options)
    case .form(let fields):
      self = .form(fields: fields.map(OmnigentUIComponents.FormField.init))
    case .unsupported(let reason, let externalUrl):
      self = .unsupported(reason: reason, externalUrl: externalUrl)
    }
  }
}

nonisolated extension OmnigentUIComponents.FormField {
  init(_ field: OmnigentCoreFFI.FormField) {
    self.init(
      key: field.key, title: field.title, detail: field.detail,
      kind: OmnigentUIComponents.FieldKind(field.kind), required: field.required,
      options: field.options.map {
        OmnigentUIComponents.FormOption(value: $0.value, label: $0.label, detail: $0.detail)
      },
      allowsCustom: field.allowsCustom, isSecret: field.isSecret, minimum: field.minimum,
      maximum: field.maximum, minLength: field.minLength, maxLength: field.maxLength,
      minItems: field.minItems, maxItems: field.maxItems)
  }
}

nonisolated extension OmnigentUIComponents.FieldKind {
  init(_ kind: OmnigentCoreFFI.FieldKind) {
    switch kind {
    case .text: self = .text
    case .number: self = .number
    case .integer: self = .integer
    case .boolean: self = .boolean
    case .singleChoice: self = .singleChoice
    case .multipleChoice: self = .multipleChoice
    }
  }
}

nonisolated extension OmnigentUIComponents.PermissionOptions {
  init(_ options: OmnigentCoreFFI.PermissionOptions) {
    self.init(
      allowAllEdits: options.allowAllEdits, allowAutoMode: options.allowAutoMode,
      permissionDirectories: options.permissionDirectories, rememberLabel: options.rememberLabel,
      plan: options.plan,
      command: options.command.map {
        OmnigentUIComponents.CommandApproval(command: $0.command, cwd: $0.cwd, reason: $0.reason)
      },
      execPolicyAmendment: options.execPolicyAmendment,
      persistModes: options.persistModes.map(OmnigentUIComponents.PersistMode.init),
      antigravity: options.antigravity.map {
        OmnigentUIComponents.AntigravityPermission(
          actionDescription: $0.actionDescription, alwaysAllowPattern: $0.alwaysAllowPattern)
      },
      files: options.fileChanges.map(DecisionFileChange.init))
  }
}

nonisolated extension DecisionFileChange {
  init(_ file: EditedFile) {
    self.init(
      path: file.path,
      added: file.linesAdded.map(Int.init),
      removed: file.linesRemoved.map(Int.init),
      kind: file.kind.map(Kind.init))
  }
}

nonisolated extension DecisionFileChange.Kind {
  init(_ kind: EditKind) {
    switch kind {
    case .create: self = .create
    case .modify: self = .modify
    case .delete: self = .delete
    case .write: self = .write
    }
  }
}

nonisolated extension OmnigentUIComponents.PersistMode {
  init(_ mode: OmnigentCoreFFI.PersistMode) {
    switch mode {
    case .session: self = .session
    case .always: self = .always
    }
  }
}

nonisolated extension OmnigentCoreFFI.PersistMode {
  init(_ mode: OmnigentUIComponents.PersistMode) {
    switch mode {
    case .session: self = .session
    case .always: self = .always
    }
  }
}

nonisolated extension OmnigentCoreFFI.DecisionResponse {
  // One case per response; a new case fails to compile here instead of answering wrong.
  // swiftlint:disable:next cyclomatic_complexity
  init(_ response: OmnigentUIComponents.DecisionResponse) {
    switch response {
    case .approve: self = .approve
    case .decline: self = .decline
    case .cancel: self = .cancel
    case .answer(let value): self = .answer(value: value)
    case .form(let values):
      self = .form(values: values.mapValues(OmnigentCoreFFI.ElicitationValue.init))
    case .approveAllEdits: self = .approveAllEdits
    case .approveAutoMode: self = .approveAutoMode
    case .approveDirectories: self = .approveDirectories
    case .approveRemembering: self = .approveRemembering
    case .approveCommandPolicy(let policy): self = .approveCommandPolicy(policy: policy)
    case .approvePersist(let mode): self = .approvePersist(mode: OmnigentCoreFFI.PersistMode(mode))
    case .declineWithFeedback(let feedback): self = .declineWithFeedback(feedback: feedback)
    }
  }
}

nonisolated extension OmnigentCoreFFI.ElicitationValue {
  init(_ value: OmnigentUIComponents.ElicitationValue) {
    switch value {
    case .null: self = .null
    case .bool(let value): self = .bool(value: value)
    case .integer(let value): self = .integer(value: value)
    case .number(let value): self = .number(value: value)
    case .text(let value): self = .text(value: value)
    case .textList(let values): self = .textList(values: values)
    }
  }
}

nonisolated extension OmnigentUIComponents.DecisionResponse {
  // The answer the store holds for a card, for the card's "Approved" line.
  // swiftlint:disable:next cyclomatic_complexity
  init(_ response: OmnigentCoreFFI.DecisionResponse) {
    switch response {
    case .approve: self = .approve
    case .decline: self = .decline
    case .cancel: self = .cancel
    case .answer(let value): self = .answer(value: value)
    case .form(let values):
      self = .form(values: values.mapValues(OmnigentUIComponents.ElicitationValue.init))
    case .approveAllEdits: self = .approveAllEdits
    case .approveAutoMode: self = .approveAutoMode
    case .approveDirectories: self = .approveDirectories
    case .approveRemembering: self = .approveRemembering
    case .approveCommandPolicy(let policy): self = .approveCommandPolicy(policy: policy)
    case .approvePersist(let mode):
      self = .approvePersist(mode: OmnigentUIComponents.PersistMode(mode))
    case .declineWithFeedback(let feedback): self = .declineWithFeedback(feedback: feedback)
    }
  }
}

nonisolated extension OmnigentUIComponents.ElicitationValue {
  init(_ value: OmnigentCoreFFI.ElicitationValue) {
    switch value {
    case .null: self = .null
    case .bool(let value): self = .bool(value: value)
    case .integer(let value): self = .integer(value: value)
    case .number(let value): self = .number(value: value)
    case .text(let value): self = .text(value: value)
    case .textList(let values): self = .textList(values: values)
    }
  }
}
