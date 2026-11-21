import OmnigentCoreFFI
import OmnigentUIComponents
import Testing

@testable import OmnigentAppUI

/// A remote browser tab's badge: the user's own control, else the agent's DevTools activity that
/// the host reports in its control state.
struct RemoteTabAgentBadgeTests {
  private func control(_ owner: ControlOwner, _ agent: RemoteBrowserAgentActivity?)
    -> RemoteBrowserControl
  {
    RemoteBrowserControl(owner: owner, holder: .nobody, userId: nil, handoff: nil, agent: agent)
  }

  @Test func theUsersControlOutranksTheAgentsActivity() {
    #expect(TabAdapter.remoteAgentControl(nil) == nil)
    #expect(TabAdapter.remoteAgentControl(control(.agent, nil)) == nil)
    #expect(TabAdapter.remoteAgentControl(control(.agent, .active)) == .active)
    #expect(TabAdapter.remoteAgentControl(control(.agent, .idle)) == .idle)
    #expect(TabAdapter.remoteAgentControl(control(.user, .active)) == .user)
  }
}
