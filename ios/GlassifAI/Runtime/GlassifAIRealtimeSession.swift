import AVFoundation
import Combine
import Foundation
import LiveKitWebRTC
import QuartzCore
import UIKit

@MainActor
final class GlassifAIRealtimeSession: NSObject, ObservableObject {
  enum State: Equatable {
    case disconnected
    case connecting
    case listening
    case thinking
    case speaking
    case failed(String)
  }

  /// Which realtime configuration the current call was started with.
  enum StartMode: String {
    case autoloom = "AutoLoom instructions (v2)"
    case baselineFallback = "Baseline fallback (v1)"
  }

  @Published private(set) var state: State = .disconnected
  @Published private(set) var userTranscript = ""
  @Published private(set) var assistantCaption = ""
  @Published private(set) var isMicrophoneMuted = false
  @Published private(set) var sidebandStatus = "idle"
  @Published private(set) var startMode: StartMode?
  @Published private(set) var lastRealtimeError: String?
  @Published private(set) var isAssistantAudioSuppressed = false
  /// Tap (or invocation) to listening, for the last successful start.
  @Published private(set) var lastConnectMs: Int?
  /// End of the user's turn to the first words of the answer (median of
  /// recent turns).
  @Published private(set) var responseLatencyMedianMs: Int?
  @Published private(set) var reconnectCount = 0
  @Published private(set) var lastReconnectReason: String?
  /// What the last start asked for and what it really got: voice, model and
  /// the reason for any fallback. Shown as "Selected" and "Active" voice.
  @Published private(set) var startReport: RealtimeStartReport?
  /// The voice being previewed from Settings, if any.
  @Published private(set) var previewingVoice: String?
  /// Why the last conversation ended by itself (quiet period, voice command).
  @Published private(set) var lastEndReason: String?

  var isActive: Bool {
    switch state {
    case .connecting, .listening, .thinking, .speaking: true
    case .disconnected, .failed: false
    }
  }

  private let factory = LKRTCPeerConnectionFactory()
  private var peer: LKRTCPeerConnection?
  /// Samples the microphone and assistant voice levels for the orb.
  private var levelSamplerTask: Task<Void, Never>?
  private var dataChannel: LKRTCDataChannel?
  private var audioTrack: LKRTCAudioTrack?
  private var audioRouteObserver: NSObjectProtocol?
  private var prefersBluetoothHFP = false
  private var forcesBuiltInAudio = false
  private var sidebandEventTask: Task<Void, Never>?
  private var audioSuppressionTask: Task<Void, Never>?
  private var streamingCaptionRole = ""
  private var streamingCaptionMessageId = ""
  private var streamingCaptionText = ""
  private var userTurnOpen = false
  private var assistantTurnOpen = false
  private let orchestrator = AssistantOrchestrator.shared
  private var connectStartedAt: CFTimeInterval?
  private var userTurnEndedAt: CFTimeInterval?
  private var responseLatencies: [Double] = []
  /// Audio preferences of the running call, reused when reconnecting.
  private var callAudio: (prefersBluetoothHFP: Bool, forcesBuiltInAudio: Bool)?
  private var reconnectPolicy = RealtimeReconnectPolicy()
  private var isReconnecting = false
  /// Voice for a preview session instead of the saved voice.
  private var voiceOverride: String?
  private var isPreviewSession = false
  /// Ends a preview, or the conversation after a spoken end command.
  private var autoStopTask: Task<Void, Never>?
  private var pendingHangUp = false
  /// A stop word silenced the answer during the current user turn.
  private var stopWordMutedTurn = false
  private var lastActivityAt = Date()
  private var idleMonitorTask: Task<Void, Never>?

  /// Where the current start is, and every step of the last start
  /// (Settings → Developer → Voice diagnostics).
  @Published private(set) var connectionPhase: ConnectionPhase = .idle
  @Published private(set) var connectionSteps: [ConnectionStep] = []
  /// The audio route when the conversation became ready.
  @Published private(set) var readyRoute: String?
  /// Settings are being applied by a restart (no new greeting).
  private var isRestarting = false

  /// A user turn the app handles itself (a note, a reminder, a memory…).
  /// The voice model's own reply to that turn stays muted; the app's result
  /// is spoken instead — through the model's delegation for the same turn
  /// when it made one, otherwise as speakable context. One request, one
  /// answer.
  private struct TurnInterception {
    let turn: Int
    var result: String?
    var handoffID: String?
    /// The model finished (or never started) its own reply to the turn.
    var modelReplyDone = false
    var delivered = false
    /// Unmute when the muted reply's turn ends.
    var releaseAfterTurn = false
    /// A new user turn began; later delegations are not this turn's.
    var acceptsDelegations = true
  }

  private var interception: TurnInterception?
  private var interceptionTimer: Task<Void, Never>?
  /// The assistant's audio is held for an interception; the usual turn
  /// events do not release it.
  private var holdsAssistantAudio = false
  /// Held early because the partial transcript already began with a command.
  private var preHeldForCommand = false
  /// Delegations that arrived before the user's final transcript.
  private var deferredDelegations: [(handoffID: String, request: String)] = []
  private var deferredFlushTask: Task<Void, Never>?
  private var answeredHandoffs = Set<String>()
  /// Counts final user turns; a late delegation for an intercepted turn is
  /// answered without running the request twice.
  private var userTurnSerial = 0
  private var lastInterceptedTurn: Int?
  /// The last delegation the voice model made (to spot one that arrived
  /// before the final transcript of the same request).
  private var recentDelegation: (at: Date, request: String, handoffID: String)?
  /// When the current user turn began, and whether the assistant was still
  /// talking then (a barge-in).
  private var userTurnOpenedAt: Date?
  private var userTurnBargedIn = false
  /// The user's last partial words, to tell when they stopped talking.
  private var lastUserPartialAt = Date.distantPast
  /// The answer began before the user's final transcript (the transcription
  /// runs separately): the partial words are used once they are stable.
  private var earlyFinalTask: Task<Void, Never>?
  /// A turn handled from its partial words; its late final only corrects it.
  private var earlyFinal: (text: String, handled: Bool, at: Date)?
  /// This connection sends `turn.done`; the older transcript events finish
  /// a turn only when it never does.
  private var sawTurnDone = false
  private var lastLegacyFinal: (text: String, at: Date)?

