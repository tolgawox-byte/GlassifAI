import AVFoundation
import SwiftUI
import UIKit

struct GlassifAIExperienceView: View {
  let captureSource: CaptureSource
  @ObservedObject var glassesStream: StreamSessionViewModel
  let glassesPlaceholder: (title: String, caption: String)
  @ObservedObject var voice: GlassifAIRealtimeSession
  @ObservedObject var camera: GlassifAICamera
  let glassesDeviceName: String?

  @ObservedObject private var orchestrator = AssistantOrchestrator.shared
  @ObservedObject private var audioRoute = AudioRouteMonitor.shared
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @AppStorage(AssistantPreferences.debugOverlayKey) private var showsDebugOverlay = false
  @State private var showSettings = false
  @State private var showTextInput = false
  @State private var typedText = ""
  @State private var metrics = FrameMetricsSnapshot()
  @FocusState private var textFieldFocused: Bool
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.openURL) private var openURL

  private var caption: (role: String, text: String)? {
    if !voice.assistantCaption.isEmpty { return ("Assistant", voice.assistantCaption) }
    if !voice.userTranscript.isEmpty { return ("You", voice.userTranscript) }
    return nil
  }

  var body: some View {
    ZStack {
      AutoLoomTheme.background.ignoresSafeArea()
      cameraLayer
      LinearGradient(
        colors: [.black.opacity(0.55), .clear, .black.opacity(0.78)],
        startPoint: .top,
        endPoint: .bottom)
        .ignoresSafeArea()
        .allowsHitTesting(false)

      VStack(spacing: 10) {
        topBar
        cameraSourcePicker
        if showsDebugOverlay { debugOverlay }
        Spacer(minLength: 12)
        conversationPanel
      }
      .padding(.horizontal, 16)
      .padding(.bottom, 10)
    }
    .preferredColorScheme(.dark)
    .tint(AutoLoomTheme.electricBlue)
    .sheet(isPresented: $showSettings) {
      SettingsView(voice: voice, glassesStream: glassesStream)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
    .sensoryFeedback(trigger: voice.state) { _, state in
      switch state {
      case .listening: .success
      case .failed: .error
      default: nil
      }
    }
    .task(id: captureSource) {
      while !Task.isCancelled {
        metrics = FrameStore.shared.snapshot()
        try? await Task.sleep(nanoseconds: 500_000_000)
      }
    }
    .onAppear {
      UIApplication.shared.isIdleTimerDisabled = true
      audioRoute.glassesName = glassesDeviceName
    }
    .onChange(of: glassesDeviceName) { _, name in audioRoute.glassesName = name }
    .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
  }

  // MARK: Camera

  @ViewBuilder
  private var cameraLayer: some View {
    switch captureSource {
    case .iPhoneCamera:
      GlassifAICameraPreview(session: camera.captureSession)
        .ignoresSafeArea()
    case .glasses:
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
          placeholder(
            systemImage: "eyeglasses",
            title: glassesPlaceholder.title,
            caption: glassesPlaceholder.caption)
        } else if let age = metrics.lastFrameAgeMs, age > 1_500 {
          VStack {
            Spacer()
            Label("Glasses view paused — last frame \(age / 1_000) s ago", systemImage: "pause.circle")
              .font(.footnote.weight(.medium))
              .padding(.horizontal, 12)
              .padding(.vertical, 8)
              .background(.ultraThinMaterial, in: Capsule())
              .padding(.bottom, 220)
          }
        }
      }
      .ignoresSafeArea()
    case .off:
      placeholder(
        systemImage: "video.slash",
        title: "Camera off",
        caption: "Chat, web search, and reasoning still work. Turn a camera on to ask about what you see.")
    }
  }

  private func placeholder(systemImage: String, title: String, caption: String) -> some View {
    AutoLoomTheme.background
      .ignoresSafeArea()
      .overlay {
        VStack(spacing: 18) {
          Image(systemName: systemImage)
            .font(.system(size: 42, weight: .light))
            .foregroundStyle(AutoLoomTheme.electricBlue)
          VStack(spacing: 6) {
            Text(title)
              .font(.title3.bold())
            Text(caption)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)
          }
        }
        .padding(.horizontal, 40)
      }
  }

  // MARK: Top

  private var topBar: some View {
    HStack(spacing: 10) {
      AutoLoomMark(size: 30)
      VStack(alignment: .leading, spacing: 1) {
        Text(AutoLoomBrand.appName)
          .font(.headline)
          .lineLimit(1)
          .minimumScaleFactor(0.8)
        Text(audioRouteLabel)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      Spacer()
      Button { showSettings = true } label: {
        Image(systemName: "gearshape")
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Open settings")
    }
    .padding(.top, 6)
  }

  private var audioRouteLabel: String {
    let input = audioRoute.inputs.first.map { "\($0.name)" } ?? "—"
    let output = audioRoute.outputs.first.map { "\($0.name)" } ?? "—"
    return "Mic: \(input) · Speaker: \(output)"
  }

  private var cameraSourcePicker: some View {
    HStack(spacing: 6) {
      ForEach(CaptureSource.allCases, id: \.rawValue) { source in
        Button {
          captureSourceRaw = source.rawValue
        } label: {
          Label(source.label, systemImage: source.systemImage)
            .font(.subheadline.weight(.semibold))
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity, minHeight: 36)
            .foregroundStyle(source == captureSource ? Color.white : Color.white.opacity(0.75))
            .background(
              source == captureSource ? AutoLoomTheme.electricBlue.opacity(0.85) : Color.clear,
              in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Camera: \(source.label)")
        .accessibilityAddTraits(source == captureSource ? .isSelected : [])
      }
    }
    .padding(4)
    .background(.ultraThinMaterial, in: Capsule())
  }

  private var debugOverlay: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("Camera \(metrics.source) · \(metrics.inputResolution) \(metrics.pixelFormat)")
      Text(String(format: "FPS %.1f · received %llu · dropped %llu", metrics.measuredFPS, metrics.framesReceived, metrics.previewDropped))
      Text("Phone processing median \(ms(metrics.processingMedianMs)) · p95 \(ms(metrics.processingP95Ms))")
      Text("Capture→phone median \(ms(metrics.transportMedianMs)) · p95 \(ms(metrics.transportP95Ms))")
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

  // MARK: Conversation

  private var conversationPanel: some View {
    VStack(spacing: 12) {
      if !orchestrator.sources.isEmpty { sourcesStrip }
      if let question = orchestrator.typedQuestion { typedAnswerCard(question: question) }
      if let caption {
        VStack(alignment: .leading, spacing: 6) {
          Text(caption.role)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
          Text(caption.text)
            .font(.body.weight(.medium))
            .lineLimit(5)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .transition(.opacity)
      } else if voice.state == .disconnected && orchestrator.typedQuestion == nil {
        Text("Tap to talk — ask anything, or about what you see")
          .font(.subheadline)
          .foregroundStyle(.white.opacity(0.75))
          .multilineTextAlignment(.center)
      }

      if showTextInput { textInputRow }

      HStack(alignment: .center) {
        statusView
          .frame(maxWidth: .infinity, alignment: .leading)
        callButton
        HStack(spacing: 8) {
          secondaryButton
          Button {
            showTextInput.toggle()
            textFieldFocused = showTextInput
          } label: {
            Image(systemName: "keyboard")
              .frame(width: 44, height: 44)
              .background(.thinMaterial, in: Circle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(showTextInput ? "Hide text input" : "Type a question")
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    }
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: voice.state)
    .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: caption?.text)
    .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: orchestrator.activity)
  }

  private var textInputRow: some View {
    HStack(spacing: 8) {
      TextField("Type a question", text: $typedText, axis: .vertical)
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
      .buttonStyle(.plain)
      .disabled(typedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityLabel("Send question")
    }
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
        Text("You (typed)")
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
        Spacer()
        Button { orchestrator.clearSources() } label: {
          Image(systemName: "xmark")
            .font(.caption.bold())
            .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Dismiss answer")
      }
      Text(question)
        .font(.subheadline)
        .lineLimit(2)
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
          Text(statusLabel.label)
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
              if let snippet = source.snippet {
                Text(snippet)
                  .font(.caption2)
                  .foregroundStyle(.secondary)
                  .lineLimit(2)
              }
              HStack(spacing: 4) {
                Image(systemName: "link")
                Text(source.host)
                  .lineLimit(1)
              }
              .font(.caption2)
              .foregroundStyle(AutoLoomTheme.electricBlue)
              Text("Fetched \(source.fetchedAt.formatted(date: .omitted, time: .shortened))" +
                   (source.publishedAt.map { " · Published \($0)" } ?? ""))
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
            .frame(width: 200, alignment: .leading)
            .padding(10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
          }
          .buttonStyle(.plain)
          .accessibilityLabel("Source: \(source.title), \(source.host)")
          .accessibilityHint("Opens the page in your browser")
        }
      }
    }
  }

  // MARK: Status and controls

  /// Short status words; Turkish when the app language is Turkish or the
  /// device runs in Turkish.
  private func word(_ english: String, _ turkish: String) -> String {
    let language = AssistantPreferences.language
    if language == "tr" { return turkish }
    if language == "en" { return english }
    return Locale.current.language.languageCode?.identifier == "tr" ? turkish : english
  }

  private var statusLabel: (label: String, symbol: String, isError: Bool) {
    if voice.isMicrophoneMuted { return (word("Mic muted", "Mikrofon kapalı"), "mic.slash.fill", false) }
    if case .failed(let message) = voice.state { return (message, "exclamationmark.triangle.fill", true) }
    switch orchestrator.activity {
    case .seeing: return (word("Seeing", "Görüntüyü inceliyor"), "eye", false)
    case .searching: return (word("Searching", "Araştırıyor"), "globe", false)
    case .thinking: return (word("Thinking", "Düşünüyor"), "ellipsis", false)
    case nil: break
    }
    switch voice.state {
    case .disconnected: return (word("Ready", "Hazır"), "circle.fill", false)
    case .connecting: return (word("Connecting", "Bağlanıyor"), "antenna.radiowaves.left.and.right", false)
    case .listening: return (word("Listening", "Dinliyor"), "ear.fill", false)
    case .thinking: return (word("Thinking", "Düşünüyor"), "ellipsis", false)
    case .speaking: return (word("Speaking", "Konuşuyor"), "waveform", false)
    case .failed(let message): return (message, "exclamationmark.triangle.fill", true)
    }
  }

  private var statusView: some View {
    let status = statusLabel
    return HStack(spacing: 7) {
      if voice.state == .connecting {
        ProgressView().controlSize(.small).tint(.white)
      } else {
        Image(systemName: status.symbol)
          .foregroundStyle(status.isError ? Color.red : Color.white)
          .font(status.symbol == "circle.fill" ? .system(size: 7) : .footnote)
      }
      Text(status.isError ? word("Error", "Hata") : status.label)
        .font(.footnote.weight(.medium))
        .lineLimit(1)
    }
    .foregroundStyle(.white.opacity(0.9))
    .accessibilityElement(children: .combine)
    .accessibilityLabel("Status: \(status.label)")
    .contextMenu {
      if status.isError { Text(status.label) }
    }
  }

  @ViewBuilder
  private var secondaryButton: some View {
    if orchestrator.activity != nil {
      Button {
        orchestrator.cancelAll(reason: "cancelled by user", voiceOnly: false)
      } label: {
        Image(systemName: "xmark.circle.fill")
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Cancel the current task")
    } else if voice.state == .speaking {
      Button { voice.stopSpeaking() } label: {
        Image(systemName: "hand.raised.fill")
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Stop speaking")
      .accessibilityHint("Stops the current answer and keeps listening")
    } else if voice.isActive {
      Button { voice.toggleMicrophoneMuted() } label: {
        Image(systemName: voice.isMicrophoneMuted ? "mic.fill" : "mic.slash.fill")
          .frame(width: 44, height: 44)
          .background(.thinMaterial, in: Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel(voice.isMicrophoneMuted ? "Unmute microphone" : "Mute microphone")
    } else {
      Color.clear.frame(width: 44, height: 44)
    }
  }

  private var callButton: some View {
    Button {
      Task {
        if voice.isActive {
          await voice.stop()
        } else {
          let route = AudioRoutePreference.current
          await voice.start(
            prefersBluetoothHFP: route.prefersGlassesAudio(for: captureSource),
            forcesBuiltInAudio: route == .iPhone)
        }
      }
    } label: {
      ZStack {
        Circle()
          .fill(voice.isActive ? Color.red : AutoLoomTheme.electricBlue)
          .frame(width: 72, height: 72)
          .shadow(color: AutoLoomTheme.electricBlue.opacity(voice.isActive ? 0 : 0.45), radius: 14, y: 4)
        if voice.state == .connecting {
          ProgressView().tint(.white)
        } else {
          Image(systemName: voice.isActive ? "phone.down.fill" : "waveform")
            .font(.system(size: 25, weight: .semibold))
            .foregroundStyle(.white)
        }
      }
      .frame(width: 76, height: 76)
      .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(voice.state == .connecting)
    .accessibilityLabel(voice.isActive ? "End conversation" : "Start conversation")
    .accessibilityHint(voice.isActive ? "Ends the voice conversation" : "Starts a live voice conversation")
  }
}
