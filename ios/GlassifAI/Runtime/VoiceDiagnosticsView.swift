import AVFoundation
import SwiftUI

/// Settings → Developer → Voice diagnostics: the last start's connection
/// steps (WakeDetected → … → Ready / Failed), the audio route, the voice
/// ChatGPT really used, and the realtime latency.
struct VoiceDiagnosticsView: View {
  @ObservedObject var voice: GlassifAIRealtimeSession
  @ObservedObject private var coordinator = VoiceStartCoordinator.shared

  var body: some View {
    List {
      Section(L.t("Connection", "Bağlantı")) {
        row(L.t("Phase", "Aşama"), voice.connectionPhase.rawValue)
        row(L.t("Audio route when ready", "Hazır olunca ses yolu"), voice.readyRoute ?? "—")
        row(L.t("Connect time", "Bağlanma süresi"), voice.lastConnectMs.map { "\($0) ms" } ?? "—")
        row(L.t("Reconnects", "Yeniden bağlanma"), "\(voice.reconnectCount)" + (voice.lastReconnectReason.map { " · \($0)" } ?? ""))
        row(L.t("Response latency (median)", "Yanıt gecikmesi (medyan)"), voice.responseLatencyMedianMs.map { "\($0) ms" } ?? "—")
        row(L.t("Feedback", "Bildirim"), ConnectionFeedback.current.label)
        if let error = voice.lastRealtimeError {
          row(L.t("Last error", "Son hata"), error)
        }
      }
      Section(L.t("Last start, step by step", "Son başlatma, adım adım")) {
        if voice.connectionSteps.isEmpty {
          Text(L.t("No start yet", "Henüz başlatma yok")).foregroundStyle(.secondary)
        }
        ForEach(voice.connectionSteps) { step in
          HStack(alignment: .top) {
            Text(step.phase.rawValue).font(.footnote.weight(.semibold))
            Spacer()
            Text("\(step.atMs) ms" + (step.detail.map { " · \($0)" } ?? ""))
              .font(.caption)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.trailing)
          }
        }
      }
      Section(L.t("Voice", "Ses")) {
        let report = voice.startReport
        row(L.t("Requested", "İstenen"), report.map { "\($0.requestedVoice) · \($0.requestedModel)" } ?? "—")
        row(L.t("Active", "Etkin"), report.map { "\($0.activeVoice ?? "—") · \($0.activeModel ?? "—")" } ?? "—")
        row(L.t("Start step", "Başlatma adımı"), report?.step?.label ?? "—")
        row("Jarvis Style", JarvisStyle.isEnabled ? L.t("On", "Açık") : L.t("Off", "Kapalı"))
        ForEach(report?.attempts ?? [], id: \.self) { attempt in
          Text(attempt).font(.caption2).foregroundStyle(.orange)
        }
      }
      Section(L.t("Recent starts", "Son başlatmalar")) {
        if coordinator.events.isEmpty {
          Text(L.t("None yet", "Henüz yok")).foregroundStyle(.secondary)
        }
        ForEach(Array(coordinator.events.reversed())) { event in
          row("\(event.reason.rawValue) · \(event.at.formatted(date: .omitted, time: .standard))", event.outcome.rawValue)
        }
      }
    }
    .navigationTitle(L.t("Voice diagnostics", "Ses tanılaması"))
  }

  private func row(_ title: String, _ value: String) -> some View {
    HStack(alignment: .top) {
      Text(title).font(.footnote)
      Spacer(minLength: 12)
      Text(value)
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.trailing)
        .textSelection(.enabled)
    }
  }
}
