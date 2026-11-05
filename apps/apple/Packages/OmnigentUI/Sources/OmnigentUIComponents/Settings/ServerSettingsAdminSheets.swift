import OmnigentPlatform
import SwiftUI

/// Invite a member: mints a single-use register link and shows it once, as the web's Members.
struct InviteMemberSheet: View {
  let invite: @MainActor (Bool) async -> MemberInviteLink?
  let errorMessage: String?
  @Environment(\.dismiss) private var dismiss
  @State private var asAdmin = false
  @State private var isCreating = false
  @State private var link: MemberInviteLink?
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: Theme.Spacing.large) {
      Text(link == nil ? "Invite a Member" : "Invite Link").font(.headline)
      if let link {
        Text(expiry(link))
          .foregroundStyle(.secondary)
        Text(link.url)
          .font(.callout.monospaced())
          .textSelection(.enabled)
          .padding(Theme.Spacing.small)
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary, in: .rect(cornerRadius: 6))
          .accessibilityIdentifier("settings.invite-link")
      } else {
        Text("A single-use link is created. Share it with the person you want to add.")
          .foregroundStyle(.secondary)
        Toggle("Make them an administrator", isOn: $asAdmin)
        if failed {
          Label(
            errorMessage ?? "The invite could not be created.",
            systemImage: "exclamationmark.triangle"
          )
          .foregroundStyle(Theme.warning)
        }
      }
      HStack {
        Spacer()
        if let link {
          Button("Copy Link") { Pasteboard.copy(link.url) }
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        } else {
          Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
          Button("Create Invite") { create() }
            .keyboardShortcut(.defaultAction)
            .disabled(isCreating)
            .accessibilityIdentifier("settings.create-invite")
        }
      }
    }
    .padding(Theme.Spacing.large)
    .frame(width: 440)
  }

  private func create() {
    isCreating = true
    failed = false
    Task {
      link = await invite(asAdmin)
      failed = link == nil
      isCreating = false
    }
  }

  private func expiry(_ link: MemberInviteLink) -> String {
    guard let expiresAt = link.expiresAt else {
      return "Send this link to the new member. It works once."
    }
    let date = expiresAt.formatted(date: .abbreviated, time: .shortened)
    return "Send this link to the new member. It works once and expires \(date)."
  }
}

/// Add a global policy: pick a registry handler, name it and fill its parameters.
struct AddPolicySheet: View {
  let templates: [PolicyTemplate]
  let add: @MainActor (PolicyTemplate, String, [String: String]) async -> Bool
  let errorMessage: String?
  @Environment(\.dismiss) private var dismiss
  @State private var filter = ""
  @State private var selected: PolicyTemplate?
  @State private var name = ""
  @State private var values: [String: String] = [:]
  @State private var isAdding = false
  @State private var failed = false

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Text("Add Global Policy").font(.headline).padding(Theme.Spacing.large)
      Form {
        if let selected { configure(selected) } else { picker }
        if failed, let errorMessage {
          Label(errorMessage, systemImage: "exclamationmark.triangle")
            .foregroundStyle(Theme.warning)
        }
      }
      .formStyle(.grouped)
      HStack {
        if selected != nil { Button("Change Policy") { choose(nil) } }
        Spacer()
        Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
        Button("Add") { submit() }
          .keyboardShortcut(.defaultAction)
          .disabled(selected == nil || isAdding)
          .accessibilityIdentifier("settings.add-policy-confirm")
      }
      .padding(Theme.Spacing.large)
    }
    .frame(width: 520, height: 520)
  }

  private var picker: some View {
    Section {
      TextField("Filter policies", text: $filter)
      let listed = templates.filter { $0.matches(filter) }
      if listed.isEmpty {
        Text(templates.isEmpty ? "Loading policies\u{2026}" : "No policies match your filter.")
          .foregroundStyle(.secondary)
      }
      ForEach(listed) { template in
        Button {
          choose(template)
        } label: {
          VStack(alignment: .leading, spacing: 2) {
            Text(template.name).foregroundStyle(.primary)
            if !template.detail.isEmpty {
              Text(template.detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
          }
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(.rect)
        }
        .buttonStyle(.plain)
      }
    } footer: {
      Text("Global policies apply to every new session on this server.")
    }
  }

  @ViewBuilder private func configure(_ template: PolicyTemplate) -> some View {
    Section {
      LabeledContent("Policy", value: template.name)
      if !template.detail.isEmpty {
        Text(template.detail).font(.callout).foregroundStyle(.secondary)
      }
      TextField("Name", text: $name)
    }
    if !template.params.isEmpty {
      Section("Parameters") {
        ForEach(template.params) { param in field(param) }
      }
    }
  }

  @ViewBuilder private func field(_ param: PolicyTemplate.Param) -> some View {
    let value = Binding(get: { values[param.id] ?? "" }, set: { values[param.id] = $0 })
    VStack(alignment: .leading, spacing: 2) {
      switch param.kind {
      case .boolean:
        Toggle(
          param.id,
          isOn: Binding(
            get: { value.wrappedValue == "true" }, set: { value.wrappedValue = "\($0)" }))
      case .choice:
        Picker(param.id, selection: value) {
          Text("Default").tag("")
          ForEach(param.options, id: \.self) { Text($0).tag($0) }
        }
      case .multiChoice:
        Text(param.id)
        ForEach(param.options, id: \.self) { option in
          Toggle(option, isOn: multiChoice(value, option))
        }
      case .list:
        TextField(param.id, text: value, prompt: Text("Comma-separated"))
      case .object:
        TextField(param.id, text: value, prompt: Text("JSON object"))
      case .text, .integer, .number:
        TextField(param.id, text: value)
      }
      if let detail = param.detail {
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private func multiChoice(_ value: Binding<String>, _ option: String) -> Binding<Bool> {
    Binding(
      get: { Self.items(value.wrappedValue).contains(option) },
      set: { isOn in
        var items = Self.items(value.wrappedValue).filter { $0 != option }
        if isOn { items.append(option) }
        value.wrappedValue = items.joined(separator: ", ")
      })
  }

  private static func items(_ text: String) -> [String] {
    text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  private func choose(_ template: PolicyTemplate?) {
    selected = template
    name = template?.suggestedName ?? ""
    values = Dictionary(
      uniqueKeysWithValues: (template?.params ?? []).map { ($0.id, $0.defaultValue) })
    failed = false
  }

  private func submit() {
    guard let selected else { return }
    isAdding = true
    failed = false
    Task {
      let added = await add(selected, name, values)
      isAdding = false
      if added { dismiss() } else { failed = true }
    }
  }
}