  /// - Parameters:
  ///   - greeting: a line said right after connecting (voice previews).
  ///   - reason: how a new conversation was started; it decides the ready
  ///     announcement. nil for reconnects, restarts and previews.
  func start(
    prefersBluetoothHFP: Bool = false,
    forcesBuiltInAudio: Bool = false,
    greeting: String? = nil,
    reason: VoiceStartReason? = nil
  ) async {
    guard !isActive else { return }
    // Every start path frees the wake phrase listener's microphone first.
    WakePhraseListener.shared.stopListening(reason: nil)
    let freshConversation = !isReconnecting && !isRestarting && !isPreviewSession
    state = .connecting
    connectStartedAt = CACurrentMediaTime()
    connectionSteps = []
    readyRoute = nil
    markPhase(reason == .wakePhrase || reason == .metaInvocation ? .wakeDetected : .preparingAudio,
              detail: reason?.rawValue ?? (isReconnecting ? "reconnect" : isPreviewSession ? "voice preview" : "restart"))
    callAudio = (prefersBluetoothHFP, forcesBuiltInAudio)
    userTranscript = ""
    // A voice preview only speaks; it never listens.
    isMicrophoneMuted = isPreviewSession
    lastEndReason = nil
    pendingHangUp = false
    stopWordMutedTurn = false
    assistantCaption = ""
    streamingCaptionRole = ""
    streamingCaptionMessageId = ""
    streamingCaptionText = ""
    userTurnOpen = false
    assistantTurnOpen = false
    lastRealtimeError = nil
    isAssistantAudioSuppressed = false
    resetInterception()
    _ = orchestrator.beginVoiceSession()
    if freshConversation { orchestrator.beginConversation() }
    AudioRouteMonitor.shared.onMediaServicesReset = { [weak self] in
      Task { @MainActor in await self?.handleMediaServicesReset() }
    }

    do {
      self.forcesBuiltInAudio = forcesBuiltInAudio
      markPhase(.preparingAudio)
      try configureAudioSession(prefersBluetoothHFP: prefersBluetoothHFP)
      let configuration = LKRTCConfiguration()
      configuration.sdpSemantics = .unifiedPlan
      configuration.bundlePolicy = .maxBundle
      configuration.continualGatheringPolicy = .gatherContinually
      let constraints = LKRTCMediaConstraints(
        mandatoryConstraints: nil,
        optionalConstraints: ["DtlsSrtpKeyAgreement": "true"])
      guard let peer = factory.peerConnection(
        with: configuration,
        constraints: constraints,
        delegate: self) else {
        throw RealtimeError.peerCreationFailed
      }
      self.peer = peer

      let audioConstraints = LKRTCMediaConstraints(
        mandatoryConstraints: [
          "googEchoCancellation": "true",
          "googAutoGainControl": "true",
          "googNoiseSuppression": "true",
        ],
        optionalConstraints: nil)
      let source = factory.audioSource(with: audioConstraints)
      let audioTrack = factory.audioTrack(with: source, trackId: "glassifai-audio")
      self.audioTrack = audioTrack
      audioTrack.isEnabled = !isMicrophoneMuted
      guard peer.add(audioTrack, streamIds: ["glassifai"]) != nil else {
        throw RealtimeError.audioTrackFailed
      }

      let videoTransceiver = LKRTCRtpTransceiverInit()
      videoTransceiver.direction = .sendOnly
      guard peer.addTransceiver(of: .video, init: videoTransceiver) != nil else {
        throw RealtimeError.peerCreationFailed
      }

      let channelConfiguration = LKRTCDataChannelConfiguration()
      channelConfiguration.isOrdered = true
      channelConfiguration.isNegotiated = true
      channelConfiguration.channelId = 0
      guard let channel = peer.dataChannel(forLabel: "", configuration: channelConfiguration) else {
        throw RealtimeError.dataChannelFailed
      }
      channel.delegate = self
      dataChannel = channel

      markPhase(.connectingRealtime)
      let offer = try await createOffer(peer: peer, constraints: constraints)
      try await setLocalDescription(offer, peer: peer)
      for _ in 0..<25 where peer.iceGatheringState != .complete {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      let localSDP = peer.localDescription?.sdp ?? offer.sdp
      let answerSDP = try await createDirectRealtimeCall(sdp: localSDP)
      let answer = LKRTCSessionDescription(type: .answer, sdp: answerSDP)
      try await setRemoteDescription(answer, peer: peer)

      markPhase(.waitingForDataChannel, detail: "session accepted")
      for _ in 0..<100 where channel.readyState != .open {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      guard channel.readyState == .open else { throw RealtimeError.connectionTimedOut }
      markPhase(.routingAudio, detail: "data channel open")
      let route = await waitForAudioRoute(prefersGlasses: prefersBluetoothHFP && !forcesBuiltInAudio)
      readyRoute = route
      state = .listening
      if let connectStartedAt {
        lastConnectMs = Int(((CACurrentMediaTime() - connectStartedAt) * 1_000).rounded())
        startReport?.connectMs = lastConnectMs
      }
      markPhase(.ready, detail: route)
      startSidebandEventLoop()
      noteActivity()
      startIdleMonitor()
      startLevelSampler()
      orchestrator.speakInConversation = { [weak self] text in
        self?.sayAppMessage(text) ?? false
      }
      if let greeting {
        _ = sayExactly(greeting)
      } else if freshConversation, let reason {
        announceReady(for: reason)
      } else if isReconnecting, ConnectionFeedback.current.playsChime {
        // A reconnect is not a new conversation: at most a subtle chime.
        ChimePlayer.shared.play(.reconnected)
      }
    } catch {
      await tearDown()
      let message = LogSanitizer.sanitize(error.localizedDescription)
      lastRealtimeError = message
      state = .failed(message)
      markPhase(.failed, detail: LogSanitizer.sanitize(message, limit: 120))
      if isReconnecting { orchestrator.finishConversation() }
      if !isPreviewSession, reason != nil || isReconnecting {
        announceFailure(ConnectionFeedback.failureText(turkish: L.isTurkish))
      }
    }
  }

  // MARK: Connection feedback

  private func markPhase(_ phase: ConnectionPhase, detail: String? = nil) {
    connectionPhase = phase
    let elapsed = connectStartedAt.map { Int(((CACurrentMediaTime() - $0) * 1_000).rounded()) } ?? 0
    connectionSteps.append(ConnectionStep(phase: phase, atMs: elapsed, detail: detail))
    NSLog("[AutoLoom] connection %@ at %d ms%@", phase.rawValue, elapsed, detail.map { " (\($0))" } ?? "")
  }

  /// Waits briefly for the microphone route, and for the glasses' hands-free
  /// route when they are preferred. Returns a short description.
  private func waitForAudioRoute(prefersGlasses: Bool) async -> String {
    let session = AVAudioSession.sharedInstance()
    for _ in 0..<15 {
      let route = session.currentRoute
      let glasses = route.inputs.contains { $0.portType == .bluetoothHFP }
        || route.outputs.contains { $0.portType == .bluetoothHFP }
      if !route.inputs.isEmpty && (!prefersGlasses || glasses) {
        return glasses ? "Bluetooth HFP" : route.outputs.first?.portType.rawValue ?? "audio"
      }
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
    let output = session.currentRoute.outputs.first?.portType.rawValue ?? "none"
    return prefersGlasses ? "glasses route not selected; using \(output)" : output
  }

  /// A new conversation is ready: chime and/or the chosen phrase, once;
  /// then, once a day and only if turned on, the daily briefing.
  private func announceReady(for reason: VoiceStartReason) {
    let feedback = ConnectionFeedback.current
    if feedback.playsChime { ChimePlayer.shared.play(.ready) }
    if let phrase = ConnectionFeedback.readyPhrase(for: reason, turkish: L.isTurkish) {
      // Said by the voice model itself: hearing it proves the whole path
      // (ChatGPT, WebRTC, audio route) works.
      _ = sayExactly(phrase)
    }
    guard DailyBriefing.isDue() else { return }
    DailyBriefing.markGiven()
    Task { @MainActor [weak self] in
      guard let self else { return }
      let outcome = await self.orchestrator.runVoiceIntent(
        VoiceBridgeDecision(.routine(.briefing), "daily briefing (first conversation today)"),
        transcript: "daily briefing")
      _ = self.sayAppMessage(outcome.spoken)
    }
  }

  /// A start failed or the call could not be restored: a low tone and a
  /// short sentence from the on-device voice, never silence.
  private func announceFailure(_ text: String) {
    guard ConnectionFeedback.current != .off else { return }
    ChimePlayer.shared.play(.failed)
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 450_000_000)
      LocalAnnouncer.shared.say(text, turkish: L.isTurkish)
    }
  }

  /// The glasses' link dropped during a conversation.
  func announceGlassesDisconnected() {
    let text = ConnectionFeedback.glassesLostText(turkish: L.isTurkish)
    if isConnected, sayExactly(text) { return }
    LocalAnnouncer.shared.say(text, turkish: L.isTurkish)
  }

  /// Speakable context arrives as a user-role item, so a line the model
  /// must say is phrased as an instruction from the app.
  @discardableResult
  private func sayExactly(_ line: String) -> Bool {
    sayAppMessage("Say exactly these words and nothing else: \"\(line)\"")
  }

  /// Sends a message from the app (not the user) that the model answers
  /// aloud, for example the result of a command the app handled.
  @discardableResult
  private func sayAppMessage(_ text: String) -> Bool {
    guard isConnected else { return false }
    return EmbeddedCodexBridge.appendContext("[App message, not the user speaking] " + text, speakable: true)
  }

  func stop() async {
    let endsConversation = !isPreviewSession && (isActive || callAudio != nil)
    callAudio = nil
    sendEvent(["type": "session.close"])
    await tearDown()
    state = .disconnected
    connectionPhase = .idle
    if endsConversation { orchestrator.finishConversation() }
    // In the background the screen's state observers may not run, so the
    // wake phrase listener is asked to take the microphone back. The short
    // delay lets an immediate restart (camera switch) claim it first.
    Task { @MainActor in
      try? await Task.sleep(nanoseconds: 400_000_000)
      await WakePhraseListener.shared.refresh()
    }
  }

  /// Whether a call is established (not merely starting).
  private var isConnected: Bool {
    switch state {
    case .listening, .thinking, .speaking: true
    default: false
    }
  }

  /// A running call broke (network switch, ICE failure, task channel ended,
  /// iOS audio reset). Reconnects automatically within a small budget and
  /// resumes with the conversation summary; otherwise asks for a tap. Runs
  /// in its own task, so it never inherits the cancelled event loop.
  private func handleMidCallFailure(reason: String, userMessage: String) {
    guard !isReconnecting else { return }
    if isPreviewSession {
      // A broken preview simply ends; it is never reconnected.
      Task { @MainActor [weak self] in await self?.stop() }
      return
    }
    isReconnecting = true
    Task { @MainActor [weak self] in
      await self?.reconnect(reason: reason, userMessage: userMessage)
    }
  }

  private func reconnect(reason: String, userMessage: String) async {
    defer { isReconnecting = false }
    let audio = callAudio
    await tearDown()
    lastRealtimeError = LogSanitizer.sanitize(reason, limit: 160)
    guard let audio, reconnectPolicy.allowsReconnect(now: Date()) else {
      state = .failed(userMessage)
      markPhase(.failed, detail: "reconnect budget used")
      orchestrator.finishConversation()
      announceFailure(ConnectionFeedback.failureText(turkish: L.isTurkish))
      return
    }
    reconnectPolicy.record(Date())
    reconnectCount += 1
    lastReconnectReason = LogSanitizer.sanitize(reason, limit: 120)
    NSLog("[AutoLoom] realtime reconnect %d: %@", reconnectCount, LogSanitizer.sanitize(reason, limit: 120))
    state = .connecting
    try? await Task.sleep(nanoseconds: RealtimeReconnectPolicy.delayNanoseconds)
    // The user ended the call while waiting.
    guard state == .connecting, callAudio != nil else { return }
    state = .disconnected
    await start(prefersBluetoothHFP: audio.prefersBluetoothHFP, forcesBuiltInAudio: audio.forcesBuiltInAudio)
  }

  /// Stops the current spoken answer. The V3 protocol has no interrupt
  /// message (barge-in is handled server-side when the user talks), so the
  /// app also silences the assistant's audio locally until the user speaks
  /// again or the interrupted turn ends.
  func stopSpeaking() {
    sendEvent([
      "type": "action_request",
      "payload": ["action": "stop_speaking"],
    ])
    suppressAssistantAudio()
    if isActive { state = .listening }
  }

  func toggleMicrophoneMuted() {
    guard isActive, !isPreviewSession else { return }
    isMicrophoneMuted.toggle()
    audioTrack?.isEnabled = !isMicrophoneMuted
  }

  /// Restarts the running conversation so a changed voice, name or style
  /// applies now instead of from the next conversation. The new session
  /// resumes from the conversation summary.
  func restartToApplySettings() async {
    guard isConnected, !isPreviewSession, let audio = callAudio else { return }
    isRestarting = true
    defer { isRestarting = false }
    await tearDown()
    state = .disconnected
    await start(prefersBluetoothHFP: audio.prefersBluetoothHFP, forcesBuiltInAudio: audio.forcesBuiltInAudio)
  }

  /// Speaks one short line in `voice` so the user can hear it before
  /// choosing. Only while no conversation runs; the microphone stays off and
  /// the preview ends by itself.
  func previewVoice(_ voice: String) async {
    guard !isActive else { return }
    let source = orchestrator.captureSource()
    let route = AudioRoutePreference.current
    voiceOverride = voice
    isPreviewSession = true
    previewingVoice = voice
    let line = VoicePreview.greeting(name: AssistantIdentity.name, voice: voice, turkish: L.isTurkish)
    await start(
      prefersBluetoothHFP: route.prefersGlassesAudio(for: source),
      forcesBuiltInAudio: route == .iPhone,
      greeting: line)
    guard isActive, isPreviewSession else { return }
    scheduleAutoStop(afterSeconds: 12)
  }

  private func scheduleAutoStop(afterSeconds seconds: Double) {
    autoStopTask?.cancel()
    autoStopTask = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      guard !Task.isCancelled else { return }
      await self?.stop()
    }
  }

