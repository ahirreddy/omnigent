import NativeLabCore
import SwiftUI

struct ConfigurationButton: View {
  @EnvironmentObject private var model: AppModel
  @State private var showsConfiguration = false
  let sessionID: String
  var expanded = false
  var onOpen: (() -> Void)?

  var body: some View {
    Button {
      if let onOpen { onOpen() } else { showsConfiguration = true }
    } label: {
      HStack(alignment: .center, spacing: 8) {
        HarnessLogo(harness: model.snapshot(for: sessionID)?.session.configuration?.harness)
          .frame(width: 24, height: 24)
          .accessibilityIdentifier(expanded ? "expanded-harness-logo" : "composer-harness-logo")
        Text(
          model.snapshot(for: sessionID)?.session.configuration?.modelLabel ?? "Model not reported"
        )
        .font(.subheadline.weight(.medium))
        .multilineTextAlignment(.leading)
        .lineLimit(2)
        .accessibilityIdentifier(expanded ? "expanded-model-label" : "composer-model-label")
        Spacer(minLength: 0)
        Image(systemName: "chevron.down").font(.caption)
      }
      .frame(minHeight: 44)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel("Harness and model")
    .accessibilityValue(
      model.snapshot(for: sessionID)?.session.configuration?.identityLabel ?? "Not reported"
    )
    .accessibilityIdentifier(expanded ? "expanded-configuration" : "composer-configuration")
    .sheet(isPresented: $showsConfiguration) {
      SessionConfigurationView(
        sessionID: sessionID,
        generation: model.connectionGeneration,
        configuration: model.snapshot(for: sessionID)?.session.configuration
          ?? SessionConfiguration()
      )
      .environmentObject(model)
    }
  }
}

struct SessionConfigurationView: View {
  @EnvironmentObject private var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var edit: ConfigurationEdit
  @State private var catalog: ConfigurationCatalog?
  @State private var target: HarnessChoice?
  @State private var error: String?
  @State private var catalogError: String?
  @State private var isWorking = false
  @State private var loadingCatalog = false
  @State private var reloadCatalogWhenFinished = false
  @State private var confirmsSwitch = false
  @State private var path: [Page] = []
  private enum Page: Hashable { case models, effort, harnesses, details }
  let sessionID: String
  @State private var generation: UUID

  init(sessionID: String, generation: UUID, configuration: SessionConfiguration) {
    self.sessionID = sessionID
    _generation = State(initialValue: generation)
    _edit = State(initialValue: ConfigurationEdit(configuration))
  }

  private var current: SessionConfiguration {
    model.snapshot(for: sessionID)?.session.configuration ?? SessionConfiguration()
  }
  private var choices: SessionConfiguration {
    catalog?.configurationByAddingModelOptions(to: current) ?? current
  }
  private var usesHostPreview: Bool { current.models.isEmpty && !choices.models.isEmpty }
  private var conflict: Bool { !current.sameSelection(as: edit.baseline) }
  private var disabledReason: String? { model.configurationUnavailableReason(sessionID) }
  private var canApply: Bool {
    !isWorking && !conflict && disabledReason == nil && (target != nil || edit.hasChanges)
  }
  private var selectedModel: String {
    if edit.model == nil && current.modelReported != true && current.effectiveModel == nil {
      return "Not reported"
    }
    guard let value = edit.model else { return "Harness default" }
    return choices.models.first(where: { $0.matches(value) })?.title ?? value
  }
  private var selectedEffort: String {
    if edit.effort == edit.baseline.effort { return current.effortLabel }
    return edit.effort?.capitalized ?? "Harness default"
  }

