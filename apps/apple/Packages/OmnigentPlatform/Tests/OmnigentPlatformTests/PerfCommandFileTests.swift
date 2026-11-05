#if DEBUG
  import Testing

  @testable import OmnigentPlatform

  @MainActor
  struct PerfCommandFileTests {
    @Test func readsSequencedCommandsInOrder() {
      let commands = PerfCommandFile.commands(in: "1 begin\n2 scroll\n\nbad\n3 settings.usage \n")
      #expect(commands.map(\.sequence) == [1, 2, 3])
      #expect(commands.map(\.name) == ["begin", "scroll", "settings.usage"])
    }
  }
#endif
