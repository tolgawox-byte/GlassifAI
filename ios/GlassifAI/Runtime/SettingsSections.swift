import SwiftUI
import UIKit

enum AppInfo {
  static var version: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
  }

  static var build: String {
    Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
  }

  /// Stamped by CI (`AUTOLOOM_COMMIT_SHA`); empty for local Xcode builds.
  static var commit: String {
    let value = (Bundle.main.object(forInfoDictionaryKey: "AutoLoomCommitSHA") as? String ?? "")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return value.isEmpty || value.hasPrefix("$(") ? "local build" : value
  }
}

// MARK: Privacy

/// Settings → Privacy center: what leaves the phone, what is stored, every
/// permission and its state, and deleting local data.
struct PrivacySettingsView: View {
  @ObservedObject private var memory = MemoryStore.shared
  @ObservedObject private var captures = CaptureLibrary.shared
  @State private var permissions: [AppPermission: PermissionState] = [:]
  @State private var confirmWipe = false
  @State private var wiped = false
  @Environment(\.openURL) private var openURL

  var body: some View {
    Form {
      Section(L.t("What leaves this iPhone", "Bu iPhone'dan ne çıkar")) {
        privacyRow(
          L.t("Voice", "Ses"),
          L.t("Microphone audio streams to ChatGPT's realtime voice only while a conversation is active.",
              "Mikrofon sesi yalnızca konuşma sürerken ChatGPT canlı sesine gider."), "waveform")
        privacyRow(
          L.t("Camera", "Kamera"),
          L.t("A camera frame is sent only when a request needs to see. The preview never leaves the phone.",
              "Kamera karesi yalnızca bir istek görmeyi gerektirdiğinde gönderilir. Önizleme telefondan çıkmaz."), "camera")
        privacyRow(
          L.t("Web search", "Web araması"),
          L.t("Searches run through your ChatGPT account on OpenAI's servers.",
              "Aramalar ChatGPT hesabınızla OpenAI sunucularında yapılır."), "globe")
        privacyRow(
          L.t("Memories", "Anılar"),
          L.t("Only the few memories relevant to a request are added to your own ChatGPT request.",
              "Bir isteğe yalnızca ilgili birkaç anı eklenir."), "brain")
        privacyRow(
          L.t("Account", "Hesap"),
          L.t("ChatGPT sign-in tokens stay in this iPhone's Keychain and are sent only to OpenAI.",
              "ChatGPT oturum anahtarları bu iPhone'un Anahtar Zinciri'nde kalır ve yalnızca OpenAI'ye gider."), "key")
      }
      Section(L.t("What is stored on this iPhone", "Bu iPhone'da ne saklanır")) {
        privacyRow(
          L.t("Memories and notes", "Anılar ve notlar"),
          L.t("\(memory.memories.count) memories and \(memory.notes.count) notes you asked to save (SwiftData, on this iPhone only).",
              "Kaydetmenizi istediğiniz \(memory.memories.count) anı ve \(memory.notes.count) not (SwiftData, yalnızca bu iPhone'da)."),
          "tray")
        privacyRow(L.t("Visual memories", "Görsel anılar"), visualSummary, "eye")
        privacyRow(
          L.t("Ray-Ban captures", "Ray-Ban çekimleri"),
          L.t("\(captures.records.count) photos and videos: labels and small thumbnails. The photos and videos are in your Photos library, or in AutoLoom when kept here. Never uploaded.",
              "\(captures.records.count) fotoğraf ve video: etiketler ve küçük önizlemeler. Fotoğraf ve videolar Fotoğraflar arşivinizde, burada tutulanlar AutoLoom'da. Asla yüklenmez."),
          "photo.stack")
        privacyRow(
          L.t("Conversation context", "Konuşma bağlamı"),
          L.t("Kept in memory for the current app session only.",
              "Yalnızca bu uygulama oturumu boyunca bellekte tutulur."), "text.bubble")
        privacyRow(
          L.t("Diagnostics", "Tanılama"),
          L.t("In-memory metrics and sanitized errors; no audio, images or tokens are logged.",
              "Bellekteki ölçümler ve temizlenmiş hatalar; ses, görüntü veya anahtar kaydedilmez."), "stethoscope")
      }
      Section(
        header: Text(L.t("Permissions", "İzinler")),
        footer: Text(L.t("Each permission is asked only when a feature needs it.",
                         "Her izin yalnızca bir özellik ona ihtiyaç duyduğunda istenir."))) {
        ForEach(AppPermission.allCases) { permission in
          VStack(alignment: .leading, spacing: 2) {
            HStack {
              Label(permission.label, systemImage: permission.systemImage)
              Spacer()
              Text(permissions[permission]?.label ?? "…")
                .font(.footnote)
                .foregroundStyle(permissions[permission] == .denied ? Color.orange : Color.secondary)
            }
            Text(permission.purpose)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Button(L.t("Open iOS Settings", "iOS Ayarlarını aç")) {
          if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        }
      }
      Section(L.t("Safety", "Güvenlik")) {
        privacyRow(
          L.t("Untrusted content", "Güvenilmeyen içerik"),
          L.t("Text from web pages, images, signs and QR codes is information, never an instruction.",
              "Web sayfaları, görüntüler, tabelalar ve QR kodlardaki metin bilgidir, asla talimat değildir."), "shield")
        privacyRow(
          L.t("Actions", "İşlemler"),
          L.t("Reminders and events need your yes; calls, messages, links, maps and sharing need a tap. The app never sends email, buys, deletes your data or posts.",
              "Anımsatıcı ve etkinlikler onayınızı; arama, mesaj, bağlantı, harita ve paylaşım dokunmanızı gerektirir. Uygulama e-posta göndermez, satın almaz, verilerinizi silmez veya paylaşım yapmaz."),
          "hand.raised")
      }
      Section {
        Button(L.t("Delete all local data", "Tüm yerel verileri sil"), role: .destructive) { confirmWipe = true }
        if wiped {
          Label(L.t("Local data deleted", "Yerel veriler silindi"), systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      } footer: {
        Text(L.t(
          "Deletes memories, notes, AutoLoom's captures list and the captures kept only in AutoLoom, the conversation context, sources and diagnostics. Your ChatGPT sign-in stays until you disconnect it. Apple Reminders, Calendar and your Photos library are not touched.",
          "Anıları, notları, AutoLoom çekim listesini ve yalnızca AutoLoom'da tutulan çekimleri, konuşma bağlamını, kaynakları ve tanılamayı siler. ChatGPT oturumu siz kesene kadar kalır. Apple Anımsatıcılar, Takvim ve Fotoğraflar arşivinize dokunulmaz."))
      }
    }
    .navigationTitle(L.t("Privacy center", "Gizlilik merkezi"))
    .task {
      var states: [AppPermission: PermissionState] = [:]
      for permission in AppPermission.allCases {
        states[permission] = await PermissionCenter.state(permission)
      }
      permissions = states
    }
    .confirmationDialog(
      L.t("Delete all local data?", "Tüm yerel veriler silinsin mi?"), isPresented: $confirmWipe, titleVisibility: .visible
    ) {
      Button(L.t("Delete", "Sil"), role: .destructive) {
        MemoryStore.shared.deleteEverything()
        CaptureLibrary.shared.deleteEverything()
        DealerStore.shared.deleteEverything()
        ShoppingListStore.shared.deleteEverything()
        ParkingStore.shared.clear()
        AssistantOrchestrator.shared.wipeConversationData()
        FrameStore.shared.reset()
        wiped = true
      }
    }
  }

  private var visualSummary: String {
    guard memory.visualMemoriesEnabled else { return L.t("Off.", "Kapalı.") }
    let photos = memory.saveVisualPhotos ? L.t("on", "açık") : L.t("off", "kapalı")
    let places = memory.attachLocation ? L.t("on", "açık") : L.t("off", "kapalı")
    return L.t("On. Photos: ", "Açık. Fotoğraf: ") + photos + L.t(". Places: ", ". Konum: ") + places + "."
  }

  private func privacyRow(_ title: String, _ detail: String, _ icon: String) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: icon)
        .foregroundStyle(AutoLoomTheme.electricBlue)
        .frame(width: 22)
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.subheadline.weight(.semibold))
        Text(detail).font(.footnote).foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 2)
  }
}

