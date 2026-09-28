import AVFoundation
import Foundation
import Speech
import UIKit

/// Detects the assistant's name in a live transcript ("Jarvis", "Hey Jarvis",
/// "Jarvis, what am I looking at?"). Word-boundary match, case- and
/// accent-insensitive.
enum WakePhraseMatcher {
  static func contains(name: String, in transcript: String) -> Bool {
    let needle = fold(name)
    guard needle.count >= 3 else { return false }
    let words = fold(transcript)
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
    let parts = needle.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    guard !parts.isEmpty, words.count >= parts.count else { return false }
    for start in 0...(words.count - parts.count) where Array(words[start..<start + parts.count]) == parts {
      return true
    }
    return false
  }

  private static func fold(_ text: String) -> String {
    text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
  }
}

/// Mode B, "app-armed listening": while the app is open on screen and the
/// user has armed it, on-device speech recognition listens for the
/// assistant's name and then starts a conversation. It never runs in the
/// background, never sends audio anywhere while waiting (on-device
/// recognition only, or it does not run), and shows a visible indicator.
@MainActor
final class WakePhraseListener: ObservableObject {
  static let shared = WakePhraseListener()
  static let armedKey = "autoloom.wake.armed"

  enum Status: Equatable {
    case off
    case listening
    case unavailable(String)

    var label: String {
      switch self {
      case .off: "Off"
      case .listening: "Listening for the name (on-device)"
      case .unavailable(let reason): "Unavailable — \(reason)"
      }
    }
  }

  @Published private(set) var status: Status = .off
  @Published private(set) var detections = 0
  @Published var isArmed: Bool {
    didSet {
      UserDefaults.standard.set(isArmed, forKey: Self.armedKey)
      Task { await refresh() }
    }
  }

  /// Whether a conversation is running (it owns the microphone then).
  var isConversationActive: () -> Bool = { false }

  /// Created only when listening actually starts, so a disarmed listener
  /// never touches the audio hardware (the voice call owns it).
  private var engine: AVAudioEngine?
  private var tapInstalled = false
  private var recognizer: SFSpeechRecognizer?
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var restartTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  private init() {
    isArmed = UserDefaults.standard.bool(forKey: Self.armedKey)
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.stopListening(reason: nil, releaseAudioSession: true) }
    })
    observers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    })
  }

  /// Starts or stops listening to match the current state: armed, app on
  /// screen, and no conversation running.
  func refresh() async {
    guard isArmed, UIApplication.shared.applicationState == .active, !isConversationActive() else {
      if isListening { stopListening(reason: nil, releaseAudioSession: !isConversationActive()) }
      if !isArmed, case .unavailable = status { status = .off }
      return
    }
    guard !isListening else { return }
    await startListening()
  }

  private var isListening: Bool {
    task != nil || tapInstalled || engine?.isRunning == true
  }

  private func startListening() async {
    let locale = Locale(identifier: "en-US")
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      status = .unavailable("speech recognition is not available")
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      // Waiting for a name must never stream audio to a server.
      status = .unavailable("on-device recognition is not supported on this iPhone")
      return
    }
    let speechAllowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
    }
    guard speechAllowed else {
      status = .unavailable("speech recognition permission denied")
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      status = .unavailable("microphone permission denied")
      return
    }
    guard isArmed, UIApplication.shared.applicationState == .active, !isConversationActive() else { return }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers])
      try session.setActive(true)
      let request = SFSpeechAudioBufferRecognitionRequest()
      request.requiresOnDeviceRecognition = true
      request.shouldReportPartialResults = true
      let name = AssistantIdentity.name
      request.contextualStrings = [name, "Hey \(name)"]
      let engine = AVAudioEngine()
      self.engine = engine
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        stopListening(reason: "no microphone input available")
        return
      }
      input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
        request.append(buffer)
      }
      tapInstalled = true
      engine.prepare()
      try engine.start()
      self.recognizer = recognizer
      self.request = request
      task = recognizer.recognitionTask(with: request) { [weak self] result, error in
        let text = result?.bestTranscription.formattedString ?? ""
        let finished = error != nil || (result?.isFinal ?? false)
        Task { @MainActor in self?.handle(text: text, finished: finished) }
      }
      status = .listening
      // Recognition sessions are bounded; start a fresh one periodically.
      restartTask?.cancel()
      restartTask = Task { [weak self] in
        try? await Task.sleep(nanoseconds: 50_000_000_000)
        guard !Task.isCancelled else { return }
        self?.stopListening(reason: nil)
        await self?.refresh()
      }
    } catch {
      stopListening(reason: "audio could not start")
    }
  }

  private func handle(text: String, finished: Bool) {
    guard task != nil else { return }
    if WakePhraseMatcher.contains(name: AssistantIdentity.name, in: text) {
      detections += 1
      stopListening(reason: nil)
      Task { await VoiceStartCoordinator.shared.request(.wakePhrase) }
      return
    }
    if finished {
      stopListening(reason: nil)
      Task { [weak self] in
        try? await Task.sleep(nanoseconds: 300_000_000)
        await self?.refresh()
      }
    }
  }

  func stopListening(reason: String?, releaseAudioSession: Bool = false) {
    let wasListening = isListening
    restartTask?.cancel()
    restartTask = nil
    task?.cancel()
    task = nil
    request?.endAudio()
    request = nil
    if let engine {
      if engine.isRunning { engine.stop() }
      if tapInstalled { engine.inputNode.removeTap(onBus: 0) }
    }
    tapInstalled = false
    engine = nil
    // Only a session this listener activated, never a running call's.
    if releaseAudioSession && wasListening && !isConversationActive() {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    if let reason {
      status = .unavailable(reason)
    } else if case .unavailable = status {
      // Keep the explanation visible.
    } else {
      status = .off
    }
  }
}
