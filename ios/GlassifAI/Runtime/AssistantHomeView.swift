import AVFoundation
import SwiftUI
import UIKit

/// The Assistant tab. Top: the brand, the camera switch and the Ray-Ban
/// status pill. Centre: the camera edge to edge, or the orb when the camera
/// is off. Bottom: captions, confirmations, the assistant's state in one word
/// and the controls. Technical metrics live in Settings → Developer.
struct AssistantHomeView: View {
  let captureSource: CaptureSource
  @ObservedObject var glassesStream: StreamSessionViewModel
  @ObservedObject var voice: GlassifAIRealtimeSession
  @ObservedObject var camera: GlassifAICamera
  @ObservedObject var connection: WearableConnectionCoordinator

  @ObservedObject private var orchestrator = AssistantOrchestrator.shared
  @ObservedObject private var audioRoute = AudioRouteMonitor.shared
  @ObservedObject private var liveVision = LiveVisionController.shared
  @ObservedObject private var wake = WakePhraseListener.shared
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(AssistantPreferences.languageKey) private var language = "auto"
  @State private var showTextInput = false
  @State private var typedText = ""
  @State private var metrics = FrameMetricsSnapshot()
  @State private var notice: String?
  @State private var showConnectedToast = false
  /// A short one-shot orb state (the confirmation after a save).
  @State private var orbFlash: OrbMood?
  @FocusState private var textFieldFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openURL) private var openURL

  private var presence: AssistantPresence {
    AssistantPresence.resolve(state: voice.state, activity: orchestrator.activity, muted: voice.isMicrophoneMuted)
  }

  private var orbMood: OrbMood { orbFlash ?? presence.mood }

  var body: some View {
    ZStack {
      AutoLoomTheme.background.ignoresSafeArea()
      stage
      if captureSource != .off {
        LinearGradient(
          colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.78)],
          startPoint: .top,
          endPoint: .bottom)
          .ignoresSafeArea()
          .allowsHitTesting(false)
      }

      VStack(spacing: 10) {
        header
        chips
        Spacer(minLength: 8)
        conversationArea
        presenceLine
        voiceBar
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 8)

      if showConnectedToast {
        VStack {
          ConnectedToast()
            .padding(.top, 96)
          Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
        .allowsHitTesting(false)
      }
    }
    .preferredColorScheme(.dark)
    .tint(AutoLoomTheme.electricBlue)
    .sensoryFeedback(trigger: voice.state) { _, state in
      switch state {
      case .listening: .success
      case .failed: .error
      default: nil
      }
    }
    .sensoryFeedback(.success, trigger: connection.connectedNotice)
    .sensoryFeedback(.impact(weight: .light), trigger: wake.detections)
    .sensoryFeedback(.success, trigger: orbFlash) { _, flash in flash == .success }
    .task(id: captureSource) {
      while !Task.isCancelled {
        metrics = FrameStore.shared.snapshot()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
    .task(id: notice) {
      guard notice != nil else { return }
      try? await Task.sleep(nanoseconds: 3_500_000_000)
      notice = nil
    }
    .task(id: showConnectedToast) {
      guard showConnectedToast else { return }
      try? await Task.sleep(nanoseconds: 2_400_000_000)
      withAnimation(reduceMotion ? nil : .easeOut(duration: 0.3)) { showConnectedToast = false }
    }
    .task(id: orbFlash) {
      guard orbFlash != nil else { return }
      try? await Task.sleep(nanoseconds: 1_100_000_000)
      orbFlash = nil
    }
    .onAppear {
      audioRoute.glassesName = connection.deviceName
      UIApplication.shared.isIdleTimerDisabled = voice.isActive
    }
    .onChange(of: voice.isActive) { _, active in
      // Keep the screen on only during a conversation.
      UIApplication.shared.isIdleTimerDisabled = active
    }
    .onChange(of: voice.lastEndReason) { _, reason in
      if let reason { notice = reason }
    }
    .onChange(of: orchestrator.notice) { _, text in
      // For example a note saved after a permission was granted.
      if let text {
        notice = text
        orchestrator.clearNotice()
      }
    }
    .onChange(of: connection.connectedNotice) { _, _ in
      guard captureSource == .glasses else { return }
      withAnimation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.82)) { showConnectedToast = true }
    }
    .onChange(of: presence) { old, new in
      // A brief confirmation only after a save that really finished.
      guard old == .saving else { return }
      if case .error = new { return }
      orbFlash = .success
    }
    .onChange(of: connection.deviceName) { _, name in audioRoute.glassesName = name }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }

  // MARK: Header

  private var header: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .center, spacing: 10) {
        AutoLoomMark(size: 28)
        Text(AutoLoomBrand.appName)
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Spacer(minLength: 8)
        cameraMenu
      }
      if captureSource == .glasses {
        statusRow
          .transition(.opacity)
      }
    }
    .padding(.top, 6)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: captureSource)
  }

  /// "● Ray-Ban Connected": the pill is a button only when there is
  /// something to try again.
  @ViewBuilder
  private var statusRow: some View {
    let status = connection.status
    HStack(spacing: 8) {
      if status.showsTryAgain {
        Button { connection.retry() } label: {
          HStack(spacing: 6) {
            ConnectionStatusPill(status: status)
            Image(systemName: "arrow.clockwise")
              .font(.caption.weight(.bold))
              .foregroundStyle(.white.opacity(0.85))
          }
        }
        .buttonStyle(PressableButtonStyle(scale: 0.96))
        .accessibilityHint(L.t("Tries to connect again", "Yeniden bağlanmayı dener"))
      } else {
        ConnectionStatusPill(status: status)
      }
      if let detail = status.detail, status.tone != .idle {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.white.opacity(0.7))
          .lineLimit(1)
          .contentTransition(.opacity)
      }
      Spacer(minLength: 0)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: status)
  }

  /// A small indicator of the camera source; tap to switch.
  private var cameraMenu: some View {
    Menu {
      Picker(L.t("Camera", "Kamera"), selection: $captureSourceRaw) {
        ForEach(CaptureSource.allCases, id: \.rawValue) { source in
          Label(source.displayName, systemImage: source.systemImage).tag(source.rawValue)
        }
      }
    } label: {
      HStack(spacing: 6) {
        Image(systemName: captureSource.systemImage)
          .contentTransition(.symbolEffect(.replace))
        Text(captureSource.label)
        if captureSource != .off {
          Circle()
            .fill(cameraIsLive ? GlassesUserStatus.Tone.connected.color : GlassesUserStatus.Tone.attention.color)
            .frame(width: 6, height: 6)
        }
      }
      .font(.caption.weight(.semibold))
      .foregroundStyle(.white.opacity(0.9))
      .padding(.horizontal, 10)
      .padding(.vertical, 7)
      .background(.ultraThinMaterial, in: Capsule())
      .overlay(Capsule().strokeBorder(.white.opacity(0.08)))
    }
    .accessibilityLabel(L.t("Camera: ", "Kamera: ") + captureSource.displayName)
    .accessibilityHint(L.t("Changes the camera the assistant uses", "Asistanın kullandığı kamerayı değiştirir"))
  }

  private var cameraIsLive: Bool {
    guard let age = metrics.lastFrameAgeMs else { return false }
    return age < 1_500
  }

  /// No frame for two seconds: the last one is not shown as live.
  private var glassesViewIsStale: Bool {
    guard let age = metrics.lastFrameAgeMs else { return false }
    return age > 2_000
  }

  // MARK: Chips

  @ViewBuilder
  private var chips: some View {
    HStack(spacing: 8) {
      if liveVision.isActive {
        chip(
          L.t("Live Vision", "Canlı Görüş") + (liveVision.status == .describing ? " · " + L.t("looking", "bakıyor") : ""),
          systemImage: "eye.fill", tint: .red)
      }
      if wake.status.isListening && !voice.isActive {
        chip(L.t("Say “\(WakePhraseSettings.phrase)”", "“\(WakePhraseSettings.phrase)” deyin"), systemImage: "ear")
      }
      if let notice {
        chip(notice, systemImage: "info.circle")
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: notice)
  }

  private func chip(_ text: String, systemImage: String, tint: Color = .white) -> some View {
    Label {
      Text(text).lineLimit(1)
    } icon: {
      Image(systemName: systemImage).foregroundStyle(tint)
    }
    .font(.caption.weight(.semibold))
    .padding(.horizontal, 12)
    .padding(.vertical, 6)
    .background(.ultraThinMaterial, in: Capsule())
    .transition(.opacity)
  }

  // MARK: Camera or orb

  /// One source at a time, crossfading when the source changes.
  private var stage: some View {
    ZStack {
      switch captureSource {
      case .off:
        orbStage
          .transition(.opacity)
      case .iPhoneCamera:
        GlassifAICameraPreview(session: camera.captureSession)
          .ignoresSafeArea()
          .transition(.opacity)
      case .glasses:
        glassesStage
          .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.4), value: captureSource)
  }

  private var glassesStage: some View {
    ZStack {
      if glassesStream.frameIngestor.usesLegacyPreview {
        if let image = glassesStream.currentVideoFrame {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        }
      } else {
        LowLatencyPreviewView(renderer: glassesStream.frameIngestor.renderer)
      }
      if !glassesStream.hasReceivedFirstFrame {
        glassesWaiting
          .transition(.opacity)
      } else if glassesViewIsStale {
        staleVeil
          .transition(.opacity)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: glassesStream.hasReceivedFirstFrame)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: glassesViewIsStale)
    .ignoresSafeArea()
  }

  /// Until the first frame: the link animation and the real state in plain
  /// words, with one "Try Again" when recovery needs the user.
  private var glassesWaiting: some View {
    let status = connection.status
    return ZStack {
      AutoLoomTheme.background
      VStack(spacing: 22) {
        GlassesLinkAnimation(visual: GlassesLinkVisual.from(connection.phase), size: 180)
        VStack(spacing: 6) {
          Text(status.title)
            .font(.title3.weight(.semibold))
            .contentTransition(.opacity)
          if let detail = status.detail {
            Text(detail)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
              .contentTransition(.opacity)
          }
        }
        if status.showsTryAgain {
          Button { connection.retry() } label: {
            Label(L.t("Try Again", "Tekrar dene"), systemImage: "arrow.clockwise")
              .font(.subheadline.weight(.semibold))
              .foregroundStyle(.white)
              .padding(.horizontal, 20)
              .padding(.vertical, 11)
              .background(AutoLoomTheme.electricBlue, in: Capsule())
          }
          .buttonStyle(PressableButtonStyle())
          .transition(.scale.combined(with: .opacity))
        }
      }
      .padding(.horizontal, 40)
      .padding(.bottom, 140)
      .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: status)
    }
  }

  /// The glasses stopped sending: a soft veil instead of a frozen frame
  /// that looks live.
  private var staleVeil: some View {
    ZStack {
      Rectangle().fill(.ultraThinMaterial)
      Label(L.t("Glasses view paused", "Gözlük görüntüsü duraklatıldı"), systemImage: "pause.circle")
        .font(.footnote.weight(.medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.thinMaterial, in: Capsule())
    }
  }

  private var orbStage: some View {
    VStack(spacing: 20) {
      Spacer()
      AssistantOrb(mood: orbMood, size: 240)
      Text(L.t("Camera off — conversation, web and memory still work.",
               "Kamera kapalı — sohbet, web ve hafıza çalışmaya devam eder."))
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 40)
      Spacer()
      Spacer()
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: Conversation

  private var conversationArea: some View {
    VStack(spacing: 10) {
      if let pending = orchestrator.pendingAction {
        PendingActionCard(pending: pending)
          .transition(.move(edge: .bottom).combined(with: .opacity))
      }
      if case .failed(let message) = voice.state {
        errorCard(message)
          .transition(.opacity)
      }
      if !orchestrator.sources.isEmpty { sourcesStrip }
      if let question = orchestrator.typedQuestion { typedAnswerCard(question: question) }
      captionCard
      if showTextInput { textInputRow }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: voice.state)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: voice.assistantCaption)
  }

  @ViewBuilder
  private var captionCard: some View {
    let userLine = voice.userTranscript.trimmingCharacters(in: .whitespacesAndNewlines)
    let assistantLine = voice.assistantCaption.trimmingCharacters(in: .whitespacesAndNewlines)
    if !userLine.isEmpty || !assistantLine.isEmpty {
      VStack(alignment: .leading, spacing: 6) {
        if !userLine.isEmpty {
          Text(userLine)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineLimit(2)
        }
        if !assistantLine.isEmpty {
          Text(assistantLine)
            .font(.body.weight(.medium))
            .lineLimit(5)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(14)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
      .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.white.opacity(0.06)))
      .transition(.opacity)
    } else if !voice.isActive && orchestrator.typedQuestion == nil {
      Text(idleHint)
        .font(.subheadline)
        .foregroundStyle(.white.opacity(0.75))
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }
  }

  private var idleHint: String {
    if wake.status.isListening {
      return L.t("Tap and talk, or say “\(WakePhraseSettings.phrase)”.",
                 "Dokunup konuşun ya da “\(WakePhraseSettings.phrase)” deyin.")
    }
    return L.t("Tap and talk — ask anything, or about what you see.",
               "Dokunun ve konuşun — her şeyi, gördüklerinizi de sorabilirsiniz.")
  }

  private func errorCard(_ message: String) -> some View {
    let friendly = FriendlyError.message(for: message)
    return HStack(alignment: .top, spacing: 12) {
      Image(systemName: "exclamationmark.triangle.fill")
        .foregroundStyle(GlassesUserStatus.Tone.attention.color)
      VStack(alignment: .leading, spacing: 4) {
        Text(friendly.title).font(.subheadline.weight(.semibold))
        Text(friendly.detail).font(.footnote).foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .accessibilityElement(children: .combine)
  }

  private var textInputRow: some View {
    HStack(spacing: 8) {
      TextField(L.t("Type a question", "Bir soru yazın"), text: $typedText, axis: .vertical)
        .lineLimit(1...3)
        .focused($textFieldFocused)
        .submitLabel(.send)
        .onSubmit(sendTyped)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
      Button(action: sendTyped) {
        Image(systemName: "arrow.up.circle.fill")
          .font(.system(size: 32))
      }
      .buttonStyle(PressableButtonStyle())
      .disabled(typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityLabel(L.t("Send question", "Soruyu gönder"))
    }
    .transition(.move(edge: .bottom).combined(with: .opacity))
  }

  private func sendTyped() {
    let text = typedText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    orchestrator.submitTyped(text)
    typedText = ""
    textFieldFocused = false
  }

  private func typedAnswerCard(question: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(question)
          .font(.subheadline.weight(.semibold))
          .lineLimit(2)
        Spacer()
        Button { orchestrator.clearSources() } label: {
          Image(systemName: "xmark")
            .font(.caption.bold())
            .frame(width: 28, height: 28)
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel(L.t("Dismiss answer", "Yanıtı kapat"))
      }
      Divider()
      if let answer = orchestrator.typedAnswer {
        ScrollView {
          Text(answer)
            .font(.body)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .frame(maxHeight: 160)
      } else {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text(presence.word)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
      }
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  private var sourcesStrip: some View {
    ScrollView(.horizontal, showsIndicators: false) {
      HStack(spacing: 8) {
        ForEach(orchestrator.sources) { source in
          Button {
            if URLSafety.isPublicWebURL(source.url) { openURL(source.url) }
          } label: {
            VStack(alignment: .leading, spacing: 4) {
              Text(source.title)
                .font(.caption.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
              HStack(spacing: 4) {
                Image(systemName: "link")
                Text(source.host).lineLimit(1)
              }
              .font(.caption2)
              .foregroundStyle(AutoLoomTheme.electricBlue)
            }
            .frame(width: 180, alignment: .leading)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
          .buttonStyle(PressableButtonStyle(scale: 0.97))
          .accessibilityLabel(L.t("Source: ", "Kaynak: ") + "\(source.title), \(source.host)")
        }
      }
    }
  }

  // MARK: State and controls

  /// The assistant's state in one word, right above the controls.
  private var presenceLine: some View {
    HStack(spacing: 7) {
      Circle()
        .fill(presence.color)
        .frame(width: 7, height: 7)
      Text(presence.word)
        .font(.subheadline.weight(.medium))
        .foregroundStyle(.white.opacity(0.9))
        .contentTransition(.opacity)
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 5)
    .background(.ultraThinMaterial, in: Capsule())
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: presence)
    .accessibilityElement(children: .combine)
    .accessibilityLabel(L.t("Status: ", "Durum: ") + presence.word)
  }

  private var voiceBar: some View {
    HStack(alignment: .center) {
      HStack(spacing: 10) {
        roundButton(
          systemImage: showTextInput ? "keyboard.chevron.compact.down" : "keyboard",
          label: showTextInput ? L.t("Hide keyboard", "Klavyeyi gizle") : L.t("Type a question", "Soru yaz")) {
          withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showTextInput.toggle() }
          textFieldFocused = showTextInput
        }
        if voice.isActive && captureSource != .off {
          roundButton(
            systemImage: liveVision.isActive ? "eye.fill" : "eye",
            label: liveVision.isActive ? L.t("Stop Live Vision", "Canlı Görüşü durdur") : L.t("Start Live Vision", "Canlı Görüşü başlat"),
            highlighted: liveVision.isActive) {
            if liveVision.isActive {
              liveVision.stop(reason: "stopped on screen")
            } else {
              _ = liveVision.start()
            }
          }
          .transition(.scale.combined(with: .opacity))
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      mainVoiceButton

      HStack(spacing: 10) {
        contextButton
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: voice.isActive)
  }

  private var mainVoiceButton: some View {
    VStack(spacing: 6) {
      Button {
        Task {
          if voice.isActive {
            await voice.stop()
          } else {
            // Same idempotent path as Siri and wake-phrase starts.
            await VoiceStartCoordinator.shared.request(.button)
          }
        }
      } label: {
        ZStack {
          if voice.isActive {
            AssistantOrb(mood: orbMood, size: 104)
              .transition(.scale(scale: 0.8).combined(with: .opacity))
          } else {
            Circle()
              .fill(AutoLoomTheme.electricBlue.gradient)
              .frame(width: 74, height: 74)
              .shadow(color: AutoLoomTheme.electricBlue.opacity(0.45), radius: 16, y: 4)
              .transition(.scale(scale: 0.8).combined(with: .opacity))
            Image(systemName: "waveform")
              .font(.system(size: 26, weight: .semibold))
              .foregroundStyle(.white)
          }
        }
        .frame(width: 104, height: 104)
        .contentShape(Circle())
      }
      .buttonStyle(PressableButtonStyle())
      .disabled(voice.state == .connecting)
      .accessibilityLabel(voice.isActive ? L.t("End conversation", "Konuşmayı bitir") : L.t("Start conversation", "Konuşmayı başlat"))
      Text(voice.isActive ? L.t("Tap to end", "Bitirmek için dokunun") : L.t("Tap to talk", "Konuşmak için dokunun"))
        .font(.caption2)
        .foregroundStyle(.white.opacity(0.7))
        .contentTransition(.opacity)
    }
  }

  @ViewBuilder
  private var contextButton: some View {
    if orchestrator.activity != nil {
      roundButton(systemImage: "xmark", label: L.t("Cancel the current task", "Görevi iptal et")) {
        orchestrator.cancelAll(reason: "cancelled by user", voiceOnly: false)
      }
    } else if voice.state == .speaking {
      roundButton(systemImage: "hand.raised.fill", label: L.t("Stop speaking", "Sus")) {
        voice.stopSpeaking()
      }
    } else if voice.isActive {
      roundButton(
        systemImage: voice.isMicrophoneMuted ? "mic.slash.fill" : "mic.fill",
        label: voice.isMicrophoneMuted ? L.t("Unmute microphone", "Mikrofonu aç") : L.t("Mute microphone", "Mikrofonu kapat"),
        highlighted: voice.isMicrophoneMuted) {
        voice.toggleMicrophoneMuted()
      }
    } else {
      Color.clear.frame(width: 44, height: 44)
    }
  }

  private func roundButton(
    systemImage: String,
    label: String,
    highlighted: Bool = false,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Image(systemName: systemImage)
        .font(.system(size: 17, weight: .semibold))
        .contentTransition(.symbolEffect(.replace))
        .frame(width: 44, height: 44)
        .foregroundStyle(.white)
        .background(highlighted ? AnyShapeStyle(AutoLoomTheme.electricBlue.opacity(0.85)) : AnyShapeStyle(.thinMaterial), in: Circle())
        .overlay(Circle().strokeBorder(.white.opacity(0.08)))
    }
    .buttonStyle(PressableButtonStyle())
    .accessibilityLabel(label)
  }
}

/// Live camera numbers, shown only in Settings → Developer → Camera
/// diagnostics (never on the assistant screen).
struct DeveloperOverlay: View {
  let captureSource: CaptureSource
  @ObservedObject var glassesStream: StreamSessionViewModel
  let metrics: FrameMetricsSnapshot

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      if captureSource == .glasses {
        Text("Requested \(glassesStream.streamProfile.requestedSummary) · \(glassesStream.activeTransport.shortLabel) · DAT \(GlassesSDKInfo.datVersion)")
      }
      Text("Actual \(metrics.source) · \(metrics.inputResolution) \(metrics.pixelFormat)")
      Text(String(format: "FPS in %.1f · shown %.1f · received %llu · dropped %llu", metrics.measuredFPS, metrics.renderedFPS, metrics.framesReceived, metrics.previewDropped))
      Text("Processing median \(ms(metrics.processingMedianMs)) · capture→phone \(ms(metrics.transportMedianMs))")
      Text("Last frame age \(metrics.lastFrameAgeMs.map { "\($0) ms" } ?? "—") · \(metrics.previewMode)")
    }
    .font(.system(.caption2, design: .monospaced))
    .foregroundStyle(.white.opacity(0.9))
    .padding(8)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
    .accessibilityHidden(true)
  }

  private func ms(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "—"
  }
}