// MARK: Task trace

/// Settings → Developer → Task trace: recent turns with routes, models,
/// timings and image metadata, copyable in sanitized form.
struct TaskTraceView: View {
  var voice: GlassifAIRealtimeSession?
  @ObservedObject private var ledger = AssistantOrchestrator.shared.ledger
  @ObservedObject private var actions = ActionTraceLog.shared
  @State private var copied = false

  var body: some View {
    List {
      Section {
        Button(copied ? L.t("Copied", "Kopyalandı") : L.t("Copy sanitized task trace", "Temizlenmiş görev izini kopyala")) {
          UIPasteboard.general.string = TaskTrace.text(records: ledger.records, start: voice?.startReport) +
            "\n\nVoice actions:\n" + actions.text
          copied = true
        }
      } footer: {
        Text(L.t(
          "Requests are shortened; emails, long numbers, tokens and image data are removed. No audio or images.",
          "İstekler kısaltılır; e-postalar, uzun numaralar, anahtarlar ve görüntü verisi çıkarılır. Ses veya görüntü yoktur."))
      }
      Section {
        if actions.entries.isEmpty {
          Text(L.t("No spoken commands yet", "Henüz sesli komut yok")).foregroundStyle(.secondary)
        }
        ForEach(Array(actions.entries.reversed())) { entry in
          VStack(alignment: .leading, spacing: 3) {
            Text("\(entry.canonical.isEmpty ? entry.intent : entry.canonical) · \(entry.result)")
              .font(.footnote.weight(.semibold))
            Text("“\(entry.transcript)”")
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("Parser: \(entry.parser)").font(.caption2)
            Text("Parsed: \(entry.parsed)").font(.caption2)
            Text("Permission: \(entry.permission)").font(.caption2)
            Text("Executor: \(entry.executor)" + (entry.durationMs.map { " · \($0) ms" } ?? "")).font(.caption2)
            Text("Persistence: \(entry.persistence)").font(.caption2)
            Text("Spoken: \(entry.spoken)").font(.caption2)
          }
          .foregroundStyle(.primary)
          .padding(.vertical, 2)
        }
      } header: {
        Text(L.t("Voice actions", "Sesli işlemler"))
      } footer: {
        Text(L.t(
          "Transcript → intent → parser → permission → executor → result for notes, memory, reminders, tasks and the calendar. Text is shortened and numbers removed.",
          "Notlar, hafıza, anımsatıcılar, görevler ve takvim için döküm → niyet → ayrıştırıcı → izin → yürütücü → sonuç. Metin kısaltılır, numaralar çıkarılır."))
      }
      Section(L.t("Recent turns", "Son adımlar")) {
        if ledger.records.isEmpty {
          Text(L.t("No tasks yet", "Henüz görev yok")).foregroundStyle(.secondary)
        }
        ForEach(Array(ledger.records.suffix(15).reversed())) { record in
          VStack(alignment: .leading, spacing: 3) {
            Text("\(record.kind?.displayName ?? "Routing") · turn \(record.turnID)")
              .font(.footnote.weight(.semibold))
            Text(TaskTrace.redactUserText(record.request))
              .font(.caption)
              .foregroundStyle(.secondary)
            Text("via \(record.routeOrigin?.rawValue ?? "—") · model \(record.model ?? "—")")
              .font(.caption2)
              .foregroundStyle(.secondary)
            ForEach(record.notes, id: \.self) { note in
              Text(note).font(.caption2).foregroundStyle(.orange)
            }
            ForEach(record.timeline.breakdown, id: \.stage) { item in
              Text("\(item.stage): \(item.ms) ms").font(.caption2.monospaced())
            }
          }
          .padding(.vertical, 2)
        }
      }
    }
    .navigationTitle(L.t("Action & task trace", "İşlem ve görev izi"))
  }
}