  /// Tries the most complete configuration first and records why any step
  /// fails, so a fallback is visible (Selected vs Active voice) instead of
  /// silently speaking with another voice.
  private func createDirectRealtimeCall(sdp: String) async throws -> String {
    let tokens = try await ChatGPTAuthSession.shared.freshTokens()
    let requestedVoice = voiceOverride ?? AssistantPreferences.voice
    let resume = isPreviewSession ? nil : orchestrator.context.resumeSummary()
    // Session resume: the profile, a few relevant memories and the last
    // conversation's summary; never a raw transcript.
    let store = MemoryStore.shared
    let recent = isPreviewSession ? nil : store.recentConversationSummary().map {
      "\($0.createdAt.formatted(date: .abbreviated, time: .shortened)): \($0.text)"
    }
    let instructions = AssistantInstructions.realtime(
      memory: isPreviewSession ? [] : store.promptItems,
      profileName: isPreviewSession || !store.isEnabled ? nil : store.profile.preferredName,
      recentConversation: recent,
      smartMemory: store.isEnabled && store.smartMemoryEnabled)
    var report = RealtimeStartReport(requestedVoice: requestedVoice, requestedModel: ModelSelector.realtimeModel)
    report.isPreview = isPreviewSession
    var lastError: String?
    for step in RealtimeStartLadder.steps(requestedVoice: requestedVoice, hasResume: resume != nil) {
      if let lastError, RealtimeStartLadder.shouldSkip(step, after: lastError) { continue }
      let result: EmbeddedCodexResult
      let sentVoice: String
      if step == .baseline {
        sentVoice = VoiceCatalog.defaultVoice
        result = try await EmbeddedCodexBridge.startRealtime(tokens: tokens, sdp: sdp)
      } else {
        var options = RealtimeStartOptions()
        options.instructions = instructions
        options.model = ModelSelector.realtimeModel
        sentVoice = step == .defaultVoice ? VoiceCatalog.defaultVoice : requestedVoice
        options.voice = sentVoice
        if step == .full, let resume {
          options.initialItems = [RealtimeStartOptions.Item(role: "developer", text: resume)]
        }
        result = try await EmbeddedCodexBridge.startRealtime(tokens: tokens, sdp: sdp, options: options)
      }
      if result.ok, let answer = result.sdp, Self.isAnswerSDP(answer) {
        report.step = step
        report.activeVoice = result.voice ?? sentVoice
        report.activeModel = result.model ?? ModelSelector.realtimeModel
        if let note = result.voiceNote { report.attempts.append(LogSanitizer.sanitize(note, limit: 160)) }
        startReport = report
        startMode = step == .baseline ? .baselineFallback : .autoloom
        if step != .full {
          NSLog("[AutoLoom] realtime started with fallback step %@ (voice %@)", step.rawValue, report.activeVoice ?? "?")
        }
        return answer
      }
      let error = result.error ?? (result.ok ? "the answer was not a valid session description" : "no answer")
      lastError = error
      report.attempts.append("\(step.rawValue): \(LogSanitizer.sanitize(error, limit: 160))")
      if report.fallbackReason == nil { report.fallbackReason = RealtimeStartLadder.reason(from: error) }
      NSLog("[AutoLoom] realtime start step %@ failed: %@", step.rawValue, LogSanitizer.sanitize(error, limit: 200))
    }
    startReport = report
    throw RealtimeError.signalingFailed(
      "Could not start ChatGPT voice. \(LogSanitizer.sanitize(lastError ?? "Unknown error"))")
  }

