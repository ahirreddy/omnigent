import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

@MainActor
struct HarnessSetupAdapterTests {
  private func catalog(_ availability: HarnessAvailability, install: Bool = true)
    -> HarnessSetupCatalog
  {
    HarnessSetupCatalog(
      harnessInstall: install, installableHarnesses: ["codex-native"],
      harnesses: [
        HarnessDefinition(
          id: "codex-native", label: "Codex",
          setupSteps: [
            SetupStep(
              kind: "install", title: "Install Codex", detail: "We'll install it.",
              action: "install", command: nil, statusKey: "installed"),
            SetupStep(
              kind: "auth", title: "Set up authentication", detail: "Sign in.", action: "auth",
              command: "codex login", statusKey: "authed"),
          ])
      ],
      hosts: [
        SetupHost(
          hostId: "h1", name: "Mac", status: "online", sandboxProvider: nil,
          harnesses: [HarnessAvailabilityEntry(harness: "codex-native", availability: availability)]
        )
      ])
  }

  private func sheet(_ catalog: HarnessSetupCatalog, detected: [DetectedCredential] = [])
    -> HarnessSetupSheetState
  {
    HarnessSetupAdapter.sheet(
      harnessSetupPlan(catalog: catalog, harness: "codex-native", hostId: "h1"),
      progress: HarnessSetupAdapter.Progress(catalog: .loaded(catalog), detected: detected))
  }

  @Test func missingHarnessOffersInstallThenLockedSignIn() {
    let state = sheet(catalog(.binaryMissing))
    #expect(state.name == "Codex")
    #expect(state.hostName == "Mac")
    #expect(state.steps.map(\.control) == [.install, .credential(enabled: false)])
    #expect(state.steps[1].loginCommand == "codex login")
  }

  @Test func installedHarnessOffersTheDetectedCredential() {
    let detected = [
      DetectedCredential(family: "anthropic", source: "$ANTHROPIC_API_KEY", envVar: "A"),
      DetectedCredential(family: "openai", source: "$OPENAI_API_KEY", envVar: "OPENAI_API_KEY"),
    ]
    let state = sheet(catalog(.needsAuth), detected: detected)
    #expect(state.steps.map(\.status) == [.done, .todo])
    #expect(state.adoptableSource == "$OPENAI_API_KEY")
    #expect(
      HarnessSetupAdapter.credential(.adopt, harness: "codex-native", detected: detected)
        == .adopt(envVar: "OPENAI_API_KEY"))
    #expect(
      HarnessSetupAdapter.credential(.adopt, harness: "codex-native", detected: []) == nil)
  }

  @Test func withoutTheFeatureStepsAreCommands() {
    let state = sheet(catalog(.binaryMissing, install: false))
    #expect(state.steps.map(\.control) == [.none, .command("codex login")])
    #expect(!state.needsOmniSetup)
  }

  @Test func loadingAndFailedCatalogsSaySo() {
    let loading = HarnessSetupAdapter.sheet(
      nil, progress: HarnessSetupAdapter.Progress(catalog: .loading))
    #expect(loading.isLoading)
    let failed = HarnessSetupAdapter.sheet(
      nil,
      progress: HarnessSetupAdapter.Progress(catalog: .failed(.InvalidState(message: "boom"))))
    #expect(!failed.isLoading)
    #expect(failed.errorMessage == "boom")
  }

  @Test func appliedReadinessUpdatesTheInventory() {
    let applied = harnessSetupCatalogApplying(
      catalog: catalog(.binaryMissing), hostId: "h1",
      harnesses: [HarnessAvailabilityEntry(harness: "codex-native", availability: .ready)])
    let rows = HarnessSetupAdapter.rows(harnessInventory(catalog: applied, hostId: "h1"))
    let codex = rows.first { $0.id == "codex-native" }
    #expect(codex?.isReady == true)
    #expect(codex?.status == "Configured")
    #expect(rows.first?.status == nil)
  }
}