// MARK: Diagnostics

struct DiagnosticsView: View {
  let voice: GlassifAIRealtimeSession?
  let glassesStream: StreamSessionViewModel?
  @ObservedObject private var orchestrator = AssistantOrchestrator.shared
  @ObservedObject private var ledger = AssistantOrchestrator.shared.ledger
  @ObservedObject private var audioRoute = AudioRouteMonitor.shared
  @ObservedObject private var liveVision = LiveVisionController.shared
  @State private var metrics = FrameMetricsSnapshot()
  @State private var sidebandStatus = "—"
  @State private var copied = false

  private var batteryLabel: String {
    let device = UIDevice.current
    device.isBatteryMonitoringEnabled = true
    let level = device.batteryLevel < 0 ? "unknown" : "\(Int((device.batteryLevel * 100).rounded()))%"
    let state: String
    switch device.batteryState {
    case .charging: state = "charging"
    case .full: state = "full"
    case .unplugged: state = "on battery"
    default: state = "unknown"
    }
    return "\(level), \(state)"
  }

  private var thermalLabel: String {
    switch ProcessInfo.processInfo.thermalState {
    case .nominal: "nominal"
    case .fair: "fair"
    case .serious: "serious (Live Vision slows down)"
    case .critical: "critical (Live Vision paused)"
    @unknown default: "unknown"
    }
  }