  var body: some View {
    NavigationStack(path: $path) {
      Form {
        Section {
          HStack(spacing: 10) {
            HarnessLogo(harness: current.harness).frame(width: 28, height: 28)
            Text(current.modelLabel).font(.headline).textSelection(.enabled)
          }
          .accessibilityElement(children: .ignore)
          .accessibilityLabel(current.identityLabel)
          .accessibilityIdentifier("configuration-current")
          Text(
            model.isLive
              ? "Settings for this session only." : "Offline sample settings. No model is invoked."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        if let disabledReason {
          Section { Text(disabledReason).accessibilityIdentifier("configuration-unavailable") }
        }
        if conflict || model.configurationNeedsReview(sessionID) {
          Section {
            Text(
              conflict
                ? "Settings changed elsewhere. Review the current settings before applying."
                : "Confirmation was lost. No automatic retry was made."
            )
            .accessibilityIdentifier("configuration-conflict")
            Button("Review current settings") { Task { await review() } }
              .buttonStyle(.borderless)
              .accessibilityIdentifier("configuration-review")
              .disabled(isWorking)
          }
        }
        Section {
          NavigationLink(value: Page.harnesses) {
            configRow("Harness", value: target?.title ?? current.harnessLabel)
          }.accessibilityIdentifier("configuration-harness")
          NavigationLink(value: Page.models) {
            configRow("Model", value: target == nil ? selectedModel : "Choose after switching")
          }.accessibilityIdentifier("configuration-model")
          NavigationLink(value: Page.effort) {
            configRow("Reasoning", value: target == nil ? selectedEffort : "Choose after switching")
          }.accessibilityIdentifier("configuration-effort")
        } footer: {
          Text(
            target == nil
              ? "Changes are saved for the next message. The current response is never interrupted."
              : "Switching resets the runtime; it starts on next use. Your message draft stays here. Choose model and reasoning after the switch."
          )
        }
        if let target {
          Section {
            Text(switchExplanation(target))
            Button("Keep current harness") {
              guard !confirmsSwitch, !isWorking else { return }
              self.target = nil
            }
            .buttonStyle(.borderless)
            .disabled(confirmsSwitch || isWorking)
            .accessibilityIdentifier("configuration-clear-harness")
          }
        }
        Section {
          NavigationLink("Session details", value: Page.details)
            .accessibilityIdentifier("configuration-details")
        }
        if let error {
          Section {
            Text(error).foregroundStyle(.red).accessibilityIdentifier("configuration-error")
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        if path.isEmpty { applyButton }
      }
      .navigationTitle("Harness & model")
      .navigationBarTitleDisplayMode(.inline)
      .navigationDestination(for: Page.self) { page in
        Group {
          switch page {
          case .models:
            ModelChoicesView(
              configuration: choices, selection: edit.model,
              disabledReason: modelUnavailableReason, usesHostPreview: usesHostPreview
            ) { choice in
              guard !conflict, modelUnavailableReason == nil else { return }
              let stagedEffort = edit.effort
              edit = ConfigurationEdit(choices)
              edit.effort = stagedEffort
              edit.selectModel(choice)
              error = nil
              path.removeLast()
            }
          case .effort: effortChoices
          case .harnesses: harnessChoices
          case .details: details
          }
        }
        .toolbar { ToolbarItem(placement: .confirmationAction) { closeButton } }
      }
      .toolbar {
        ToolbarItem(placement: .confirmationAction) { closeButton }
      }
      .task { await loadCatalog() }
      .onChange(of: model.connectionGeneration) { _, _ in dismiss() }
      .onChange(of: path) { _, new in
        if new.last == .harnesses { Task { await loadCatalog() } }
      }
      .onChange(of: current) { _, new in
        guard !isWorking else { return }
        if new.hostID != edit.baseline.hostID || new.hostOnline != edit.baseline.hostOnline
          || new.runnerOnline != edit.baseline.runnerOnline
        {
          Task { await loadCatalog() }
        }
        if new.sameSelection(as: edit.baseline) {
          var updated = ConfigurationEdit(new)
          updated.model = edit.model
          updated.effort = edit.effort
          edit = updated
        } else if !edit.hasChanges && target == nil {
          edit = ConfigurationEdit(new)
        }
      }
    }
    .alert("Switch to \(target?.title ?? "another harness")?", isPresented: $confirmsSwitch) {
      Button("Switch harness") { Task { await apply() } }
        .accessibilityIdentifier("configuration-confirm-switch")
      Button("Cancel", role: .cancel) {}
    } message: {
      Text(target.map(switchExplanation) ?? "")
    }
    .presentationDetents([.large])
    .presentationDragIndicator(.visible)
    .interactiveDismissDisabled(isWorking)
  }

  private var applyButton: some View {
    Button {
      if target != nil { confirmsSwitch = true } else { Task { await apply() } }
    } label: {
      HStack {
        if isWorking { ProgressView() }
        Text(target == nil ? "Apply to next message" : "Review harness switch")
      }.frame(maxWidth: .infinity, minHeight: 44)
    }
    .buttonStyle(.borderedProminent)
    .disabled(!canApply)
    .accessibilityIdentifier("configuration-apply")
    .padding(.horizontal).padding(.vertical, 8)
    .background(Color(uiColor: .systemBackground))
  }

  private var modelUnavailableReason: String? {
    if let disabledReason { return disabledReason }
    if conflict { return "Review the changed settings first." }
    if target != nil { return "Choose the model after switching harness." }
    if current.routingMode == "on" {
      return "Smart routing chooses the model. Manage routing in the web app."
    }
    if !current.supportsModels {
      return "This harness does not expose a supported native model picker."
    }
    if choices.models.isEmpty {
      return catalog?.modelOptionsError ?? "Model choices have not been reported by the runner yet."
    }
    return nil
  }

  private var closeButton: some View {
    Button(edit.hasChanges || target != nil ? "Cancel" : "Done") { dismiss() }
      .disabled(isWorking).accessibilityIdentifier("configuration-done")
  }

  private var effortChoices: some View {
    List {
      Section {
        Text("Current: \(current.effortLabel)")
        if !current.supportsEffort {
          Text("This harness does not expose a separate reasoning control.")
        } else if let reason = modelUnavailableReason {
          Text(reason)
        } else if choices.efforts(for: edit.model).isEmpty {
          Text(
            "Supported reasoning levels are not reported for this model. Its default remains available."
          )
        }
      }
      Section("For the selected model") {
        choiceRow(
          "Harness default", selected: edit.effort == nil && current.effortReported == true,
          id: "effort-default"
        ) {
          guard !conflict, modelUnavailableReason == nil else { return }
          edit.effort = nil
          path.removeLast()
        }
        ForEach(choices.efforts(for: edit.model), id: \.self) { effort in
          choiceRow(effort.capitalized, selected: edit.effort == effort, id: "effort-\(effort)") {
            guard !conflict, modelUnavailableReason == nil else { return }
            edit.effort = effort
            path.removeLast()
          }
        }
      }.disabled(modelUnavailableReason != nil || !current.supportsEffort)
    }.navigationTitle("Reasoning")
  }

  private var harnessChoices: some View {
    List {
      Section {
        Text("Current: \(current.harnessLabel)")
        Text(
          "Only configured targets that preserve conversation history can be selected. Host readiness does not guarantee provider sign-in."
        )
        .font(.footnote).foregroundStyle(.secondary)
        if let disabledReason { Text(disabledReason) }
        if edit.hasChanges {
          Text(
            "Choosing a harness discards unapplied model and reasoning choices, not your message draft."
          )
        }
        if loadingCatalog { ProgressView("Loading harnesses…") }
        if let catalogError {
          Text(catalogError)
          Button("Try loading choices again") { Task { await loadCatalog() } }
        }
        if let catalog, catalog.agents.isEmpty {
          Text("No built-in harness targets were reported.")
        }
      }
      if let catalog {
        ForEach(orderedHarnesses(catalog)) { agent in
          let reason = catalog.unavailableReason(for: agent, current: current)
          Button {
            guard !conflict, disabledReason == nil, reason == nil else { return }
            edit = ConfigurationEdit(current)
            target = agent
            error = nil
            path.removeLast()
          } label: {
            HStack(alignment: .top, spacing: 12) {
              HarnessLogo(harness: agent.harness).frame(width: 28, height: 28)
              VStack(alignment: .leading, spacing: 6) {
                Text(agent.title).foregroundStyle(.primary)
                Text(agent.name).font(.caption).foregroundStyle(.secondary)
                if let reason { Text(reason).font(.footnote).foregroundStyle(.secondary) }
              }
            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
          }
          .disabled(reason != nil || disabledReason != nil || conflict)
          .accessibilityIdentifier("harness-\(agent.id)")
        }
      }
    }.navigationTitle("Harness")
  }

  private func orderedHarnesses(_ catalog: ConfigurationCatalog) -> [HarnessChoice] {
    func rank(_ agent: HarnessChoice) -> Int {
      if SessionConfiguration.canonicalHarness(agent.harness)
        == SessionConfiguration.canonicalHarness(current.harness)
      {
        return 0
      }
      return catalog.unavailableReason(for: agent, current: current) == nil ? 1 : 2
    }
    return catalog.agents.sorted {
      if rank($0) != rank($1) { return rank($0) < rank($1) }
      return ($0.title + $0.name).localizedStandardCompare($1.title + $1.name) == .orderedAscending
    }
  }

  private var details: some View {
    Form {
      Section("Reported by this session") {
        detail("Harness", current.harness)
        detail(
          "Model override",
          current.modelOverride ?? (current.modelReported == true ? "None (harness default)" : nil))
        detail("Agent model", current.baseModel)
        detail(
          "Reasoning override",
          current.effort ?? (current.effortReported == true ? "None (harness default)" : nil))
        detail("Agent", model.snapshot(for: sessionID)?.session.agentName)
        detail("Agent ID", current.agentID)
        detail("Session ID", sessionID)
        detail("Host", catalog?.host?.name ?? current.hostID)
        detail("Host ID", current.hostID)
        detail("Workspace", model.snapshot(for: sessionID)?.session.workspace)
        detail("Provider", nil)
      }
      Section {
        Text(
          "Harness default means no explicit override. It is not a confirmed model or reasoning level. Provider identity is not inferred from the model name."
        )
        .font(.footnote)
      }
    }.navigationTitle("Session details")
  }

  private func configRow(_ title: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(title)
      Text(value).font(.subheadline).foregroundStyle(.secondary).fixedSize(
        horizontal: false, vertical: true)
    }.frame(minHeight: 44)
  }

  private func detail(_ title: String, _ value: String?) -> some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(title).font(.caption).foregroundStyle(.secondary)
      Text(value ?? "Not reported").textSelection(.enabled)
    }
  }

  private func choiceRow(_ title: String, selected: Bool, id: String, action: @escaping () -> Void)
    -> some View
  {
    Button(action: action) {
      HStack {
        Text(title)
        Spacer()
        if selected { Image(systemName: "checkmark") }
      }
      .frame(minHeight: 44).contentShape(Rectangle())
    }.accessibilityIdentifier(id).accessibilityAddTraits(selected ? .isSelected : [])
  }

  private func switchExplanation(_ target: HarnessChoice) -> String {
    let sameFamily =
      SessionConfiguration.family(current.harness) != nil
      && SessionConfiguration.family(current.harness) == SessionConfiguration.family(target.harness)
    return
      "The conversation, files, workspace and message draft stay. The runtime resets to \(target.title) and starts on next use; this does not verify provider access. "
      + (sameFamily
        ? "Model and reasoning settings carry over within this provider family. Review model compatibility before sending."
        : "Model and reasoning settings reset to the target's defaults.")
  }

  private func loadCatalog() async {
    guard generation == model.connectionGeneration else {
      dismiss()
      return
    }
    guard !loadingCatalog else {
      reloadCatalogWhenFinished = true
      return
    }
    loadingCatalog = true
    catalogError = nil
    defer {
      loadingCatalog = false
      if reloadCatalogWhenFinished {
        reloadCatalogWhenFinished = false
        Task { await loadCatalog() }
      }
    }
    do {
      let loaded = try await model.loadConfigurationCatalog(sessionID)
      guard generation == model.connectionGeneration else { return }
      catalog = loaded
    } catch {
      if generation == model.connectionGeneration { catalogError = error.localizedDescription }
    }
  }

  private func review() async {
    guard generation == model.connectionGeneration else {
      dismiss()
      return
    }
    isWorking = true
    defer { isWorking = false }
    do {
      try await model.reviewConfiguration(sessionID)
      edit = ConfigurationEdit(current)
      target = nil
      error = nil
      await loadCatalog()
    } catch { self.error = error.localizedDescription }
  }

  private func apply() async {
    guard generation == model.connectionGeneration else {
      dismiss()
      return
    }
    guard canApply else { return }
    isWorking = true
    error = nil
    defer { isWorking = false }
    do {
      try await model.applyConfiguration(edit, to: sessionID, target: target)
      dismiss()
    } catch {
      self.error =
        error.localizedDescription
        + " No automatic retry was made. Review any settings that were already saved."
    }
  }
}

private struct ModelChoicesView: View {
  let configuration: SessionConfiguration
  let selection: String?
  let disabledReason: String?
  let usesHostPreview: Bool
  let choose: (String?) -> Void
  @State private var search = ""

  private var choices: [ModelChoice] {
    var seen = Set<String>()
    return configuration.models.filter { option in
      option.hidden != true && seen.insert(option.value).inserted
        && (search.isEmpty
          || [option.title, option.value, option.description ?? ""].contains {
            $0.localizedCaseInsensitiveContains(search)
          })
    }.sorted { lhs, rhs in
      if lhs.matches(selection) != rhs.matches(selection) { return lhs.matches(selection) }
      return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
  }

  var body: some View {
    List {
      Section("Current session") {
        Text(configuration.modelLabel).textSelection(.enabled)
          .accessibilityIdentifier("model-current-value")
        if let raw = configuration.effectiveModel, raw != configuration.modelLabel {
          Text(raw).font(.caption).textSelection(.enabled)
        }
        if let raw = configuration.modelOverride,
          !configuration.models.contains(where: { $0.matches(raw) })
        {
          Text(
            "This identifier is not in the advertised catalog. It stays unchanged unless you choose another model."
          )
          .font(.footnote).foregroundStyle(.secondary)
        }
        if let disabledReason { Text(disabledReason).font(.footnote) }
        if usesHostPreview {
          Text(
            "Host preview; choices are revalidated before applying. The session runtime has not reported its catalog yet."
          )
          .font(.footnote).foregroundStyle(.secondary)
          .accessibilityIdentifier("model-host-preview")
        }
      }
      Section("Choose for this session") {
        option(
          "Harness default", detail: "Remove the explicit model override",
          selected: selection == nil && configuration.modelReported == true, id: "model-default"
        ) { choose(nil) }
        ForEach(choices) { model in
          option(
            model.title,
            detail: [model.value, model.description].compactMap { $0 }.joined(separator: "\n"),
            selected: model.matches(selection), id: "model-\(model.id)"
          ) { choose(model.value) }
        }
        if choices.isEmpty {
          Text(search.isEmpty ? "No model choices reported." : "No matching models.")
            .foregroundStyle(.secondary)
        }
      }.disabled(disabledReason != nil)
    }
    .navigationTitle("Model")
    .searchable(text: $search, prompt: "Search models")
  }

  private func option(
    _ title: String, detail: String, selected: Bool, id: String, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 5) {
          Text(title).foregroundStyle(.primary)
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        Spacer(minLength: 8)
        if selected { Image(systemName: "checkmark") }
      }.frame(minHeight: 44).contentShape(Rectangle())
    }.accessibilityIdentifier(id).accessibilityAddTraits(selected ? .isSelected : [])
  }
}