  private static func isAnswerSDP(_ sdp: String?) -> Bool {
    sdp?.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("v=0") == true
  }

  private func startSidebandEventLoop() {
    sidebandEventTask?.cancel()
    sidebandEventTask = Task { [weak self] in
      var ticks = 0
      while !Task.isCancelled {
        while let event = EmbeddedCodexBridge.nextSidebandEvent() {
          self?.handleDelegation(event)
        }
        if ticks.isMultiple(of: 10) {
          let status = EmbeddedCodexBridge.sidebandStatus()
          self?.sidebandStatus = LogSanitizer.sanitize(status, limit: 160)
          if EmbeddedCodexBridge.isSidebandTerminal(status) {
            self?.handleMidCallFailure(
              reason: "task channel \(status)",
              userMessage: "The assistant's task channel disconnected. Tap to reconnect.")
            return
          }
        }
        ticks += 1
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  private func handleDelegation(_ event: [String: Any]) {
    guard let item = event["item"] as? [String: Any],
          item["type"] as? String == "delegation",
          item["target"] as? String == "client",
          let handoffId = item["id"] as? String else { return }
    let content = item["content"] as? [[String: Any]] ?? []
    let request = content.compactMap { entry -> String? in
      guard entry["type"] as? String == "input_text" else { return nil }
      return entry["text"] as? String
    }.joined()
    guard !answeredHandoffs.contains(handoffId) else { return }
    if userTurnOpen {
      // The user's words are not final yet; the app may be about to handle
      // this request itself, so decide right after the final transcript.
      if !deferredDelegations.contains(where: { $0.handoffID == handoffId }) {
        deferredDelegations.append((handoffId, request))
      }
      // The model already decided the turn is over. When the words so far
      // are an explicit command the app runs itself ("not al: …"), the turn
      // ends here from them: the app saves the note and answers this
      // delegation with the result, so the model's own routing (a memory, a
      // reminder) can never replace the user's verb. A late final
      // transcript only corrects the text.
      if !isPreviewSession, !pendingHangUp, !userTranscript.isEmpty,
         orchestrator.bridgeDecision(for: userTranscript) != nil {
        NSLog("[AutoLoom] delegation during an open turn that is a command: finishing the turn now")
        finalizeUserTurnEarly()
        return
      }
      deferredFlushTask?.cancel()
      deferredFlushTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled else { return }
        self?.flushDeferredDelegations()
      }
      return
    }
    routeDelegation(handoffId: handoffId, request: request)
  }

  private func flushDeferredDelegations() {
    deferredFlushTask?.cancel()
    deferredFlushTask = nil
    let pending = deferredDelegations
    deferredDelegations = []
    for delegation in pending {
      routeDelegation(handoffId: delegation.handoffID, request: delegation.request)
    }
  }

  private func routeDelegation(handoffId: String, request: String) {
    guard !answeredHandoffs.contains(handoffId) else { return }
    if var current = interception, current.acceptsDelegations {
      answeredHandoffs.insert(handoffId)
      if current.handoffID == nil, !current.delivered {
        // The model delegated the request the app is already doing: its
        // result will answer this delegation instead of running it twice.
        current.handoffID = handoffId
        interception = current
        noteActivity()
        NSLog("[AutoLoom] delegation matched to the command the app is handling")
        deliverInterceptionIfReady()
      } else {
        _ = EmbeddedCodexBridge.completeDelegation(
          handoffId: handoffId,
          text: "The app is already handling this request and tells the user the result. Say nothing more about it.")
      }
      return
    }
    if let turn = lastInterceptedTurn, turn == userTurnSerial {
      answeredHandoffs.insert(handoffId)
      _ = EmbeddedCodexBridge.completeDelegation(
        handoffId: handoffId,
        text: "The app already did this and told the user. Say nothing more about it.")
      return
    }
    releaseAssistantAudio()
    noteActivity()
    recentDelegation = (Date(), request, handoffId)
    orchestrator.handleDelegation(handoffID: handoffId, text: request) { [weak self] text in
      let delivered = EmbeddedCodexBridge.completeDelegation(handoffId: handoffId, text: text)
      if !delivered {
        self?.handleMidCallFailure(
          reason: "delegation result could not be delivered",
          userMessage: "The assistant's task channel disconnected. Tap to reconnect.")
      }
      return delivered
    }
  }

  private func handleMediaServicesReset() async {
    guard isActive else { return }
    handleMidCallFailure(
      reason: "iOS restarted the audio system",
      userMessage: "iOS restarted the audio system. Tap to reconnect.")
  }

  /// WebRTC's own statistics carry an `audioLevel` for the microphone
  /// (media-source) and the assistant's voice (inbound-rtp). Read about
  /// eight times a second, only while the app is on screen; the orb reads
  /// the smoothed value every frame.
  private func startLevelSampler() {
    levelSamplerTask?.cancel()
    levelSamplerTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 125_000_000)
        guard let self, let peer = self.peer else { return }
        guard UIApplication.shared.applicationState == .active else { continue }
        peer.statistics { @Sendable report in
          var input: Double?
          var output: Double?
          for stat in report.statistics.values {
            guard let level = (stat.values["audioLevel"] as? NSNumber)?.doubleValue else { continue }
            if stat.type == "media-source" {
              input = max(input ?? 0, level)
            } else if stat.type == "inbound-rtp" {
              output = max(output ?? 0, level)
            }
          }
          AudioLevelMeter.shared.update(input: input, output: output)
        }
      }
    }
  }

  private func tearDown() async {
    levelSamplerTask?.cancel()
    levelSamplerTask = nil
    AudioLevelMeter.shared.reset()
    sidebandEventTask?.cancel()
    sidebandEventTask = nil
    audioSuppressionTask?.cancel()
    audioSuppressionTask = nil
    idleMonitorTask?.cancel()
    idleMonitorTask = nil
    autoStopTask?.cancel()
    autoStopTask = nil
    pendingHangUp = false
    stopWordMutedTurn = false
    resetInterception()
    orchestrator.speakInConversation = nil
    voiceOverride = nil
    isPreviewSession = false
    previewingVoice = nil
    isAssistantAudioSuppressed = false
    isMicrophoneMuted = false
    orchestrator.endVoiceSession()
    EmbeddedCodexBridge.closeRealtime()
    dataChannel?.delegate = nil
    dataChannel?.close()
    dataChannel = nil
    audioTrack?.isEnabled = false
    audioTrack = nil
    peer?.delegate = nil
    peer?.close()
    peer = nil
    if let audioRouteObserver {
      NotificationCenter.default.removeObserver(audioRouteObserver)
      self.audioRouteObserver = nil
    }
    prefersBluetoothHFP = false
    forcesBuiltInAudio = false
    // Hands-Free Ready in the background keeps the session so the wake
    // phrase listener can take the microphone back.
    if !WakePhraseListener.shared.keepsAudioSessionAfterConversation {
      try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    AudioRouteMonitor.shared.refresh()
  }

  private func configureAudioSession(prefersBluetoothHFP: Bool) throws {
    let session = AVAudioSession.sharedInstance()
    var options: AVAudioSession.CategoryOptions = [.allowBluetoothHFP, .mixWithOthers]
    if !prefersBluetoothHFP {
      options.insert(.defaultToSpeaker)
    }
    try session.setCategory(.playAndRecord, mode: .voiceChat, options: options)
    try session.setActive(true)
    self.prefersBluetoothHFP = prefersBluetoothHFP
    if let audioRouteObserver {
      NotificationCenter.default.removeObserver(audioRouteObserver)
    }
    audioRouteObserver = NotificationCenter.default.addObserver(
      forName: AVAudioSession.routeChangeNotification,
      object: session,
      queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.refreshPreferredAudioRoute()
      }
    }

    try applyPreferredAudioRoute()
    AudioRouteMonitor.shared.start()
  }

  private func refreshPreferredAudioRoute() {
    do {
      try applyPreferredAudioRoute()
    } catch {
      NSLog("[GlassifAI] audio route refresh failed: %@", error.localizedDescription)
    }
    AudioRouteMonitor.shared.refresh()
  }

  private func applyPreferredAudioRoute() throws {
    let session = AVAudioSession.sharedInstance()
    if forcesBuiltInAudio {
      if let builtIn = session.availableInputs?.first(where: { $0.portType == .builtInMic }),
         session.currentRoute.inputs.first?.portType != .builtInMic {
        try session.setPreferredInput(builtIn)
      }
      if !session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
        try session.overrideOutputAudioPort(.speaker)
      }
      return
    }
    guard prefersBluetoothHFP else { return }
    let glassesName = AudioRouteMonitor.shared.glassesName
    if session.currentRoute.inputs.contains(where: {
      $0.portType == .bluetoothHFP && AudioRouteMonitor.isGlassesPortName($0.portName, glassesName: glassesName)
    }) {
      return
    }
    if let glassesInput = AudioRouteMonitor.preferredGlassesInput(
      from: session.availableInputs, glassesName: glassesName) {
      if session.currentRoute.inputs.first?.uid == glassesInput.uid { return }
      try session.overrideOutputAudioPort(.none)
      try session.setPreferredInput(glassesInput)
      NSLog("[GlassifAI] audio routed to Bluetooth HFP: %@", glassesInput.portName)
    } else {
      if session.currentRoute.inputs.contains(where: { $0.portType == .bluetoothHFP }) {
        // Another hands-free headset is active and the glasses are not
        // identifiable; leave the user's current choice alone.
        return
      }
      if session.currentRoute.outputs.contains(where: { $0.portType == .builtInSpeaker }) {
        return
      }
      try session.overrideOutputAudioPort(.speaker)
      NSLog("[GlassifAI] Bluetooth HFP unavailable; using iPhone audio")
    }
  }

  // MARK: Local "stop speaking"

  private func remoteAudioTracks() -> [LKRTCAudioTrack] {
    guard let peer else { return [] }
    return peer.transceivers.compactMap { transceiver in
      guard transceiver.mediaType == .audio else { return nil }
      return transceiver.receiver.track as? LKRTCAudioTrack
    }
  }

  private func suppressAssistantAudio() {
    let tracks = remoteAudioTracks()
    guard !tracks.isEmpty else { return }
    tracks.forEach { $0.isEnabled = false }
    isAssistantAudioSuppressed = true
    audioSuppressionTask?.cancel()
    audioSuppressionTask = Task { [weak self] in
      try? await Task.sleep(nanoseconds: 8_000_000_000)
      guard !Task.isCancelled else { return }
      self?.releaseAssistantAudio()
    }
  }

  private func releaseAssistantAudio() {
    guard isAssistantAudioSuppressed, !holdsAssistantAudio else { return }
    audioSuppressionTask?.cancel()
    audioSuppressionTask = nil
    remoteAudioTracks().forEach { $0.isEnabled = true }
    isAssistantAudioSuppressed = false
  }

  /// Mutes the model until the app's own result is delivered.
  private func holdAssistantAudio() {
    holdsAssistantAudio = true
    remoteAudioTracks().forEach { $0.isEnabled = false }
    isAssistantAudioSuppressed = true
    audioSuppressionTask?.cancel()
    audioSuppressionTask = nil
  }

  private func releaseHeldAudio() {
    guard holdsAssistantAudio else { return }
    holdsAssistantAudio = false
    preHeldForCommand = false
    releaseAssistantAudio()
  }

  private func resetInterception() {
    interceptionTimer?.cancel()
    interceptionTimer = nil
    interception = nil
    deferredFlushTask?.cancel()
    deferredFlushTask = nil
    deferredDelegations = []
    answeredHandoffs = []
    holdsAssistantAudio = false
    preHeldForCommand = false
    lastInterceptedTurn = nil
    recentDelegation = nil
    earlyFinalTask?.cancel()
    earlyFinalTask = nil
    earlyFinal = nil
    userTurnOpenedAt = nil
    userTurnBargedIn = false
    sawTurnDone = false
    lastLegacyFinal = nil
  }

  // MARK: Voice action bridge

  /// The user's final words: an explicit command ("not al …", "yarın 10'da
  /// hatırlat …") is executed by the app; the model's own reply is muted and
  /// the app's result is spoken instead.
  @discardableResult
  private func interceptIfCommand(_ text: String, assistantWasSpeaking: Bool) -> Bool {
    defer { flushDeferredDelegations() }
    // "Dur" silences an answer; it is only a command when it answers a
    // question the app asked ("Hayır" to "Kaydedeyim mi?").
    let command = ConversationCommands.classify(
      text, assistantName: AssistantIdentity.name, assistantSpeaking: assistantWasSpeaking)
    let skip = command == .endConversation || (command == .stopSpeaking && orchestrator.pendingAction == nil)
    guard !isPreviewSession, !pendingHangUp, !skip, let decision = orchestrator.bridgeDecision(for: text) else {
      finishPreHold()
      return false
    }
    // The model may have delegated these words before their final
    // transcript arrived. Its delegation is taken over (stopped; the app's
    // result answers it) unless it already did the action. It is never
    // simply skipped: a delegation that only answered would leave the
    // command undone.
    var takenOver: String?
    if let earlier = earlierDelegation(matching: text) {
      switch orchestrator.takeOverDelegation(handoffID: earlier.handoffID, signature: decision.intent.actionSignature) {
      case .completedAction:
        NSLog("[AutoLoom] command already done by the model's delegation")
        finishPreHold()
        return false
      case .cancelled:
        takenOver = earlier.handoffID
        NSLog("[AutoLoom] early delegation taken over by the voice action bridge")
      case .completedOther, .unknown:
        break
      }
    }
    let turn = userTurnSerial
    let handled = orchestrator.interceptVoiceTurn(text, decision: decision) { [weak self] result in
      self?.interceptionResultReady(result, turn: turn)
    }
    guard handled else {
      finishPreHold()
      return false
    }
    interception = TurnInterception(turn: turn)
    if let takenOver {
      answeredHandoffs.insert(takenOver)
      interception?.handoffID = takenOver
    }
    lastInterceptedTurn = turn
    holdAssistantAudio()
    interceptionTimer?.cancel()
    interceptionTimer = Task { @MainActor [weak self] in
      // The model stayed silent: deliver without waiting for its reply.
      try? await Task.sleep(nanoseconds: 3_000_000_000)
      guard let self, !Task.isCancelled else { return }
      if var current = self.interception, current.turn == turn, !current.delivered, !self.assistantTurnOpen {
        current.modelReplyDone = true
        self.interception = current
        self.deliverInterceptionIfReady()
      }
      // Never keep the assistant muted for long.
      try? await Task.sleep(nanoseconds: 20_000_000_000)
      guard !Task.isCancelled, let current = self.interception, current.turn == turn else { return }
      if !current.delivered {
        self.interception?.modelReplyDone = true
        self.deliverInterceptionIfReady()
      }
      self.interception = nil
      self.releaseHeldAudio()
    }
    return true
  }

  // MARK: Final transcripts

  /// The model answers before the user's final transcript arrived. Once the
  /// partial words have been still for a moment, they are handled as the
  /// final words, so a command is never lost to a late transcript.
  private func scheduleEarlyFinal() {
    earlyFinalTask?.cancel()
    let opened = userTurnOpenedAt
    earlyFinalTask = Task { @MainActor [weak self] in
      for _ in 0..<16 {
        try? await Task.sleep(nanoseconds: 300_000_000)
        guard let self, !Task.isCancelled, self.userTurnOpen, self.userTurnOpenedAt == opened else { return }
        if Date().timeIntervalSince(self.lastUserPartialAt) >= 1.2 {
          self.finalizeUserTurnEarly()
          return
        }
      }
    }
  }

  private func finalizeUserTurnEarly() {
    let text = userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    guard userTurnOpen, !text.isEmpty else { return }
    NSLog("[AutoLoom] user turn finished from its partial transcript (the final one is late)")
    userTurnOpen = false
    userTranscript = text
    noteActivity()
    userTurnSerial += 1
    orchestrator.noteUserTurn(text)
    handleEndCommand(text, assistantWasSpeaking: userTurnBargedIn)
    let handled = interceptIfCommand(text, assistantWasSpeaking: userTurnBargedIn)
    earlyFinal = (text, handled, Date())
  }

  /// Older event shapes: the user's final words when this connection never
  /// sends `turn.done`. Each turn is handled once.
  private func finalizeLegacyUserTurn(_ raw: String) {
    let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !sawTurnDone, !userTurnOpen, !text.isEmpty else { return }
    if let last = lastLegacyFinal, !Self.wordsDiffer(last.text, text), Date().timeIntervalSince(last.at) < 10 { return }
    lastLegacyFinal = (text, Date())
    userTurnOpenedAt = Date()
    userTurnEndedAt = CACurrentMediaTime()
    noteActivity()
    userTurnSerial += 1
    orchestrator.noteUserTurn(text)
    handleEndCommand(text, assistantWasSpeaking: false)
    interceptIfCommand(text, assistantWasSpeaking: false)
  }

  private static func wordsDiffer(_ a: String, _ b: String) -> Bool {
    MemorySearch.tokens(a) != MemorySearch.tokens(b)
  }

  /// A delegation the model made for these words before their final
  /// transcript: made while the user was still talking, or within a few
  /// seconds with mostly the same words.
  private func earlierDelegation(matching text: String) -> (at: Date, request: String, handoffID: String)? {
    guard let recent = recentDelegation, Date().timeIntervalSince(recent.at) < 8 else { return nil }
    if let opened = userTurnOpenedAt, recent.at >= opened { return recent }
    let spoken = Set(MemorySearch.tokens(text))
    guard !spoken.isEmpty else { return nil }
    let delegated = Set(MemorySearch.tokens(recent.request))
    return Double(spoken.intersection(delegated).count) / Double(spoken.count) >= 0.5 ? recent : nil
  }

  private func finishPreHold() {
    guard preHeldForCommand else { return }
    preHeldForCommand = false
    releaseHeldAudio()
  }

  private func interceptionResultReady(_ result: String, turn: Int) {
    guard var current = interception, current.turn == turn, !current.delivered else {
      // The conversation moved on: tell the user the result anyway.
      _ = sayAppMessage(result)
      return
    }
    current.result = result
    interception = current
    deliverInterceptionIfReady()
  }

  /// Delivers once the result is ready and the model's turn is settled: as
  /// the answer to its delegation, or as speakable context. The audio is
  /// released when the muted reply has finished, so only the confirmation
  /// is heard.
  private func deliverInterceptionIfReady() {
    guard var current = interception, !current.delivered, let result = current.result else { return }
    guard current.handoffID != nil || current.modelReplyDone else { return }
    let sent: Bool
    if let handoff = current.handoffID {
      sent = EmbeddedCodexBridge.completeDelegation(handoffId: handoff, text: result)
    } else {
      sent = sayAppMessage(result)
    }
    NSLog("[AutoLoom] command result delivered via %@ (%@)", current.handoffID == nil ? "context" : "delegation", sent ? "ok" : "failed")
    current.delivered = true
    if assistantTurnOpen {
      current.releaseAfterTurn = true
      interception = current
      let turn = current.turn
      Task { @MainActor [weak self] in
        // In case the muted reply and the confirmation share one turn.
        try? await Task.sleep(nanoseconds: 2_500_000_000)
        guard let self, let pending = self.interception, pending.turn == turn, pending.releaseAfterTurn else { return }
        self.interception = nil
        self.releaseHeldAudio()
      }
    } else {
      interception = nil
      interceptionTimer?.cancel()
      releaseHeldAudio()
    }
  }

  // MARK: Spoken commands and the quiet timeout

  /// "Dur", "sus", "stop" while the assistant talks silence it at once. The
  /// server also stops an answer the user talks over; the local mute makes it
  /// instant. Other speech ends a manual mute, as before.
  private func handleUserSpeech(assistantWasSpeaking: Bool) {
    if ConversationCommands.isEnabled, !isPreviewSession,
       ConversationCommands.classify(
         userTranscript, assistantName: AssistantIdentity.name,
         assistantSpeaking: assistantWasSpeaking || stopWordMutedTurn) == .stopSpeaking {
      if !isAssistantAudioSuppressed { suppressAssistantAudio() }
      stopWordMutedTurn = true
      return
    }
    if !stopWordMutedTurn { releaseAssistantAudio() }
  }

  /// "Kapat", "konuşmayı bitir", "görüşürüz", "Jarvis stop": the assistant
  /// may say a short goodbye, then the conversation ends.
  private func handleEndCommand(_ text: String, assistantWasSpeaking: Bool) {
    guard ConversationCommands.isEnabled, !isPreviewSession,
          ConversationCommands.classify(
            text, assistantName: AssistantIdentity.name, assistantSpeaking: assistantWasSpeaking) == .endConversation
    else { return }
    pendingHangUp = true
    lastEndReason = L.t("Ended by voice command", "Sesli komutla bitirildi")
    scheduleAutoStop(afterSeconds: 4)
  }

  private func noteActivity() {
    lastActivityAt = Date()
  }

  private func startIdleMonitor() {
    idleMonitorTask?.cancel()
    idleMonitorTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 5_000_000_000)
        guard let self, !Task.isCancelled else { return }
        self.checkIdle()
      }
    }
  }

  /// Ends a conversation that stayed quiet for the chosen time. Anything in
  /// progress (speech, a task, a pending confirmation, Live Vision) counts as
  /// activity.
  private func checkIdle() {
    guard isConnected, !isPreviewSession, !pendingHangUp else { return }
    let busy = state == .speaking || userTurnOpen || assistantTurnOpen || isReconnecting
      || orchestrator.activity != nil || orchestrator.pendingAction != nil
      || LiveVisionController.shared.isActive
    if busy {
      noteActivity()
      return
    }
    let idle = Date().timeIntervalSince(lastActivityAt)
    guard ConversationTimeout.shouldEnd(idle: idle, limit: ConversationTimeout.current.interval, busy: false) else {
      return
    }
    lastEndReason = L.t("Ended after a quiet period", "Sessiz kalınca bitirildi")
    NSLog("[AutoLoom] conversation ended after %.0f s without activity", idle)
    Task { @MainActor [weak self] in await self?.stop() }
  }

  private func createOffer(
    peer: LKRTCPeerConnection,
    constraints: LKRTCMediaConstraints
  ) async throws -> LKRTCSessionDescription {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<LKRTCSessionDescription, Error>) in
      peer.offer(for: constraints) { description, error in
        if let description { continuation.resume(returning: description) }
        else { continuation.resume(throwing: error ?? RealtimeError.offerFailed) }
      }
    }
  }

  private func setLocalDescription(
    _ description: LKRTCSessionDescription,
    peer: LKRTCPeerConnection
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setLocalDescription(description) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func setRemoteDescription(
    _ description: LKRTCSessionDescription,
    peer: LKRTCPeerConnection
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      peer.setRemoteDescription(description) { error in
        if let error { continuation.resume(throwing: error) }
        else { continuation.resume() }
      }
    }
  }

  private func sendEvent(_ event: [String: Any]) {
    guard let dataChannel, dataChannel.readyState == .open,
          let inner = try? JSONSerialization.data(withJSONObject: event),
          let innerText = String(data: inner, encoding: .utf8),
          let outer = try? JSONSerialization.data(withJSONObject: [
            "type": "data_message",
            "data": innerText,
          ]) else { return }
    _ = dataChannel.sendData(LKRTCDataBuffer(data: outer, isBinary: false))
  }

  private func handleDataChannelData(_ data: Data) {
    guard var value = try? JSONSerialization.jsonObject(with: data) else { return }
    for _ in 0..<4 {
      if let text = value as? String, let nested = text.data(using: .utf8),
         let decoded = try? JSONSerialization.jsonObject(with: nested) {
        value = decoded
      } else if let envelope = value as? [String: Any],
                envelope["type"] as? String == "data_message",
                let nested = envelope["data"] as? String,
                let nestedData = nested.data(using: .utf8),
                let decoded = try? JSONSerialization.jsonObject(with: nestedData) {
        value = decoded
      } else {
        break
      }
    }
    guard let event = value as? [String: Any], let type = event["type"] as? String else { return }
    let payload = event["payload"] as? [String: Any] ?? event
    switch type {
    case "chat_message_delta":
      applyChatMessageDelta(event: event, payload: payload)
    case "session.started", "session.updated":
      state = .listening
    case "state_update":
      if let next = payload["new_state"] as? String { applyLegacyState(next) }
    case "input_transcript.added":
      if let text = (event["item"] as? [String: Any])?["text"] as? String {
        let assistantWasSpeaking = assistantTurnOpen || state == .speaking
        if !userTurnOpen {
          userTurnOpen = true
          userTranscript = ""
          assistantCaption = ""
          stopWordMutedTurn = false
          userTurnOpenedAt = Date()
          userTurnBargedIn = assistantWasSpeaking
          earlyFinalTask?.cancel()
          earlyFinalTask = nil
          earlyFinal = nil
          // A new request: later delegations belong to it, and an unfinished
          // command result must not keep the new answer muted.
          lastInterceptedTurn = nil
          if var current = interception {
            current.acceptsDelegations = false
            current.modelReplyDone = true
            interception = current
            releaseHeldAudio()
          }
        }
        userTranscript += text
        lastUserPartialAt = Date()
        noteActivity()
        handleUserSpeech(assistantWasSpeaking: assistantWasSpeaking)
        // "Not al…", "benim adım…": hold the model's reply from the start.
        if !holdsAssistantAudio, !isPreviewSession, !assistantWasSpeaking,
           VoiceActionIntentBridge.looksLikeCommandStart(userTranscript, assistantName: AssistantIdentity.name) {
          preHeldForCommand = true
          holdAssistantAudio()
        }
      }
    case "output_transcript.added":
      if let text = (event["item"] as? [String: Any])?["text"] as? String {
        if !assistantTurnOpen {
          assistantTurnOpen = true
          assistantCaption = ""
          recordResponseLatency()
          // Answering a turn whose final transcript has not arrived yet.
          if userTurnOpen { scheduleEarlyFinal() }
        }
        // A muted reply is neither shown nor counted as speaking.
        if holdsAssistantAudio {
          state = .thinking
          return
        }
        assistantCaption += text
        state = .speaking
        noteActivity()
        orchestrator.noteAssistantSpeaking()
      }
    case "turn.done":
      if let turn = event["turn"] as? [String: Any],
         let role = turn["role"] as? String,
         let text = turn["transcript"] as? String {
        if role == "user" {
          sawTurnDone = true
          earlyFinalTask?.cancel()
          earlyFinalTask = nil
          if let early = earlyFinal, !userTurnOpen, Date().timeIntervalSince(early.at) < 20 {
            // The final words of a turn already handled from its partial
            // transcript: they only correct the text, unless the partial
            // words were no command and the final ones are.
            earlyFinal = nil
            userTranscript = text
            if !early.handled, Self.wordsDiffer(early.text, text) {
              interceptIfCommand(text, assistantWasSpeaking: false)
            } else if early.handled, Self.wordsDiffer(early.text, text) {
              // A note saved from the partial words gets the final words.
              orchestrator.correctRecentNote(fromFinalTranscript: text)
            }
            return
          }
          earlyFinal = nil
          if let legacy = lastLegacyFinal, !userTurnOpen, Date().timeIntervalSince(legacy.at) < 10,
             !Self.wordsDiffer(legacy.text, text) {
            // Already handled from the older transcript event.
            lastLegacyFinal = nil
            userTranscript = text
            return
          }
          let assistantWasSpeaking = assistantTurnOpen || isAssistantAudioSuppressed
          // A turn without partial words starts now.
          if !userTurnOpen { userTurnOpenedAt = Date() }
          userTurnOpen = false
          userTranscript = text
          state = .thinking
          userTurnEndedAt = CACurrentMediaTime()
          noteActivity()
          userTurnSerial += 1
          orchestrator.noteUserTurn(text)
          handleEndCommand(text, assistantWasSpeaking: assistantWasSpeaking)
          interceptIfCommand(text, assistantWasSpeaking: assistantWasSpeaking)
        }
        if role == "assistant" {
          assistantTurnOpen = false
          let muted = holdsAssistantAudio
          if !muted { assistantCaption = text }
          state = .listening
          noteActivity()
          // A muted reply was never heard, so it is not part of the context.
          if !muted { orchestrator.noteAssistantTurn(text) }
          if var current = interception {
            if current.delivered, current.releaseAfterTurn {
              interception = nil
              interceptionTimer?.cancel()
              releaseHeldAudio()
            } else if !current.delivered {
              current.modelReplyDone = true
              interception = current
              // A delegation for the same turn may still arrive.
              Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 500_000_000)
                self?.deliverInterceptionIfReady()
              }
            }
          }
          releaseAssistantAudio()
          // Let the last words play out, then end the preview or the
          // conversation the user asked to end.
          if isPreviewSession {
            scheduleAutoStop(afterSeconds: 1.5)
          } else if pendingHangUp {
            scheduleAutoStop(afterSeconds: 1.2)
          }
        }
      }
    case "delegation.created":
      state = .thinking
      handleDelegation(event)
    case "user_transcription_text":
      let text = (payload["text"] ?? payload["transcript"]) as? String ?? userTranscript
      userTranscript = text
      // Older event shape: its final text is the user's turn when this
      // connection never sends `turn.done`.
      let isFinal = (payload["is_final"] ?? payload["final"] ?? payload["isFinal"]) as? Bool ?? false
      if isFinal { finalizeLegacyUserTurn(text) }
    case "live_captioning_text":
      assistantCaption = (payload["text"] ?? payload["transcript"]) as? String ?? assistantCaption
    case "error":
      let message = LogSanitizer.sanitize((event["message"] as? String) ?? "ChatGPT Live reported an error.")
      lastRealtimeError = message
      state = .failed(message)
    case "goodbye", "close_ready":
      Task { await stop() }
    default:
      break
    }
  }


  private func applyChatMessageDelta(
    event: [String: Any],
    payload: [String: Any]
  ) {
    let source = payload["type"] as? String == "chat_message_delta" ? payload : event
    let delta = source["delta"] as? [String: Any]
      ?? (source["payload"] as? [String: Any])?["delta"] as? [String: Any]
      ?? [:]
    if let value = delta["v"] as? [String: Any],
       let message = value["message"] as? [String: Any] {
      let parts = (message["content"] as? [String: Any])?["parts"] as? [Any] ?? []
      var role = (message["author"] as? [String: Any])?["role"] as? String ?? ""
      if role != "user" && role != "assistant" {
        for case let part as [String: Any] in parts
        where part["content_type"] as? String == "audio_transcription" {
          if part["direction"] as? String == "in" { role = "user" }
          if part["direction"] as? String == "out" { role = "assistant" }
        }
      }
      guard role == "user" || role == "assistant" else { return }
      // Older event shape: the assistant's message closes the user's turn.
      if role == "assistant", streamingCaptionRole == "user" {
        finalizeLegacyUserTurn(streamingCaptionText)
      }
      let text = parts.compactMap { part -> String? in
        if let text = part as? String { return text }
        guard let part = part as? [String: Any] else { return nil }
        return part["text"] as? String
          ?? part["content"] as? String
          ?? part["transcript"] as? String
      }.joined(separator: "\n")
      streamingCaptionRole = role
      streamingCaptionMessageId = message["id"] as? String ?? streamingCaptionMessageId
      streamingCaptionText = text
    } else if let operations = delta["v"] as? [[String: Any]],
              !streamingCaptionRole.isEmpty {
      for operation in operations
      where operation["o"] as? String == "append" {
        let path = operation["p"] as? String ?? ""
        guard path.range(of: #"^/message/content/parts/\d+/text$"#, options: .regularExpression) != nil else {
          continue
        }
        streamingCaptionText += operation["v"] as? String ?? ""
      }
    }
    guard !streamingCaptionText.isEmpty else { return }
    if streamingCaptionRole == "user" {
      userTranscript = streamingCaptionText
    } else if streamingCaptionRole == "assistant" {
      assistantCaption = streamingCaptionText
      state = .speaking
    }
  }
  /// Time from the end of the user's turn to the first words of the answer.
  private func recordResponseLatency() {
    guard let ended = userTurnEndedAt else { return }
    userTurnEndedAt = nil
    let milliseconds = (CACurrentMediaTime() - ended) * 1_000
    guard milliseconds >= 0, milliseconds < 60_000 else { return }
    responseLatencies.append(milliseconds)
    if responseLatencies.count > 20 { responseLatencies.removeFirst(responseLatencies.count - 20) }
    let sorted = responseLatencies.sorted()
    responseLatencyMedianMs = Int(sorted[sorted.count / 2].rounded())
  }

  private func applyLegacyState(_ next: String) {
    switch next {
    case "listening", "listening_intently", "connected", "idle": state = .listening
    case "thinking": state = .thinking
    case "speaking": state = .speaking
    case "halted": state = .disconnected
    default: break
    }
  }
}