  var body: some View {
    List {
      Section("App") {
        row("App", AutoLoomBrand.appName)
        row("Version", "\(AppInfo.version) (\(AppInfo.build))")
        row("Commit", AppInfo.commit)
        row("Native bridge", EmbeddedCodexBridge.bridgeVersion())
      }
      Section("ChatGPT") {
        row("Provider", "ChatGPT account · chatgpt.com/backend-api/codex")
        row("OAuth", oauthStatus)
        row("Token", tokenExpiry)
        row("Realtime model (requested / active)", "\(ModelSelector.realtimeModel) / \(voice?.startReport?.activeModel ?? "—")")
        row("Voice (selected / active)", "\(AssistantPreferences.voice) / \(voice?.startReport?.activeVoice ?? "—")")
        row("Realtime start", voice?.startReport?.step?.label ?? voice?.startMode?.rawValue ?? "not started")
        row("Voice fallback reason", voice?.startReport?.fallbackReason ?? "none")
        ForEach(Array((voice?.startReport?.attempts ?? []).enumerated()), id: \.offset) { item in
          row("Start attempt \(item.offset + 1)", item.element)
        }
        row("Service default model", catalog.first(where: \.isListed)?.slug ?? models.first ?? "—")
        row("General model", pick(.generalChat))
        row("Vision model", pick(.vision, images: true))
        row("Reasoning model", pick(.deepReasoning))
        row("Web model", pick(.webSearch, web: true))
        row("Models available", "\(models.count)" + (ChatGPTAuthSession.shared.modelsError.map { " — \($0)" } ?? ""))
        row("GPT-6 Astra", ModelRouting.gpt6AstraStatus(catalog: catalog, health: ModelHealth.shared.entries))
        row("Model status", modelHealthSummary)
      }
      Section("Realtime") {
        row("Voice state", voiceState)
        row("Sideband", sidebandStatus)
        row("Connect time", voice?.lastConnectMs.map { "\($0) ms" } ?? "—")
        row("Last end reason", voice?.lastEndReason ?? "—")
        row("Wake phrase", "\(WakePhraseSettings.phrase) — \(WakePhraseListener.shared.status.label)")
        row("Response latency (median)", voice?.responseLatencyMedianMs.map { "\($0) ms" } ?? "—")
        row("Auto-reconnects", "\(voice?.reconnectCount ?? 0)" + (voice?.lastReconnectReason.map { " — last: \($0)" } ?? ""))
        row("Last realtime error", voice?.lastRealtimeError ?? "none")
      }
      Section("Ray-Ban (Meta DAT)") {
        row("DAT SDK", GlassesSDKInfo.datVersion)
        row("Glasses", glassesStream?.deviceDescription ?? "—")
        row("Stream state", glassesStream?.lastStreamState ?? "—")
        row("Profile", glassesStream.map { "\($0.streamProfile.label)" } ?? "—")
        row("Requested", requestedStream)
        row("Actual", actualStream)
        row("Transport", glassesStream?.activeTransport.shortLabel ?? "—")
        if let note = glassesStream?.transportNote { row("Transport note", note) }
        row("Last stream error", glassesStream?.lastStreamError ?? "none")
      }
      Section("Ray-Ban frames and vision images") {
        row("Active glasses", AudioRouteMonitor.shared.glassesName ?? "—")
        row("Delivered as", metrics.glassesCompressed.map { $0 ? "compressed (decoded by app)" : "raw (decoded by SDK)" } ?? "—")
        row("Codec / pixel format", metrics.glassesCodec)
        row("Sample size", metrics.glassesSampleSize)
        row("Raw / compressed samples", "\(metrics.rawSamples) / \(metrics.compressedSamples)")
        row("Decoded frames / failures", "\(metrics.decodedFrames) / \(metrics.decodeFailures)")
        row("Copy fallbacks", "\(metrics.copyFailures)")
        row("FrameStore sequence", "\(metrics.latestSequence)")
        row("Vision image mode", GlassesVisionCaptureMode.current.label)
        row("Vision quality", VisionQualityPreference.current.label)
        row("Text detail mode", VisionAssistPreferences.textAssist ? "on (on-device OCR + zoomed crop)" : "off")
        row("Enlarge for reading", VisionAssistPreferences.upscale ? "on (≤1.6×, patch budget)" : "off")
        row("Best-frame window", "last \(FrameStore.recentCapacity) frames, ≤\(Int(AssistantOrchestrator.maxFrameAge * 1_000)) ms old")
        row("Still photo support", "In-stream capture (DAT \(GlassesSDKInfo.datVersion)) = a frame of the video stream; full-resolution photo needs DAT 1.0")
        row("Photos requested / received / failed", "\(metrics.photosRequested) / \(metrics.photosReceived) / \(metrics.photoFailures)")
        row("Last photo", "\(metrics.lastPhotoResolution)" + (metrics.lastPhotoLatencyMs.map { " in \($0) ms" } ?? ""))
        row("Last AI image", metrics.lastVisionImage)
      }
      Section("Live Vision") {
        row("Status", liveVision.status.label)
        row("Started", liveVision.startedAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
        row("Notes sent / stable skips", "\(liveVision.updateCount) / \(liveVision.skippedStable)")
        row("Last note", liveVision.lastUpdateAt.map { $0.formatted(date: .omitted, time: .standard) } ?? "—")
        row("Last error", liveVision.lastError ?? "none")
        row("Last stop", liveVision.lastStopReason ?? "—")
        row("Thermal state", thermalLabel)
        row("Battery", batteryLabel)
        row("Power state", powerState)
      }
      Section("Camera pipeline") {
        row("Source", metrics.source)
        row("Input resolution", "\(metrics.inputResolution) \(metrics.pixelFormat)")
        row("Measured FPS (received / shown)", String(format: "%.1f / %.1f", metrics.measuredFPS, metrics.renderedFPS))
        row("Frames received", "\(metrics.framesReceived)")
        row("Preview rendered / dropped", "\(metrics.previewRendered) / \(metrics.previewDropped)")
        row("Preview failures", "\(metrics.previewFailures)")
        row("Phone processing (median / p95)", "\(ms(metrics.processingMedianMs)) / \(ms(metrics.processingP95Ms))")
        row("Capture→phone (median / p95)", "\(ms(metrics.transportMedianMs)) / \(ms(metrics.transportP95Ms))")
        row("Last frame age", metrics.lastFrameAgeMs.map { "\($0) ms" } ?? "—")
        row("Preview", metrics.previewMode)
        row("Preview resolution", metrics.previewResolution)
        row("Per-frame work", metrics.conversionsPerFrame)
      }
      Section("Audio") {
        row("Microphone", audioRoute.inputSummary)
        row("Speaker", audioRoute.outputSummary)
        row("Available inputs", audioRoute.availableInputs.map(\.name).joined(separator: ", ").ifEmpty("—"))
        row("Interrupted", audioRoute.isInterrupted ? "yes" : "no")
        row("Last audio event", audioRoute.lastEvent)
        row("Route preference", AudioRoutePreference.current.label)
      }
      Section("Actions and agent") {
        row("iPhone actions", AssistantPreferences.actionsEnabled ? "on" : "off")
        row("Waiting for confirmation", orchestrator.pendingAction?.plan.summary ?? "none")
        row("Last action result", orchestrator.lastActionResult.map { LogSanitizer.sanitize($0, limit: 160) } ?? "—")
        row("Agent gateway", agentGatewayStatus)
      }
      Section("Web search") {
        row("Enabled", AssistantPreferences.webSearchEnabled ? "yes" : "no")
        row("Last status", orchestrator.lastWebStatus)
      }
      Section("Recent tasks") {
        if ledger.records.isEmpty {
          Text("No tasks yet").foregroundStyle(.secondary)
        }
        ForEach(Array(ledger.records.suffix(6).reversed())) { record in
          taskRow(record)
        }
      }
      Section("Errors") {
        row("Last task error", orchestrator.lastError ?? "none")
      }
      Section {
        Button(copied ? "Copied" : "Copy diagnostics report") {
          UIPasteboard.general.string = report()
          copied = true
        }
      } footer: {
        Text("The report is sanitized: no tokens, audio, images, or email addresses.")
      }
    }
    .navigationTitle("Diagnostics")
    .task {
      while !Task.isCancelled {
        metrics = FrameStore.shared.snapshot()
        sidebandStatus = LogSanitizer.sanitize(EmbeddedCodexBridge.sidebandStatus(), limit: 160)
        audioRoute.refresh()
        try? await Task.sleep(nanoseconds: 1_000_000_000)
      }
    }
  }

  /// Idle, Hands-Free Ready, Conversation or Live Vision: what is using the
  /// microphone and camera right now.
  private var powerState: String {
    if liveVision.isActive { return "Live Vision (camera notes during a conversation)" }
    if voice?.isActive == true { return "Conversation" }
    if WakePhraseListener.shared.status.isListening { return "Hands-Free Ready (on-device wake phrase)" }
    return "Idle"
  }

  private var models: [String] { ChatGPTAuthSession.shared.availableModels }
  private var catalog: [CatalogModel] { ChatGPTAuthSession.shared.modelCatalog }

  private func pick(_ kind: AssistantTaskKind, images: Bool = false, web: Bool = false) -> String {
    ModelSelector.model(
      for: kind, available: models, needsHostedWebSearch: web, catalog: catalog, needsImages: images,
      excluded: ModelHealth.shared.failedThisRun) ?? "—"
  }

  /// Host only: the token and the full address stay out of diagnostics.
  private var agentGatewayStatus: String {
    guard AgentGatewayConfig.isEnabled else { return "off" }
    let host = AgentGatewayConfig.baseURL?.host ?? "no valid address"
    return AgentGatewayConfig.isReady ? "ready (\(host))" : "enabled, not ready (\(host), token \(AgentTokenStore.hasToken ? "saved" : "missing"))"
  }

  private var modelHealthSummary: String {
    let entries = ModelHealth.shared.entries
    guard !entries.isEmpty else { return "no requests yet" }
    return entries.sorted { $0.key < $1.key }
      .map { "\($0.key): \($0.value.working ? "working" : "failed")" }
      .joined(separator: ", ")
  }

  private var requestedStream: String {
    guard let glassesStream else { return "—" }
    return "\(glassesStream.streamProfile.requestedSummary), \(glassesStream.activeTransport.shortLabel)"
  }

  /// What really arrives, measured from the frame store (Ray-Ban frames only).
  private var actualStream: String {
    guard metrics.source == FrameSourceKind.glasses.rawValue, metrics.inputWidth > 0 else { return "no Ray-Ban frames" }
    return "\(metrics.inputResolution) @ \(String(format: "%.1f", metrics.measuredFPS)) fps \(metrics.pixelFormat)"
  }

  private var oauthStatus: String {
    switch ChatGPTAuthSession.shared.status {
    case .authenticated(let user): "signed in" + (user.plan.map { " · plan \($0)" } ?? "")
    case .unauthenticated: "signed out"
    case .pending: "waiting for device code"
    case .loading, .connecting: "connecting"
    case .error(let message): "error: \(LogSanitizer.sanitize(message, limit: 120))"
    }
  }

  private var tokenExpiry: String {
    guard let expiresAt = (try? ChatGPTKeychain.load())?.expiresAt else { return "—" }
    let minutes = Int((expiresAt / 1_000 - Date().timeIntervalSince1970) / 60)
    return minutes > 0 ? "access token valid ~\(minutes) min (auto-refresh)" : "expired (refreshes on next request)"
  }

  private var voiceState: String {
    guard let voice else { return "—" }
    switch voice.state {
    case .disconnected: return "disconnected"
    case .connecting: return "connecting"
    case .listening: return "listening"
    case .thinking: return "thinking"
    case .speaking: return "speaking"
    case .failed(let message): return "failed: \(LogSanitizer.sanitize(message, limit: 120))"
    }
  }

  private func taskRow(_ record: AssistantTaskRecord) -> some View {
    VStack(alignment: .leading, spacing: 3) {
      Text("\(record.kind?.rawValue ?? "ROUTING") · \(phaseLabel(record.phase))")
        .font(.footnote.weight(.semibold))
      Text("via \(record.routeOrigin?.rawValue ?? "—") · \(record.source.rawValue) · model \(record.model ?? "—")")
        .font(.caption2)
        .foregroundStyle(.secondary)
      Text("session \(record.sessionID.uuidString.prefix(8)) · turn \(record.turnID) · task \(record.id.uuidString.prefix(8))")
        .font(.caption2.monospaced())
        .foregroundStyle(.secondary)
      if let frame = record.frame {
        Text(frame.summary)
          .font(.caption2)
          .foregroundStyle(.secondary)
      }
      ForEach(record.timeline.breakdown, id: \.stage) { item in
        Text("\(item.stage): \(item.ms) ms")
          .font(.caption2.monospaced())
      }
    }
    .padding(.vertical, 2)
  }

  private func phaseLabel(_ phase: AssistantTaskPhase) -> String {
    switch phase {
    case .routing: "routing"
    case .capturingFrame: "capturing frame"
    case .searching: "searching"
    case .analyzing: "analyzing"
    case .reasoning: "reasoning"
    case .delivering: "delivering"
    case .completed: "completed"
    case .cancelled(let reason): "cancelled (\(reason))"
    case .failed(let reason): "failed (\(LogSanitizer.sanitize(reason, limit: 100)))"
    }
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(title)
        .font(.footnote)
      Spacer(minLength: 12)
      Text(value)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }

  private func ms(_ value: Double?) -> String {
    value.map { String(format: "%.0f ms", $0) } ?? "—"
  }

  private func report() -> String {
    var lines: [String] = [
      "\(AutoLoomBrand.appName) diagnostics \(Date().formatted())",
      "version \(AppInfo.version) (\(AppInfo.build)) commit \(AppInfo.commit) bridge \(EmbeddedCodexBridge.bridgeVersion())",
      "oauth: \(oauthStatus); models: \(models.count) [\(models.prefix(12).joined(separator: ","))]; realtime \(ModelSelector.realtimeModel) start: \(voice?.startReport?.step?.rawValue ?? "—"); voice selected \(AssistantPreferences.voice) active \(voice?.startReport?.activeVoice ?? "—"); fallback \(voice?.startReport?.fallbackReason ?? "none")",
      "model picks: general \(pick(.generalChat)); vision \(pick(.vision, images: true)); reasoning \(pick(.deepReasoning)); web \(pick(.webSearch, web: true)); status \(modelHealthSummary)",
      "gpt-6 astra: \(ModelRouting.gpt6AstraStatus(catalog: catalog, health: ModelHealth.shared.entries))",
      "voice: \(voiceState); sideband: \(sidebandStatus); connect \(voice?.lastConnectMs.map { "\($0) ms" } ?? "—"); response median \(voice?.responseLatencyMedianMs.map { "\($0) ms" } ?? "—"); reconnects \(voice?.reconnectCount ?? 0) (\(voice?.lastReconnectReason ?? "—")); realtime error: \(voice?.lastRealtimeError ?? "none")",
      "glasses: \(glassesStream?.lastStreamState ?? "—"); DAT \(GlassesSDKInfo.datVersion); device \(glassesStream?.deviceDescription ?? "—"); profile \(glassesStream?.streamProfile.rawValue ?? "—"); requested \(requestedStream); actual \(actualStream); transport note \(glassesStream?.transportNote ?? "none"); stream error \(glassesStream?.lastStreamError ?? "none")",
      "camera: \(metrics.source) \(metrics.inputResolution) \(metrics.pixelFormat) fps \(String(format: "%.1f", metrics.measuredFPS)) received \(metrics.framesReceived) rendered \(metrics.previewRendered) dropped \(metrics.previewDropped) failures \(metrics.previewFailures)",
      "glasses samples: \(metrics.glassesCompressed.map { $0 ? "compressed" : "raw" } ?? "—") \(metrics.glassesCodec) \(metrics.glassesSampleSize) raw \(metrics.rawSamples) compressed \(metrics.compressedSamples) decoded \(metrics.decodedFrames) decodeFail \(metrics.decodeFailures) copyFallback \(metrics.copyFailures) seq \(metrics.latestSequence)",
      "photos: requested \(metrics.photosRequested) received \(metrics.photosReceived) failed \(metrics.photoFailures) last \(metrics.lastPhotoResolution) \(metrics.lastPhotoLatencyMs.map { "\($0) ms" } ?? ""); vision mode \(GlassesVisionCaptureMode.current.rawValue); last AI image \(metrics.lastVisionImage)",
      "assistant: \(AssistantIdentity.name); addressed-only \(AssistantPreferences.respondsOnlyWhenAddressed); invocations \(VoiceStartCoordinator.shared.events.map { "\($0.reason.rawValue)=\($0.outcome.rawValue)" }.joined(separator: ","))",
      "latency: processing \(ms(metrics.processingMedianMs))/\(ms(metrics.processingP95Ms)) capture→phone \(ms(metrics.transportMedianMs))/\(ms(metrics.transportP95Ms)) frame age \(metrics.lastFrameAgeMs.map(String.init) ?? "—") ms; preview \(metrics.previewMode)",
      "audio: mic \(audioRoute.inputSummary); speaker \(audioRoute.outputSummary); interrupted \(audioRoute.isInterrupted); last \(audioRoute.lastEvent)",
      "web: enabled \(AssistantPreferences.webSearchEnabled); \(orchestrator.lastWebStatus)",
      "actions: \(AssistantPreferences.actionsEnabled ? "on" : "off"); pending \(orchestrator.pendingAction?.plan.kind.rawValue ?? "none"); agent gateway \(agentGatewayStatus)",
      "power: thermal \(thermalLabel); battery \(batteryLabel)",
      "live vision: \(liveVision.status.label); notes \(liveVision.updateCount); stable skips \(liveVision.skippedStable); error \(liveVision.lastError ?? "none"); last stop \(liveVision.lastStopReason ?? "—"); thermal \(thermalLabel)",
    ]
    for record in ledger.records.suffix(6) {
      let timeline = record.timeline.breakdown.map { "\($0.stage)=\($0.ms)" }.joined(separator: " ")
      lines.append("task \(record.kind?.rawValue ?? "ROUTING") \(phaseLabel(record.phase)) via \(record.routeOrigin?.rawValue ?? "—") model \(record.model ?? "—") \(timeline)")
    }
    lines.append("last error: \(orchestrator.lastError ?? "none")")
    return lines.map { LogSanitizer.sanitize($0, limit: 600) }.joined(separator: "\n")
  }
}

private extension String {
  func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

// MARK: About & licenses

struct LicensesView: View {
  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 18) {
        Text("Open-source attribution")
          .font(.title3.bold())
        Text("\(AutoLoomBrand.appName) is built on GlassifAI by Marco Iannello, used under the MIT License below. The original copyright notice is preserved.")
        Text(Self.mitLicense)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
        Text("Third-party components")
          .font(.headline)
        VStack(alignment: .leading, spacing: 10) {
          Text("• Meta Wearables Device Access Toolkit and camera-access sample code — Meta Wearables Developer Terms and Acceptable Use Policy (wearables.developer.meta.com). Upstream notices are preserved in the NOTICE file of the source repository.")
          Text("• OpenAI Codex (codex-api, codex-http-client, codex-protocol crates) — Apache License 2.0.")
          Text("• LiveKit WebRTC XCFramework — Apache License 2.0 (BSD-style WebRTC license for the underlying WebRTC code).")
        }
        .font(.footnote)
        Text("Code licenses are separate from service terms. Using ChatGPT and Meta services remains subject to OpenAI's and Meta's own terms.")
          .font(.footnote)
          .foregroundStyle(.secondary)
        Text(AutoLoomBrand.independenceNotice)
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      .padding(20)
    }
    .navigationTitle("Licenses")
  }

  static let mitLicense = """
  MIT License

  Copyright (c) 2026 Marco Iannello

  Permission is hereby granted, free of charge, to any person obtaining a copy of this software and associated documentation files (the "Software"), to deal in the Software without restriction, including without limitation the rights to use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of the Software, and to permit persons to whom the Software is furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
  """
}
