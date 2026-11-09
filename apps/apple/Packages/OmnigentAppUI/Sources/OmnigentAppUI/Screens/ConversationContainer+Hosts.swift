import Foundation
import OmnigentCoreFFI
import OmnigentStores
import OmnigentUIComponents

/// The reconnect sheet's ways out (Switch Host, Resume on a Machine) and the error card's
/// sign-in link and recovery fork.
extension ConversationContainer {
  /// Adds Switch Host for an owned session whose host is offline, Resume on a Machine for an
  /// owned session bound to no host, and the conversation's sheet state.
  func addHostMoves(to actions: inout SessionLivenessActions, sheets: SessionLivenessSheets) {
    actions.sheets = sheets
    guard let header = conversation.header else { return }
    let liveness = LivenessAdapter.liveness(
      header, runnerUnavailable: conversation.runnerUnavailable != nil)
    if case .hostOffline(isOwner: true) = liveness {
      actions.switchHost = HostMoveRoute(
        kind: .switchHost(currentHostID: header.settings?.hostId),
        actions: hostMoveActions(submit: switchHost))
    }
    if LivenessAdapter.resumesOnMachine(header) {
      let workspace = summary?.workspace
      actions.resume = HostMoveRoute(
        kind: .resume(
          preferredHostID: nil, workspace: workspace?.hasPrefix("/") == true ? workspace : nil),
        actions: hostMoveActions { await resumeOnHost($0, sheets: sheets) })
    }
  }

  /// A send into a session bound to no host opens Resume on a Machine first, as the web's
  /// does; the draft stays and is sent once the session starts.
  /// - Returns: Whether the send waits for the sheet.
  func holdsSendForResume(_ sheets: SessionLivenessSheets) -> Bool {
    guard let header = conversation.header, LivenessAdapter.resumesOnMachine(header),
      LivenessAdapter.liveness(header, runnerUnavailable: conversation.runnerUnavailable != nil)
        == .stranded
    else { return false }
    sheets.sendsDraftOnResume = true
    sheets.shown = .resume
    return true
  }

  private func hostMoveActions(
    submit: @escaping @MainActor (HostMoveChoice) async -> HostMoveOutcome
  ) -> HostMoveActions {
    let conversation = conversation
    return HostMoveActions(
      loadHosts: {
        do throws(CoreError) {
          return .success(
            try await conversation.hosts().map {
              HostMoveTarget(id: $0.hostId, name: $0.name, isOnline: $0.isAvailable)
            })
        } catch {
          return .failure(FolderBrowseError(message: error.message))
        }
      },
      home: { hostID in
        do throws(CoreError) {
          return try await conversation.hostDirectory(hostID: hostID, path: nil).path
        } catch {
          // Without the home the directory starts empty for the user to type or browse.
          return nil
        }
      },
      browse: { hostID, path in
        do throws(CoreError) {
          return .success(
            NewSessionAdapter.listing(
              try await conversation.hostDirectory(hostID: hostID, path: path)))
        } catch {
          return .failure(FolderBrowseError(message: error.message))
        }
      },
      submit: submit)
  }

  private func switchHost(_ choice: HostMoveChoice) async -> HostMoveOutcome {
    do throws(CoreError) {
      let launch = try await conversation.switchHost(
        to: choice.hostID, workspace: choice.workspace)
      if case .failed(let error) = launch { return .stranded(error.message) }
      return .moved
    } catch {
      return .failed(error.message)
    }
  }

  private func resumeOnHost(
    _ choice: HostMoveChoice, sheets: SessionLivenessSheets
  ) async -> HostMoveOutcome {
    let git =
      choice.branch.isEmpty
      ? nil
      : CreationGit(
        branchName: choice.branch, baseBranch: choice.baseBranch.isEmpty ? nil : choice.baseBranch,
        existingWorktree: false)
    do throws(CoreError) {
      try await conversation.resume(onHost: choice.hostID, workspace: choice.workspace, git: git)
    } catch {
      return .failed(error.message)
    }
    if sheets.sendsDraftOnResume {
      sheets.sendsDraftOnResume = false
      sendDraft()
    }
    return .moved
  }

  /// The error card's Open Sign-In Link: asks the host for the live prompt and opens its page
  /// in the browser.
  var openSignIn: @MainActor () async -> SignInOutcome {
    let conversation = conversation
    return {
      let link: SessionSignInLink
      do throws(CoreError) {
        link = try await conversation.signInLink()
      } catch {
        return .failed(error.message)
      }
      guard link.pending, let url = link.url.flatMap(URL.init(string:)) else { return .notPending }
      guard await signInOpener.open(url) else {
        return .failed("The browser did not open \(url.absoluteString).")
      }
      return .opened(code: link.code)
    }
  }

  /// The error card's fork past a failure only a new session gets past.
  func addRecoveryFork(to actions: inout ConversationActions) {
    guard let source = forkSource else { return }
    actions.forkToRecover = { elsewhere in
      beginFork(
        ForkContext(
          source: source, upToResponseID: nil, kind: elsewhere ? .anotherDirectory : .session))
    }
  }
}
