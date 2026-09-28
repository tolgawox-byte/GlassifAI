import AVFoundation
import Foundation
import Speech
import UIKit

/// Detects the wake phrase in a live transcript ("Hey Jarvis", "Jarvis,
/// what am I looking at?"). Whole words, case- and accent-insensitive, and
/// tolerant of split compounds ("auto loom" matches "AutoLoom").
enum WakePhraseMatcher {
  private static let greetings: Set<String> = ["hey", "hi", "ok", "okay", "hay", "hei", "hej"]

  /// Kept for the assistant-name checks: the name as a whole word (or words).
  static func contains(name: String, in transcript: String) -> Bool {
    matches(phrase: name, in: transcript)
  }

  /// True when the transcript contains the phrase. A phrase that starts with
  /// "hey"/"ok" also matches without it ("Jarvis" for "Hey Jarvis").
  static func matches(phrase: String, in transcript: String) -> Bool {
    var parts = words(phrase)
    guard parts.joined().count >= 3 else { return false }
    let spoken = words(transcript)
    if contains(parts, in: spoken) { return true }
    while let first = parts.first, greetings.contains(first), parts.count > 1 {
      parts.removeFirst()
    }
    return parts.joined().count >= 3 && contains(parts, in: spoken)
  }

  private static func contains(_ parts: [String], in spoken: [String]) -> Bool {
    guard !parts.isEmpty, !spoken.isEmpty else { return false }
    if spoken.count >= parts.count {
      for start in 0...(spoken.count - parts.count) where Array(spoken[start..<start + parts.count]) == parts {
        return true
      }
    }
    // Split or joined compounds: "auto loom" ↔ "autoloom".
    let target = parts.joined()
    for start in spoken.indices {
      var joined = ""
      for index in start..<spoken.count {
        joined += spoken[index]
        if joined == target { return true }
        if joined.count >= target.count { break }
      }
    }
    return false
  }

  static func words(_ text: String) -> [String] {
    text.lowercased(with: Locale(identifier: "tr_TR"))
      .replacingOccurrences(of: "ı", with: "i")
      .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
      .components(separatedBy: CharacterSet.alphanumerics.inverted)
      .filter { !$0.isEmpty }
  }
}

/// Wake phrase settings.
enum WakePhraseSettings {
  static let phraseKey = "autoloom.wake.phrase"
  static let backgroundKey = "autoloom.wake.background"
  static let readyMinutesKey = "autoloom.wake.readyMinutes"
  static let glassesArmingKey = "autoloom.wake.glassesArming"
  static let readyMinuteChoices = [15, 30, 60, 120]

  /// The phrase to listen for; defaults to "Hey <assistant name>".
  static var phrase: String {
    let stored = UserDefaults.standard.string(forKey: phraseKey)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    return stored.isEmpty ? "Hey \(AssistantIdentity.name)" : String(stored.prefix(40))
  }

  static func presets(name: String) -> [String] {
    var list = ["Hey \(name)", name]
    for extra in ["Hey AutoLoom", "Jarvis", "Hey Jarvis"] where !list.contains(extra) {
      list.append(extra)
    }
    return list
  }

  /// Hands-Free Ready: keep listening for the phrase while the app is in the
  /// background (the orange microphone indicator stays on).
  static var listensInBackground: Bool {
    UserDefaults.standard.bool(forKey: backgroundKey)
  }

  static var readyMinutes: Int {
    let stored = UserDefaults.standard.integer(forKey: readyMinutesKey)
    return stored > 0 ? stored : 60
  }

  /// Listen only while the Meta glasses report a connected link (a real
  /// SDK event; DAT 0.5.0 has no worn/unworn event).
  static var armsWithGlasses: Bool {
    UserDefaults.standard.bool(forKey: glassesArmingKey)
  }
}

/// Hands-free start by wake phrase, in on-device speech recognition only.
/// - App open: listens while armed and no conversation runs.
/// - Hands-Free Ready (opt-in): keeps listening in the background for a
///   limited time; iOS shows the orange microphone indicator the whole time.
/// Audio never leaves the phone while waiting, nothing is stored, and it
/// never runs without the visible indicator.
@MainActor
final class WakePhraseListener: ObservableObject {
  static let shared = WakePhraseListener()
  static let armedKey = "autoloom.wake.armed"

  enum Status: Equatable {
    case off
    case listening(background: Bool)
    case waitingForGlasses
    case paused(String)
    case unavailable(String)

