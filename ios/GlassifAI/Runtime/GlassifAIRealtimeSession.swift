import AVFoundation
import Combine
import Foundation
import LiveKitWebRTC

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

  var isActive: Bool {
    switch state {
    case .connecting, .listening, .thinking, .speaking: true
    case .disconnected, .failed: false
    }
  }

  private let factory = LKRTCPeerConnectionFactory()
  private var peer: LKRTCPeerConnection?
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

  func start(prefersBluetoothHFP: Bool = false, forcesBuiltInAudio: Bool = false) async {
    guard !isActive else { return }
    state = .connecting
    userTranscript = ""
    isMicrophoneMuted = false
    assistantCaption = ""
    streamingCaptionRole = ""
    streamingCaptionMessageId = ""
    streamingCaptionText = ""
    userTurnOpen = false
    assistantTurnOpen = false
    lastRealtimeError = nil
    isAssistantAudioSuppressed = false
    _ = orchestrator.beginVoiceSession()
    AudioRouteMonitor.shared.onMediaServicesReset = { [weak self] in
      Task { @MainActor in await self?.handleMediaServicesReset() }
    }

    do {
      self.forcesBuiltInAudio = forcesBuiltInAudio
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

      let offer = try await createOffer(peer: peer, constraints: constraints)
      try await setLocalDescription(offer, peer: peer)
      for _ in 0..<25 where peer.iceGatheringState != .complete {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      let localSDP = peer.localDescription?.sdp ?? offer.sdp
      let answerSDP = try await createDirectRealtimeCall(sdp: localSDP)
      let answer = LKRTCSessionDescription(type: .answer, sdp: answerSDP)
      try await setRemoteDescription(answer, peer: peer)

      for _ in 0..<100 where channel.readyState != .open {
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
      guard channel.readyState == .open else { throw RealtimeError.connectionTimedOut }
      state = .listening
      startSidebandEventLoop()
    } catch {
      await tearDown()
      let message = LogSanitizer.sanitize(error.localizedDescription)
      lastRealtimeError = message
      state = .failed(message)
    }
  }

  func stop() async {
    sendEvent(["type": "session.close"])
    await tearDown()
    state = .disconnected
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
    guard isActive else { return }
    isMicrophoneMuted.toggle()
    audioTrack?.isEnabled = !isMicrophoneMuted
  }

  private func createDirectRealtimeCall(sdp: String) async throws -> String {
    let tokens = try await ChatGPTAuthSession.shared.freshTokens()
    var options = RealtimeStartOptions()
    options.instructions = AssistantInstructions.realtime(memory: LocalMemoryStore.shared.promptItems)
    options.voice = AssistantPreferences.voice
    if let resume = orchestrator.context.resumeSummary() {
      options.initialItems = [RealtimeStartOptions.Item(role: "developer", text: resume)]
    }
    var result = try await EmbeddedCodexBridge.startRealtime(tokens: tokens, sdp: sdp, options: options)
    startMode = .autoloom
    if !result.ok || !Self.isAnswerSDP(result.sdp) {
      // The customised session was rejected; fall back to the exact
      // configuration that is verified on device.
      NSLog("[AutoLoom] realtime v2 start failed (%@); retrying with baseline configuration",
            LogSanitizer.sanitize(result.error ?? "no answer"))
      result = try await EmbeddedCodexBridge.startRealtime(tokens: tokens, sdp: sdp)
      startMode = .baselineFallback
    }
    guard result.ok, let answer = result.sdp, Self.isAnswerSDP(answer) else {
      throw RealtimeError.signalingFailed(
        "Could not start ChatGPT voice. \(LogSanitizer.sanitize(result.error ?? "Unknown error"))")
    }
    return answer
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
            self?.lastRealtimeError = LogSanitizer.sanitize(status, limit: 160)
            self?.state = .failed("The assistant's task channel disconnected. Tap to reconnect.")
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
    releaseAssistantAudio()
    orchestrator.handleDelegation(handoffID: handoffId, text: request) { [weak self] text in
      let delivered = EmbeddedCodexBridge.completeDelegation(handoffId: handoffId, text: text)
      if !delivered {
        self?.state = .failed("The assistant's task channel disconnected. Tap to reconnect.")
      }
      return delivered
    }
  }

  private func handleMediaServicesReset() async {
    guard isActive else { return }
    await tearDown()
    state = .failed("iOS restarted the audio system. Tap to reconnect.")
  }

  private func tearDown() async {
    sidebandEventTask?.cancel()
    sidebandEventTask = nil
    audioSuppressionTask?.cancel()
    audioSuppressionTask = nil
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
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
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
    guard isAssistantAudioSuppressed else { return }
    audioSuppressionTask?.cancel()
    audioSuppressionTask = nil
    remoteAudioTracks().forEach { $0.isEnabled = true }
    isAssistantAudioSuppressed = false
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
        releaseAssistantAudio()
        if !userTurnOpen {
          userTurnOpen = true
          userTranscript = ""
          assistantCaption = ""
        }
        userTranscript += text
      }
    case "output_transcript.added":
      if let text = (event["item"] as? [String: Any])?["text"] as? String {
        if !assistantTurnOpen {
          assistantTurnOpen = true
          assistantCaption = ""
        }
        assistantCaption += text
        state = .speaking
        orchestrator.noteAssistantSpeaking()
      }
    case "turn.done":
      if let turn = event["turn"] as? [String: Any],
         let role = turn["role"] as? String,
         let text = turn["transcript"] as? String {
        if role == "user" {
          userTurnOpen = false
          userTranscript = text
          state = .thinking
          orchestrator.noteUserTurn(text)
        }
        if role == "assistant" {
          assistantTurnOpen = false
          assistantCaption = text
          state = .listening
          orchestrator.noteAssistantTurn(text)
          releaseAssistantAudio()
        }
      }
    case "delegation.created":
      state = .thinking
      handleDelegation(event)
    case "user_transcription_text":
      let text = (payload["text"] ?? payload["transcript"]) as? String ?? userTranscript
      userTranscript = text
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
        await tearDown()
        lastRealtimeError = "ICE connection failed"
        state = .failed("The voice connection was interrupted. Tap to reconnect.")
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
