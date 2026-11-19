import SwiftUI

/// The harness page's tab picker: MCP servers, Skills and Plugins with their counts, then
/// Settings.
struct HarnessCatalogTabs: View {
  let catalog: HarnessCatalogState
  @Binding var tab: HarnessCatalogState.Tab

  var body: some View {
    Section {
      Picker("View", selection: $tab) {
        ForEach(HarnessCatalogState.Tab.allCases) { Text(catalog.label($0)).tag($0) }
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .accessibilityIdentifier("harness-catalog-tabs")
    }
  }
}

/// One of the lists: the servers, the skills or the plugins, or what shows instead.
struct HarnessCatalogList: View {
  let catalog: HarnessCatalogState
  let tab: HarnessCatalogState.Tab
  let openSkill: (@MainActor (HarnessCatalogState.Skill) -> Void)?
  let openPlugin: @MainActor (HarnessCatalogState.Plugin) -> Void

  var body: some View {
    Section {
      switch tab {
      case .mcpServers:
        if let text = catalog.serversNotice {
          notice(text)
        } else {
          ForEach(catalog.servers) { HarnessServerRow(server: $0) }
        }
      case .skills:
        if let text = catalog.skillsNotice {
          notice(text)
        } else {
          ForEach(catalog.skills) { HarnessSkillRow(skill: $0, open: openSkill) }
        }
      case .plugins:
        if let text = catalog.pluginsNotice {
          notice(text)
        } else {
          ForEach(catalog.plugins) { plugin in
            Button {
              openPlugin(plugin)
            } label: {
              HStack(spacing: Theme.Spacing.medium) {
                Image(systemName: "powerplug").foregroundStyle(.secondary).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                  Text(plugin.name)
                  Text(
                    [plugin.detail, plugin.description].compactMap(\.self).joined(
                      separator: " \u{00B7} ")
                  )
                  .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(
                  true)
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("harness-plugin-\(plugin.name)")
          }
        }
      case .settings:
        EmptyView()
      }
    }
    .accessibilityIdentifier("harness-catalog-\(tab.rawValue)")
  }

  private func notice(_ text: String) -> some View {
    Text(text).foregroundStyle(.secondary)
  }
}

/// An MCP server: its symbol, name and detail, dimmed with "Off" when turned off.
struct HarnessServerRow: View {
  let server: HarnessCatalogState.Server

  var body: some View {
    HStack(spacing: Theme.Spacing.medium) {
      Image(systemName: "server.rack").foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(server.title)
        let detail = [server.detail, server.isOff ? "Off" : nil].compactMap(\.self)
        if !detail.isEmpty {
          Text(detail.joined(separator: " \u{00B7} ")).font(.caption).foregroundStyle(.secondary)
        }
      }
    }
    .opacity(server.isOff ? 0.5 : 1)
    .accessibilityElement(children: .combine)
    .accessibilityIdentifier("harness-mcp-\(server.id)")
  }
}

/// A skill: its name and description, a button to its page where the harness has one.
struct HarnessSkillRow: View {
  let skill: HarnessCatalogState.Skill
  let open: (@MainActor (HarnessCatalogState.Skill) -> Void)?

  var body: some View {
    let label = HStack(spacing: Theme.Spacing.medium) {
      Image(systemName: "sparkle").foregroundStyle(.secondary).accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 2) {
        Text(skill.title)
        if !skill.description.isEmpty {
          Text(skill.description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
        }
      }
      Spacer()
      if skill.opens, open != nil {
        Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
      }
    }
    .contentShape(Rectangle())
    if skill.opens, let open {
      Button {
        open(skill)
      } label: {
        label
      }
      .buttonStyle(.plain)
      .accessibilityIdentifier("harness-skill-\(skill.name)")
    } else {
      label.accessibilityIdentifier("harness-skill-\(skill.name)")
    }
  }
}

/// A plugin's page: its detail, then its skills or its MCP servers.
struct HarnessPluginPage: View {
  let plugin: HarnessCatalogState.Plugin
  let back: @MainActor () -> Void
  let openSkill: (@MainActor (HarnessCatalogState.Skill) -> Void)?
  @State private var showsServers = false

  var body: some View {
    Section {
      VStack(alignment: .leading, spacing: Theme.Spacing.small) {
        Text(plugin.name).font(.title3.weight(.semibold))
        Text(plugin.detail).font(.caption).foregroundStyle(.secondary)
        if let description = plugin.description { Text(description) }
      }
      Picker("Plugin view", selection: $showsServers) {
        Text("Skills \u{00B7} \(plugin.skills.count)").tag(false)
        Text("MCPs \u{00B7} \(plugin.servers.count)").tag(true)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    } header: {
      Button("Plugins", systemImage: "chevron.left", action: back)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("harness-plugin-back")
    }
    Section {
      if showsServers {
        if let notice = plugin.serversNotice { Text(notice).foregroundStyle(.secondary) }
        if plugin.servers.isEmpty {
          Text("No MCPs found.").foregroundStyle(.secondary)
        }
        ForEach(plugin.servers) { HarnessServerRow(server: $0) }
      } else if let notice = plugin.skillsNotice {
        Text(notice).foregroundStyle(.secondary)
      } else if plugin.skills.isEmpty {
        Text("No skills found.").foregroundStyle(.secondary)
      } else {
        ForEach(plugin.skills) { HarnessSkillRow(skill: $0, open: openSkill) }
      }
    }
    .accessibilityIdentifier("harness-plugin-page")
  }
}

/// A skill's page: its description and contents, as the chat renders Markdown.
struct HarnessSkillPage: View {
  let page: HarnessSkillPageState
  let back: @MainActor () -> Void

  var body: some View {
    Section {
      Text(page.name).font(.title3.weight(.semibold))
      if let notice = page.notice {
        Text(notice).foregroundStyle(.secondary)
      } else if !page.description.isEmpty {
        Text(page.description)
      }
    } header: {
      Button(page.backTitle, systemImage: "chevron.left", action: back)
        .buttonStyle(.borderless)
        .accessibilityIdentifier("harness-skill-back")
    }
    if page.notice == nil {
      Section("Contents") {
        if page.truncated {
          Text("Contents truncated (256 KiB limit).").font(.caption).foregroundStyle(.secondary)
        }
        MarkdownView(page.content)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
      .accessibilityIdentifier("harness-skill-page")
    }
  }
}