    var label: String {
      switch self {
      case .off: L.t("Off", "Kapalı")
      case .listening(let background):
        background
          ? L.t("Hands-Free Ready (listening in the background)", "Eller serbest hazır (arka planda dinliyor)")
          : L.t("Listening for the wake phrase (on-device)", "Uyandırma ifadesi dinleniyor (cihazda)")
      case .waitingForGlasses: L.t("Waiting for the glasses to connect", "Gözlüğün bağlanması bekleniyor")
      case .paused(let reason): L.t("Paused — ", "Duraklatıldı — ") + reason
      case .unavailable(let reason): L.t("Unavailable — ", "Kullanılamıyor — ") + reason
      }
    }

    var isListening: Bool {
      if case .listening = self { return true }
      return false
    }
  }

  @Published private(set) var status: Status = .off
  @Published private(set) var detections = 0
  @Published private(set) var readySince: Date?
  @Published var isArmed: Bool {
    didSet {
      UserDefaults.standard.set(isArmed, forKey: Self.armedKey)
      readySince = nil
      Task { await refresh() }
    }
  }

  /// Whether a conversation is running (it owns the microphone then).
  var isConversationActive: () -> Bool = { false }
  /// Latest Meta glasses link state from the SDK (nil: unknown / no glasses).
  var glassesConnected: Bool? {
    didSet {
      guard glassesConnected != oldValue else { return }
      Task { await refresh() }
    }
  }

  /// Created only when listening actually starts, so a disarmed listener
  /// never touches the audio hardware (the voice call owns it).
  private var engine: AVAudioEngine?
  private var tapInstalled = false
  private var recognizer: SFSpeechRecognizer?
  private let feed = RecognitionFeed()
  private var task: SFSpeechRecognitionTask?
  private var restartTask: Task<Void, Never>?
  private var observers: [NSObjectProtocol] = []