extension GlassifAIRealtimeSession: LKRTCPeerConnectionDelegate {
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange stateChanged: LKRTCSignalingState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didAdd stream: LKRTCMediaStream) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove stream: LKRTCMediaStream) {}
  nonisolated func peerConnectionShouldNegotiate(_ peerConnection: LKRTCPeerConnection) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceConnectionState) {
    if newState == .failed {
      Task { @MainActor in
        if isConnected {
          handleMidCallFailure(
            reason: "ICE connection failed",
            userMessage: "The voice connection was interrupted. Tap to reconnect.")
        } else {
          await tearDown()
          lastRealtimeError = "ICE connection failed"
          state = .failed("The voice connection was interrupted. Tap to reconnect.")
        }
      }
    }
  }
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didChange newState: LKRTCIceGatheringState) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didGenerate candidate: LKRTCIceCandidate) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didRemove candidates: [LKRTCIceCandidate]) {}
  nonisolated func peerConnection(_ peerConnection: LKRTCPeerConnection, didOpen dataChannel: LKRTCDataChannel) {}
}

extension GlassifAIRealtimeSession: LKRTCDataChannelDelegate {
  nonisolated func dataChannelDidChangeState(_ dataChannel: LKRTCDataChannel) {}
  nonisolated func dataChannel(_ dataChannel: LKRTCDataChannel, didReceiveMessageWith buffer: LKRTCDataBuffer) {
    let data = buffer.data
    Task { @MainActor in handleDataChannelData(data) }
  }
}


