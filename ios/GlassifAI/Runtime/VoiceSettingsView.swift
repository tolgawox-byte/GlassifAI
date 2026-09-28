import SwiftUI

/// Settings → Voice. Shows the selected and the active voice side by side,
/// with the reason whenever ChatGPT used another one, and only offers voices
/// the realtime protocol accepts.
struct VoiceSettingsView: View {
  @ObservedObject var voice: GlassifAIRealtimeSession
  @AppStorage(AssistantPreferences.voiceKey) private var voiceName = AssistantPreferences.defaultVoice
  @AppStorage(VoiceCatalog.migratedFromKey) private var migratedFrom = ""
  @State private var applying = false

  var body: some View {
    Form {
      statusSection
      Section(
        header: Text(L.t("Voices", "Sesler")),
        footer: Text(L.t(
          "These are the voices ChatGPT's live voice accepts in this app. Tap a voice to choose it; tap the play button to hear it (only when no conversation is running).",
          "Bunlar ChatGPT canlı sesinin bu uygulamada kabul ettiği seslerdir. Seçmek için sese, dinlemek için oynat düğmesine dokunun (konuşma yokken)."))) {
        ForEach(VoiceCatalog.voices) { option in
          HStack(spacing: 12) {
            Button {
              voiceName = option.id
              migratedFrom = ""
            } label: {
              HStack {
                VStack(alignment: .leading, spacing: 2) {
                  Text(option.displayName + (option.id == VoiceCatalog.defaultVoice ? L.t(" (default)", " (varsayılan)") : ""))
                    .foregroundStyle(.primary)
                  Text(option.character)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                if option.id == voiceName {
                  Image(systemName: "checkmark").foregroundStyle(AutoLoomTheme.electricBlue)
                }
              }
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(option.id == voiceName ? .isSelected : [])
            previewButton(option)
          }
        }
      }
    }
    .navigationTitle(L.t("Voice", "Ses"))
  }

  @ViewBuilder
  private var statusSection: some View {
    let report = voice.startReport
    let isActive = voice.isActive
    Section(L.t("Now", "Şu an")) {
      LabeledContent(L.t("Selected voice", "Seçilen ses"), value: VoiceCatalog.displayName(voiceName))
      LabeledContent(
        L.t("Active voice", "Etkin ses"),
        value: isActive ? VoiceCatalog.displayName(report?.activeVoice) : L.t("No conversation", "Konuşma yok"))
      if let report, report.step != nil, !report.isPreview {
        LabeledContent(L.t("Last start", "Son başlatma"), value: report.step?.label ?? "—")
      }
      if let reason = report?.fallbackReason, report?.voiceMatches == false {
        Label(L.t("ChatGPT used another voice: ", "ChatGPT başka bir ses kullandı: ") + reason, systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      if !migratedFrom.isEmpty {
        Label(
          L.t("“\(migratedFrom.capitalized)” is not available for ChatGPT's live voice in this app, so Juniper was selected.",
              "“\(migratedFrom.capitalized)” bu uygulamada ChatGPT canlı sesinde kullanılamıyor; Juniper seçildi."),
          systemImage: "info.circle")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if isActive, let active = report?.activeVoice, active != voiceName {
        Button {
          applying = true
          Task {
            await voice.restartToApplySettings()
            applying = false
          }
        } label: {
          HStack {
            Label(L.t("Apply now (restarts the conversation)", "Şimdi uygula (konuşmayı yeniden başlatır)"), systemImage: "arrow.clockwise")
            if applying { Spacer(); ProgressView() }
          }
        }
        .disabled(applying)
      } else if !isActive {
        Text(L.t("The selected voice is used from the next conversation.", "Seçilen ses sonraki konuşmada kullanılır."))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  @ViewBuilder
  private func previewButton(_ option: RealtimeVoiceOption) -> some View {
    let previewing = voice.previewingVoice == option.id
    Button {
      Task {
        if previewing {
          await voice.stop()
        } else {
          await voice.previewVoice(option.id)
        }
      }
    } label: {
      Image(systemName: previewing ? "stop.circle.fill" : "play.circle")
        .font(.title2)
        .foregroundStyle(AutoLoomTheme.electricBlue)
    }
    .buttonStyle(.plain)
    .disabled(voice.isActive && !previewing)
    .accessibilityLabel(L.t("Preview ", "Dinle: ") + option.displayName)
  }
}