  private init() {
    isArmed = UserDefaults.standard.bool(forKey: Self.armedKey)
    let center = NotificationCenter.default
    observers.append(center.addObserver(
      forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in self?.appDidEnterBackground() }
    })
    observers.append(center.addObserver(
      forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in await self?.refresh() }
    })
  }

  private var isBackground: Bool {
    UIApplication.shared.applicationState == .background
  }

  private func appDidEnterBackground() {
    guard isListening else { return }
    if WakePhraseSettings.listensInBackground {
      status = .listening(background: true)
      if readySince == nil { readySince = Date() }
    } else {
      stopListening(reason: nil, releaseAudioSession: true)
    }
  }

  /// Starts or stops listening to match the current state.
  func refresh() async {
    let conversation = isConversationActive()
    // The Hands-Free Ready time limit counts background time only.
    if !isBackground { readySince = nil }
    guard isArmed, !conversation else {
      if isListening { stopListening(reason: nil, releaseAudioSession: !conversation) }
      if !isArmed { status = .off }
      return
    }
    if WakePhraseSettings.armsWithGlasses, glassesConnected != true {
      if isListening { stopListening(reason: nil, releaseAudioSession: true) }
      status = .waitingForGlasses
      return
    }
    if isBackground && !WakePhraseSettings.listensInBackground {
      if isListening { stopListening(reason: nil, releaseAudioSession: true) }
      return
    }
    if let readySince, Date().timeIntervalSince(readySince) > Double(WakePhraseSettings.readyMinutes * 60) {
      if isListening { stopListening(reason: nil, releaseAudioSession: true) }
      status = .paused(L.t("time limit reached; open the app to resume", "süre doldu; devam için uygulamayı açın"))
      return
    }
    if isListening {
      status = .listening(background: isBackground)
      return
    }
    if isBackground, readySince == nil { readySince = Date() }
    // In the background this only works while iOS still lets the app use
    // the microphone (right after a hands-free conversation); otherwise it
    // pauses until the app is opened.
    await startListening()
  }

  /// Hands-Free Ready is on and the app is in the background: a finished
  /// conversation keeps the audio session so listening can resume.
  var keepsAudioSessionAfterConversation: Bool {
    isArmed && WakePhraseSettings.listensInBackground && isBackground
  }

  private var isListening: Bool {
    task != nil || tapInstalled || engine?.isRunning == true
  }

  private func startListening() async {
    let locale = Locale(identifier: "en-US")
    guard let recognizer = SFSpeechRecognizer(locale: locale), recognizer.isAvailable else {
      status = .unavailable(L.t("speech recognition is not available", "konuşma tanıma kullanılamıyor"))
      return
    }
    guard recognizer.supportsOnDeviceRecognition else {
      // Waiting for a phrase must never stream audio to a server.
      status = .unavailable(L.t("on-device recognition is not supported on this iPhone",
                                "bu iPhone cihaz üzerinde tanımayı desteklemiyor"))
      return
    }
    let speechAllowed = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
      SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
    }
    guard speechAllowed else {
      status = .unavailable(L.t("speech recognition permission denied", "konuşma tanıma izni yok"))
      return
    }
    guard await AVAudioApplication.requestRecordPermission() else {
      status = .unavailable(L.t("microphone permission denied", "mikrofon izni yok"))
      return
    }
    guard isArmed, !isConversationActive(), !isBackground || WakePhraseSettings.listensInBackground else { return }

    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetoothHFP, .mixWithOthers])
      try session.setActive(true)
      let engine = AVAudioEngine()
      self.engine = engine
      let input = engine.inputNode
      let format = input.outputFormat(forBus: 0)
      guard format.sampleRate > 0, format.channelCount > 0 else {
        stopListening(reason: L.t("no microphone input available", "mikrofon girişi yok"))
        return
      }
      let feed = self.feed
      input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
        feed.append(buffer)
      }
      tapInstalled = true
      engine.prepare()
      try engine.start()
      self.recognizer = recognizer
      beginRecognition()
      status = .listening(background: isBackground)
    } catch {
      if isBackground {
        stopListening(reason: nil, releaseAudioSession: true)
        status = .paused(L.t("iOS stopped the microphone in the background; open the app to resume",
                             "iOS arka planda mikrofonu durdurdu; devam için uygulamayı açın"))
      } else {
        stopListening(reason: L.t("audio could not start", "ses başlatılamadı"))
      }
    }
  }

  /// A fresh recognition request on the running microphone. Recognition
  /// sessions are bounded, so this repeats; the microphone keeps running,
  /// which lets it continue in the background.
  private func beginRecognition() {
    guard let recognizer, tapInstalled else { return }
    task?.cancel()
    let request = SFSpeechAudioBufferRecognitionRequest()
    request.requiresOnDeviceRecognition = true
    request.shouldReportPartialResults = true
    let phrase = WakePhraseSettings.phrase
    request.contextualStrings = [phrase, AssistantIdentity.name, "Hey \(AssistantIdentity.name)"]
    feed.set(request)
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString ?? ""
      let finished = error != nil || (result?.isFinal ?? false)
      Task { @MainActor in self?.handle(text: text, finished: finished) }
    }
    restartTask?.cancel()
    restartTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: 50_000_000_000)
      guard !Task.isCancelled else { return }
      self?.recycleRecognition()
    }
  }

  private func recycleRecognition() {
    guard isListening else { return }
    if let readySince, Date().timeIntervalSince(readySince) > Double(WakePhraseSettings.readyMinutes * 60) {
      stopListening(reason: nil, releaseAudioSession: true)
      status = .paused(L.t("time limit reached; open the app to resume", "süre doldu; devam için uygulamayı açın"))
      return
    }
    feed.finish()
    beginRecognition()
  }

  private func handle(text: String, finished: Bool) {
    guard task != nil else { return }
    if WakePhraseMatcher.matches(phrase: WakePhraseSettings.phrase, in: text) {
      detections += 1
      stopListening(reason: nil)
      readySince = nil
      Task { await VoiceStartCoordinator.shared.request(.wakePhrase) }
      return
    }
    if finished {
      recycleRecognition()
    }
  }

  func stopListening(reason: String?, releaseAudioSession: Bool = false) {
    let wasListening = isListening
    restartTask?.cancel()
    restartTask = nil
    task?.cancel()
    task = nil
    feed.finish()
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
    } else if case .paused = status {
      // Keep the explanation visible.
    } else {
      status = .off
    }
  }
}

/// Hands audio buffers from the realtime audio thread to the current
/// recognition request. Swapping the request never touches the microphone.
private final class RecognitionFeed: @unchecked Sendable {
  private let lock = NSLock()
  private var request: SFSpeechAudioBufferRecognitionRequest?

  func set(_ request: SFSpeechAudioBufferRecognitionRequest) {
    lock.lock()
    let previous = self.request
    self.request = request
    lock.unlock()
    previous?.endAudio()
  }

  func append(_ buffer: AVAudioPCMBuffer) {
    lock.lock()
    request?.append(buffer)
    lock.unlock()
  }

  func finish() {
    lock.lock()
    let previous = request
    request = nil
    lock.unlock()
    previous?.endAudio()
  }
}
