#if os(iOS)
  import AVFoundation
  import Observation
  import Speech

  /// Dictation into the composer on iPhone and iPad, where apps cannot start the keyboard's own:
  /// the microphone through on-device speech recognition, the words appended to the draft as
  /// they are recognized. Mic (or ⌥⌘V) starts it and again stops it.
  @Observable
  final class SpeechDictation {
    /// The app's one dictation: there is one microphone.
    static let shared = SpeechDictation()

    /// Listening now.
    private(set) var isListening = false
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    /// Starts listening, or stops when already listening.
    /// - Parameter update: Receives the words recognized so far.
    /// - Returns: Why dictation could not start, or `nil`.
    func toggle(update: @escaping @MainActor (String) -> Void) async -> String? {
      if isListening {
        stop()
        return nil
      }
      guard await Self.authorized() else {
        return "Allow Omnigent to use the microphone and speech recognition in Settings to dictate."
      }
      guard let recognizer = SFSpeechRecognizer(), recognizer.isAvailable else {
        return "Dictation is unavailable right now."
      }
      do {
        try start(recognizer, update: update)
        return nil
      } catch {
        stop()
        return "Dictation could not start: \(error.localizedDescription)"
      }
    }

    private func start(
      _ recognizer: SFSpeechRecognizer, update: @escaping @MainActor (String) -> Void
    ) throws {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.record, mode: .measurement, options: .duckOthers)
      try session.setActive(true, options: .notifyOthersOnDeactivation)
      let engine = AVAudioEngine()
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.shouldReportPartialResults = true
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.tap(request))
      engine.prepare()
      try engine.start()
      self.engine = engine
      self.request = request
      isListening = true
      task = recognizer.recognitionTask(with: request) { [weak self] result, error in
        let text = result?.bestTranscription.formattedString
        let finished = error != nil || result?.isFinal == true
        Task { @MainActor in
          if let text { update(text) }
          if finished { self?.stop() }
        }
      }
    }

    /// Stops listening and releases the microphone.
    func stop() {
      engine?.stop()
      engine?.inputNode.removeTap(onBus: 0)
      request?.endAudio()
      task?.finish()
      engine = nil
      request = nil
      task = nil
      if isListening { isListening = false }
      do {
        try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      } catch {
        // Another app's audio keeps the session; nothing to undo here.
        return
      }
    }

    /// `words` after the draft that was there when dictation started.
    static func appending(_ words: String, to base: String) -> String {
      guard !base.isEmpty, base.last?.isWhitespace == false else { return base + words }
      return base + " " + words
    }

    /// The microphone tap, which runs on the audio thread, so it must not be main-actor
    /// isolated.
    nonisolated private static func tap(
      _ request: SFSpeechAudioBufferRecognitionRequest
    ) -> AVAudioNodeTapBlock {
      { buffer, _ in request.append(buffer) }
    }

    private static func authorized() async -> Bool {
      let speech = await withCheckedContinuation { continuation in
        // The system answers on a queue of its own.
        SFSpeechRecognizer.requestAuthorization { @Sendable status in
          continuation.resume(returning: status)
        }
      }
      guard speech == .authorized else { return false }
      return await AVAudioApplication.requestRecordPermission()
    }
  }
#endif
