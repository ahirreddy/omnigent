#if os(macOS)
  import Foundation
  import SwiftUI
  import Testing

  @testable import OmnigentUIComponents

  @Suite("New session, fork and project screens with hostile data", .serialized)
  struct NewSessionScreensRenderTests {
    nonisolated static let screens: [ScreenCase] = [
      ScreenCase("options-realistic", height: nil, realistic: true) {
        NewSessionOptionsBar(options: realisticOptions, actions: optionActions)
      },
      ScreenCase("options-empty", height: nil, realistic: true, narrowOnly: true) {
        NewSessionOptionsBar(options: NewSessionOptions(), actions: NewSessionOptionActions())
      },
      ScreenCase("options-sandbox", height: nil, narrowOnly: true) {
        var options = NewSessionOptions(
          isSandbox: true, repositories: realisticRepositories, profiles: SandboxProfilesState())
        options.projects = ["Docs"]
        return NewSessionOptionsBar(options: options, actions: optionActions)
      },
      ScreenCase("options-hostile", height: nil) {
        NewSessionOptionsBar(options: hostileOptions, actions: optionActions)
      },
      ScreenCase("options-sandbox-hostile", height: nil, narrowOnly: true) {
        NewSessionOptionsBar(
          options: NewSessionOptions(
            isSandbox: true, repositories: hostileRepositories, profiles: hostileProfiles),
          actions: optionActions)
      },
      ScreenCase("repositories-realistic", height: nil, realistic: true) {
        SandboxRepositoriesEditor(state: realisticRepositories, actions: repositoryActions)
      },
      ScreenCase("repositories-empty", height: nil, realistic: true, narrowOnly: true) {
        SandboxRepositoriesEditor(state: SandboxRepositoriesState(), actions: repositoryActions)
      },
      // A provider whose limit is zero or negative must still draw.
      ScreenCase("repositories-no-limit", height: nil, narrowOnly: true) {
        SandboxRepositoriesEditor(
          state: SandboxRepositoriesState(maxRepos: -1, problem: ""), actions: repositoryActions)
      },
      ScreenCase("repositories-hostile") {
        ScrollView {
          SandboxRepositoriesEditor(state: hostileRepositories, actions: repositoryActions)
        }
      },
      ScreenCase("fork-options-realistic", realistic: true) {
        GroupedFormHost {
          ForkOptionsSections(
            options: realisticFork, actions: forkActions, startsOnHost: true, harness: "codex",
            choices: .constant(forkChoices()))
        }
      },
      ScreenCase("fork-options-empty", realistic: true, narrowOnly: true) {
        GroupedFormHost {
          ForkOptionsSections(
            options: ForkOptions(), actions: ForkActions(forkWith: { _ in }, cancel: {}),
            startsOnHost: false,
            choices: .constant(ForkChoices(agentID: "", directory: "", start: false)))
        }
      },
      ScreenCase("fork-options-sandbox", narrowOnly: true) {
        GroupedFormHost {
          ForkOptionsSections(
            options: realisticFork, actions: forkActions, startsOnHost: false, harness: "cursor",
            choices: .constant(forkChoices(sandbox: true)))
        }
      },
      ScreenCase("fork-options-hostile") {
        GroupedFormHost {
          ForkOptionsSections(
            options: hostileFork, actions: forkActions, startsOnHost: true,
            harness: HostileData.unbroken,
            choices: .constant(forkChoices(sandbox: true, model: "0")))
        }
      },
      ScreenCase("project-settings-realistic", realistic: true) {
        ProjectSettingsSheet(
          state: realisticProject, draft: .constant(ProjectSettingsDraft()),
          actions: projectActions)
      },
      ScreenCase("project-settings-loading", narrowOnly: true) {
        ProjectSettingsSheet(
          state: ProjectSettingsViewState(projectName: "", phase: .loading),
          draft: .constant(ProjectSettingsDraft()), actions: projectActions)
      },
      ScreenCase("project-settings-failed", narrowOnly: true) {
        ProjectSettingsSheet(
          state: ProjectSettingsViewState(
            projectName: HostileData.unbroken, phase: .failed(HostileData.unbroken)),
          draft: .constant(ProjectSettingsDraft()), actions: projectActions)
      },
      ScreenCase("project-settings-hostile") {
        ProjectSettingsSheet(
          state: hostileProject, draft: .constant(hostileProjectDraft), actions: projectActions)
      },
      // Only the host: the sheet itself is private, and presenting it would show a window.
      ScreenCase("project-dialogs-closed", height: nil, realistic: true, narrowOnly: true) {
        Text("Host")
          .modifier(
            ProjectDialogs(
              prompt: .constant(nil), name: .constant(HostileData.unbroken),
              confirmingDelete: .constant(nil),
              actions: SidebarActions(sessions: SessionListActions())))
      },
    ]

    @Test("renders without crashing or hanging", arguments: screens)
    func render(screen: ScreenCase) throws {
      try ScreenRenderer.check(screen)
    }

    @Test("a chosen repository's branches load when its row appears")
    func loadsBranches() throws {
      var loaded: [String] = []
      let actions = SandboxRepositoriesActions(
        setRepos: { _ in }, urlProblem: { _, _ in nil }, branchProblem: { _, _ in nil },
        repoName: { $0 }, isSameRepo: { $0 == $1 }, loadBranches: { loaded.append($0) })
      _ = try RenderSupport.render(
        SandboxRepositoriesEditor(state: Self.realisticRepositories, actions: actions), width: 700,
        scheme: .light, layout: .regular)
      #expect(loaded == ["acme/app"], "only a GitHub repository has branches to read")
    }
  }

  extension NewSessionScreensRenderTests {
    private static let repositoryActions = SandboxRepositoriesActions(
      setRepos: { _ in }, urlProblem: { _, _ in nil }, branchProblem: { _, _ in nil },
      repoName: { $0 }, isSameRepo: { $0 == $1 }, loadBranches: { _ in })

    private static var optionActions: NewSessionOptionActions {
      var actions = NewSessionOptionActions(
        selectFolder: { _ in },
        browse: { _ in .failure(FolderBrowseError(message: "unused")) },
        selectWorktree: { _ in }, isValidBranch: { _ in true }, repositories: repositoryActions,
        profiles: SandboxProfilesActions(select: { _ in }), setUpHarness: {})
      actions.selectProject = { _ in }
      return actions
    }

    private static var forkActions: ForkActions {
      var actions = ForkActions(forkWith: { _ in }, cancel: {})
      actions.repositories = repositoryActions
      actions.profiles = SandboxProfilesActions(select: { _ in })
      return actions
    }

    private static var realisticRepositories: SandboxRepositoriesState {
      SandboxRepositoriesState(
        repos: [
          SandboxRepoChoice(url: "https://github.com/acme/app.git", branch: "main"),
          SandboxRepoChoice(url: "https://example.com/other.git"),
        ], maxRepos: 3,
        githubRepos: [
          GithubRepoOption(
            fullName: "acme/app", cloneURL: "https://github.com/acme/app.git",
            defaultBranch: "main", isPrivate: true),
          GithubRepoOption(
            fullName: "acme/web", cloneURL: "https://github.com/acme/web.git", defaultBranch: nil,
            isPrivate: false),
        ], branches: ["acme/app": ["main", "dev"]])
    }

    private static var hostileRepositories: SandboxRepositoriesState {
      var branches: [String: [String]] = [:]
      let github = (0..<HostileData.rowCount).map { index in
        GithubRepoOption(
          fullName: "\(index)\(HostileData.text(index))", cloneURL: "\(index)",
          defaultBranch: index.isMultiple(of: 2) ? nil : HostileData.text(index),
          isPrivate: index.isMultiple(of: 2))
      }
      branches[github[0].fullName] = (0..<HostileData.rowCount).map(HostileData.text)
      let notes = Dictionary(
        uniqueKeysWithValues: (0..<HostileData.rowCount).map { ("\($0)", HostileData.text($0)) })
      return SandboxRepositoriesState(
        // More than the limit, and the same address twice.
        repos: (0..<HostileData.formRowCount).map {
          SandboxRepoChoice(url: "\($0 % 20)", branch: HostileData.text($0))
        }, maxRepos: 1, githubRepos: github, githubTruncated: true,
        githubError: HostileData.bidirectional, branches: branches, notes: notes,
        problem: HostileData.controlCharacters)
    }

    private static var hostileProfiles: SandboxProfilesState {
      let profiles = (0..<HostileData.rowCount).map { index in
        SandboxProfileOption(
          id: "\(index)", name: HostileData.text(index), description: HostileData.text(index + 1),
          revision: HostileData.text(index + 2))
      }
      return SandboxProfilesState(
        profiles: profiles, selected: profiles[3], isLoading: true,
        error: HostileData.unbroken, hasMore: true)
    }

    private static var realisticOptions: NewSessionOptions {
      var options = NewSessionOptions(
        folder: "/Users/ahir/src/omnigent", recentFolders: ["/Users/ahir/src/web"],
        offersWorktrees: true,
        worktrees: [NewSessionWorktreeOption(path: "/tmp/w", branch: "feature")],
        worktree: .new(branch: "feature/sidebar", base: "main"),
        harnessNotice: "Codex isn't ready on ahir-mbp.", setUpName: "Codex", isPlanMode: true)
      options.project = "Docs"
      options.projects = ["Docs", "Web"]
      return options
    }

    private static var hostileOptions: NewSessionOptions {
      var options = NewSessionOptions(
        folder: HostileData.unbroken,
        recentFolders: (0..<HostileData.rowCount).map(HostileData.text),
        offersWorktrees: true,
        worktrees: (0..<HostileData.rowCount).map {
          NewSessionWorktreeOption(
            path: "\($0)", branch: $0.isMultiple(of: 2) ? nil : HostileData.text($0))
        },
        worktree: .existing(NewSessionWorktreeOption(path: HostileData.unbroken, branch: nil)),
        harnessNotice: HostileData.bidirectional, setUpName: HostileData.unbroken, isPlanMode: true,
        defaultBaseBranch: HostileData.controlCharacters)
      options.project = HostileData.unbroken
      options.projects = (0..<HostileData.rowCount).map(HostileData.text)
      return options
    }

    private static var realisticFork: ForkOptions {
      var options = ForkOptions(
        hosts: [
          ForkHostOption(id: "h1", name: "ahir-mbp"),
          ForkHostOption(id: "h2", name: "lab", unavailableReason: "Offline"),
        ], offersSandbox: true,
        sandboxes: [ForkSandboxOption(provider: "modal", label: "Modal Sandbox")],
        repositories: realisticRepositories,
        models: [
          ModelOption(
            id: "m1", displayName: "Opus", supportedReasoningEfforts: ["low", "high"],
            isDefault: true),
          ModelOption(id: "hidden", hidden: true),
        ],
        approvalModes: [
          "a1": [
            ApprovalModeOption(id: "ask", label: "Ask", detail: "Asks first"),
            ApprovalModeOption(id: "full", label: "Full access", risk: .fullAccess),
          ]
        ])
      options.harnessNames = ["a1": "Codex"]
      return options
    }

    private static var hostileFork: ForkOptions {
      let modes = (0..<HostileData.rowCount).map { index in
        ApprovalModeOption(
          id: "\(index)", label: HostileData.text(index), detail: HostileData.text(index + 1),
          risk: .fullAccess)
      }
      return ForkOptions(
        hosts: (0..<HostileData.rowCount).map {
          ForkHostOption(id: "\($0)", name: HostileData.text($0), unavailableReason: "x")
        }, offersSandbox: true,
        sandboxes: (0..<HostileData.rowCount).map {
          ForkSandboxOption(provider: "\($0)", label: HostileData.text($0))
        }, repositories: hostileRepositories, isCheckingBranches: false, profiles: hostileProfiles,
        models: (0..<HostileData.rowCount).map { index in
          ModelOption(
            id: "\(index)", displayName: HostileData.text(index),
            supportedReasoningEfforts: index == 0 ? (0..<50).map(HostileData.text) : [])
        }, approvalModes: ["a1": modes])
    }

    private static func forkChoices(sandbox: Bool = false, model: String? = "m1") -> ForkChoices {
      var choices = ForkChoices(agentID: "a1", directory: "/tmp", start: true, hostID: "h1")
      choices.isSandbox = sandbox
      choices.model = model
      choices.approvalMode = "full"
      return choices
    }

    private static var realisticProject: ProjectSettingsViewState {
      var state = ProjectSettingsViewState(projectName: "Docs", phase: .loaded)
      state.hosts = [ProjectSettingsChoice(id: "h1", title: "ahir-mbp")]
      state.hostTakesFolder = true
      state.agents = [ProjectSettingsChoice(id: "a1", title: "Codex")]
      state.showsModel = true
      state.models = [ProjectSettingsChoice(id: "m1", title: "gpt-5-codex")]
      state.showsEffort = true
      state.efforts = [ProjectSettingsChoice(id: "high", title: "High")]
      return state
    }

    private static var hostileProject: ProjectSettingsViewState {
      let choices = (0..<HostileData.rowCount).map {
        ProjectSettingsChoice(id: "\($0)", title: HostileData.text($0))
      }
      var state = ProjectSettingsViewState(projectName: HostileData.bidirectional, phase: .loaded)
      state.hosts = choices
      state.hostTakesFolder = true
      state.agents = choices
      state.showsModel = true
      state.models = choices
      state.showsEffort = true
      state.efforts = choices
      state.isSaving = true
      state.saveError = HostileData.bidirectional
      return state
    }

    private static var hostileProjectDraft: ProjectSettingsDraft {
      var draft = ProjectSettingsDraft()
      draft.hostID = "missing"
      draft.workspace = HostileData.unbroken
      draft.useWorktree = true
      draft.baseBranch = HostileData.controlCharacters
      draft.agentID = "missing"
      draft.model = HostileData.unbroken
      draft.effort = ""
      return draft
    }

    private static let projectActions = ProjectSettingsActions(save: {}, cancel: {})
  }

  @Suite("New session and project labels")
  struct NewSessionLabelTests {
    @Test("the worktree chip names the choice, the branch before the path")
    func worktreeTitle() {
      var options = NewSessionOptions()
      #expect(options.worktreeTitle == "No worktree")
      options.worktree = .new(branch: "", base: "")
      #expect(options.worktreeTitle == "New branch: ")
      options.worktree = .existing(NewSessionWorktreeOption(path: "/tmp/w", branch: nil))
      #expect(options.worktreeTitle == "Worktree: /tmp/w")
      options.worktree = .existing(NewSessionWorktreeOption(path: "/tmp/w", branch: "dev"))
      #expect(options.worktreeTitle == "Worktree: dev")
    }

    @Test("the repositories chip counts them past one")
    func repositoriesLabel() {
      var state = SandboxRepositoriesState()
      #expect(state.label { $0 } == "No repository")
      state.repos = [SandboxRepoChoice(url: "a")]
      #expect(state.label { "name of \($0)" } == "name of a")
      state.repos.append(SandboxRepoChoice(url: "a"))
      #expect(state.label { $0 } == "2 repositories")
    }

    @Test("the profile chip says why nothing is chosen, the choice winning over all of it")
    func profileLabel() {
      var state = SandboxProfilesState()
      #expect(state.label == "No profiles available")
      state.profiles = [SandboxProfileOption(id: "p", name: "Large", revision: "1")]
      #expect(state.label == "Choose profile")
      state.error = "x"
      #expect(state.label == "Profiles unavailable")
      state.isLoading = true
      #expect(state.label == "Loading profiles\u{2026}")
      state.selected = state.profiles[0]
      #expect(state.label == "Large")
    }

    @Test("the project prompt's identity tells its sessions and projects apart")
    func projectPromptIdentity() {
      let session = SessionSummary(id: "s", title: "S")
      let project = SessionProject(id: "p", name: "P", sessionIds: [])
      #expect(ProjectPrompt.create(moving: nil).id == "create-")
      #expect(ProjectPrompt.create(moving: session).id == "create-s")
      #expect(ProjectPrompt.rename(project).id == "rename-p")
    }

    @Test("a policy filter matches name or description, and blank matches everything")
    func policyFilter() {
      let template = PolicyTemplate(
        id: "h", name: "Ask before pushing", detail: "Pauses a push", suggestedName: "", params: [])
      #expect(template.matches("") && template.matches("  \t"))
      #expect(template.matches("ASK") && template.matches(" pauses "))
      #expect(!template.matches("merge"))
      #expect(!template.matches(HostileData.unbroken))
      #expect(!template.matches(HostileData.bidirectional))
    }
  }
#endif