/// Budget for automatic reconnects after a call breaks: a few quick attempts,
/// never an endless loop.
struct RealtimeReconnectPolicy {
  static let maxReconnects = 3
  static let window: TimeInterval = 120
  static let delayNanoseconds: UInt64 = 1_000_000_000

  private(set) var history: [Date] = []

  func allowsReconnect(now: Date) -> Bool {
    history.filter { now.timeIntervalSince($0) < Self.window }.count < Self.maxReconnects
  }

  mutating func record(_ date: Date) {
    history.append(date)
    history = history.filter { date.timeIntervalSince($0) < Self.window }
  }
}

private enum RealtimeError: LocalizedError {
  case peerCreationFailed
  case audioTrackFailed
  case dataChannelFailed
  case offerFailed
  case invalidResponse
  case connectionTimedOut
  case signalingFailed(String)

  var errorDescription: String? {
    switch self {
    case .peerCreationFailed: "The voice connection could not be created."
    case .audioTrackFailed: "The microphone could not join the voice connection."
    case .dataChannelFailed: "The ChatGPT event channel could not be created."
    case .offerFailed: "The iPhone could not create a voice offer."
    case .invalidResponse: "ChatGPT returned an invalid response."
    case .connectionTimedOut: "ChatGPT took too long to connect."
    case .signalingFailed(let message): message
    }
  }
}
