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

// MARK: Memory

struct MemorySettingsView: View {
  @ObservedObject private var memory = LocalMemoryStore.shared
  @State private var newItem = ""
  @State private var confirmDeleteAll = false

  var body: some View {
    Form {
      Section(footer: Text("Off by default. When on, the items below are stored only on this iPhone and are added as context to your own ChatGPT requests. Nothing is synced with ChatGPT's memory or chat history.")) {
        Toggle("On-device memory", isOn: $memory.isEnabled)
      }
      if memory.isEnabled {
        Section("Add") {
          HStack {
            TextField("Something to remember", text: $newItem)
            Button("Add") {
              if memory.add(newItem, source: "manual") { newItem = "" }
            }
            .disabled(newItem.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
      }
      Section(header: Text("Saved items (\(memory.items.count))")) {
        if memory.items.isEmpty {
          Text("Nothing saved.")
            .foregroundStyle(.secondary)
        }
        ForEach(memory.items) { item in
          NavigationLink {
            MemoryItemEditor(item: item)
          } label: {
            VStack(alignment: .leading, spacing: 2) {
              Text(item.text)
              Text("\(item.source) · \(item.createdAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
          }
        }
        .onDelete { offsets in
          offsets.map { memory.items[$0].id }.forEach(memory.delete)
        }
      }
      if !memory.items.isEmpty {
        Section {
          Button("Delete all memory", role: .destructive) { confirmDeleteAll = true }
        }
      }
    }
    .navigationTitle("Memory")
    .confirmationDialog("Delete all saved memory?", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
      Button("Delete all", role: .destructive) { memory.deleteAll() }
    }
  }
}

private struct MemoryItemEditor: View {
  let item: LocalMemoryStore.Item
  @State private var text = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    Form {
      TextField("Memory", text: $text, axis: .vertical)
        .lineLimit(2...6)
      Button("Save") {
        LocalMemoryStore.shared.update(item.id, text: text)
        dismiss()
      }
      Button("Delete", role: .destructive) {
        LocalMemoryStore.shared.delete(item.id)
        dismiss()
      }
    }
    .navigationTitle("Edit memory")
    .onAppear { text = item.text }
  }
}

// MARK: Privacy

struct PrivacySettingsView: View {
  @State private var confirmWipe = false
  @State private var wiped = false

  var body: some View {
    Form {
      Section("What leaves this iPhone") {
        privacyRow("Voice", "Your microphone audio streams to ChatGPT's realtime voice service only while a conversation is active.", "waveform")
        privacyRow("Camera", "A single camera frame is encoded and sent to ChatGPT only when a request needs to see. The preview itself never leaves the phone.", "camera")
        privacyRow("Web search", "Search requests run through your ChatGPT account (OpenAI's servers). The app never fetches web pages itself.", "globe")
        privacyRow("Account", "ChatGPT sign-in tokens are stored only in this iPhone's Keychain and sent only to OpenAI.", "key")
      }
      Section("What is stored on this iPhone") {
        privacyRow("Conversation context", "Kept in memory for the current app session only; cleared when the app quits or you wipe it below.", "text.bubble")
        privacyRow("On-device memory", "Only if you turn it on in Settings → Memory. Editable and deletable.", "brain")
        privacyRow("AutoLoom notes", "Notes and reports you ask to save, only on this iPhone (Settings → AutoLoom Tasks & Notes). Deletable.", "note.text")
        privacyRow("Diagnostics", "In-memory metrics and sanitized error text; no audio, images, or tokens are logged.", "stethoscope")
      }
      Section("Safety") {
        privacyRow("Untrusted content", "Text from web pages, images, signs, and QR codes is treated as information, never as instructions.", "shield")
        privacyRow("Actions", "Reminders, calendar events and notes are saved only after your spoken yes or a tap. Calls, messages, links, directions and sharing open only after a tap, and the system app lets you review before anything is sent. The app cannot send email, buy things, delete data, post publicly, push code, or deploy.", "hand.raised")
        privacyRow("Images", "Camera images are kept in memory only for the request that needs them and are never saved. On-device text recognition runs on the iPhone.", "photo")
      }
      Section {
        Button("Delete all local data", role: .destructive) { confirmWipe = true }
        if wiped {
          Label("Local data deleted", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        }
      } footer: {
        Text("Deletes on-device memory, AutoLoom notes, the current conversation context, sources, and diagnostics. Your ChatGPT sign-in stays until you disconnect it under ChatGPT account.")
      }
    }
    .navigationTitle("Privacy")
    .confirmationDialog("Delete all local data?", isPresented: $confirmWipe, titleVisibility: .visible) {
      Button("Delete", role: .destructive) {
        LocalMemoryStore.shared.deleteAll()
        AutoLoomNotesStore.shared.deleteAll()
        AssistantOrchestrator.shared.wipeConversationData()
        FrameStore.shared.reset()
        wiped = true
      }
    }
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

// MARK: Hands-free

/// Shows what hands-free invocation really works in this build, separating
/// system invocation (Meta, Apple) from the assistant's own name.
struct HandsFreeView: View {
  @ObservedObject private var coordinator = VoiceStartCoordinator.shared
  @Environment(\.openURL) private var openURL

  var body: some View {
    let name = AssistantIdentity.name
    Form {
      Section(
        header: Text("Assistant name"),
        footer: Text("Controlled by AutoLoom (Settings → Assistant). Use it while a conversation is active: \"\(name), what am I looking at?\" It does not wake the glasses or the iPhone.")) {
        LabeledContent("Assistant", value: name)
      }

      Section(
        header: Text("Meta glasses — system invocation"),
        footer: Text(HandsFreeCapabilities.metaInvocationRequirement)) {
        LabeledContent("System wake phrase", value: "Hey Meta")
        LabeledContent("\"Hey Meta, start …\" for this app", value: "Not available in this build")
        LabeledContent("Custom \"Hey \(name)\" wake word", value: "Not supported by the Meta API")
        LabeledContent("During a conversation", value: "Temple tap mutes/unmutes; long-press or fold ends")
      }

      Section(
        header: Text("iPhone — Siri"),
        footer: Text("Official iOS invocation. To use your own phrase, create a shortcut in the Shortcuts app that runs \"Start Conversation\" and name it \"\(name)\" — then say \"Hey Siri, \(name)\". Siri opens the app and it starts listening.")) {
        LabeledContent("Siri phrase", value: HandsFreeCapabilities.siriPhrase)
        LabeledContent("Custom Siri phrase", value: "Hey Siri, \(name) (after creating the shortcut)")
        Button("Open Shortcuts") {
          if let url = URL(string: "shortcuts://") { openURL(url) }
        }
      }

      Section("Background and locked phone") {
        LabeledContent("Start while the app is closed", value: "Via Siri; the iPhone must be unlocked")
        LabeledContent("Conversation already running", value: "Continues with the screen locked")
        LabeledContent("Always-listening custom wake word", value: "Not supported by iOS — not implemented")
      }

      Section("Recent invocations") {
        if coordinator.events.isEmpty {
          Text("None yet").foregroundStyle(.secondary)
        }
        ForEach(Array(coordinator.events.reversed())) { event in
          LabeledContent(
            "\(event.reason.rawValue) · \(event.at.formatted(date: .omitted, time: .standard))",
            value: event.outcome.rawValue)
        }
      }
    }
    .navigationTitle("Hands-Free")
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
        row("Realtime model", ModelSelector.realtimeModel)
        row("Realtime start", voice?.startMode?.rawValue ?? "not started")
        row("Voice", AssistantPreferences.voice)
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
      }
      Section("Camera pipeline") {
        row("Source", metrics.source)
        row("Input resolution", "\(metrics.inputResolution) \(metrics.pixelFormat)")
        row("Measured FPS", String(format: "%.1f", metrics.measuredFPS))
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

  private var models: [String] { ChatGPTAuthSession.shared.availableModels }
  private var catalog: [CatalogModel] { ChatGPTAuthSession.shared.modelCatalog }

  private func pick(_ kind: AssistantTaskKind, images: Bool = false, web: Bool = false) -> String {
    ModelSelector.model(
      for: kind, available: models, needsHostedWebSearch: web, catalog: catalog, needsImages: images,
      excluded: ModelHealth.shared.failedThisRun) ?? "—"
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
      "oauth: \(oauthStatus); models: \(models.count) [\(models.prefix(12).joined(separator: ","))]; realtime \(ModelSelector.realtimeModel) start: \(voice?.startMode?.rawValue ?? "—")",
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
