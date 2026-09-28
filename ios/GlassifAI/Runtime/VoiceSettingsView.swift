import AVFoundation
import SwiftUI

/// Settings → Voice. Shows the selected and the active voice side by side,
/// with the reason whenever ChatGPT used another one, and only offers voices
/// the realtime protocol accepts. Also Jarvis Style, connection feedback,
/// language and conversation tone.
struct VoiceSettingsView: View {
  @ObservedObject var voice: GlassifAIRealtimeSession
  @AppStorage(AssistantPreferences.voiceKey) private var voiceName = AssistantPreferences.defaultVoice
  @AppStorage(VoiceCatalog.migratedFromKey) private var migratedFrom = ""
  @AppStorage(JarvisStyle.enabledKey) private var jarvisStyle = false
  @AppStorage(ConnectionFeedback.defaultsKey) private var feedbackRaw = ConnectionFeedback.chimeAndVoice.rawValue
  @AppStorage(GreetingStyle.defaultsKey) private var greetingRaw = GreetingStyle.normal.rawValue
  @AppStorage(GreetingStyle.customTextKey) private var customGreeting = ""
  @AppStorage(AssistantPreferences.languageKey) private var language = "auto"
  @AppStorage(AssistantPreferences.verbosityKey) private var verbosity = "concise"
  @State private var applying = false

  var body: some View {
    Form {
      statusSection
      jarvisSection
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
                  Text(option.displayName + suffix(for: option.id))
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
      Section(
        header: Text(L.t("Connection feedback", "Bağlantı bildirimi")),
        footer: Text(L.t(
          "Once per new conversation, only when ChatGPT, the voice connection and the audio route are really ready. Hands-free starts (wake phrase, Siri) also say the phrase; the on-screen button only chimes. A reconnect only chimes. A failed connection says “The connection could not be established.”",
          "Her yeni konuşmada bir kez, yalnızca ChatGPT, ses bağlantısı ve ses yolu gerçekten hazır olunca. Eller serbest başlatmalar (uyandırma ifadesi, Siri) ifadeyi de söyler; ekrandaki düğme yalnızca ses çıkarır. Yeniden bağlanınca yalnızca ses çıkar. Bağlantı kurulamazsa “Bağlantı kurulamadı.” denir."))) {
        Picker(L.t("When ready", "Hazır olunca"), selection: $feedbackRaw) {
          ForEach(ConnectionFeedback.allCases) { Text($0.label).tag($0.rawValue) }
        }
        Picker(L.t("Phrase", "İfade"), selection: $greetingRaw) {
          ForEach(GreetingStyle.allCases) { style in
            Text(style.label + (style.text(turkish: L.isTurkish, custom: "").map { " — \($0)" } ?? "")).tag(style.rawValue)
          }
        }
        .disabled(!(ConnectionFeedback(rawValue: feedbackRaw) ?? .chimeAndVoice).speaks)
        if greetingRaw == GreetingStyle.custom.rawValue {
          TextField(L.t("Custom phrase", "Özel ifade"), text: $customGreeting)
        }
        Button(L.t("Play the chime", "Sesi çal")) { ChimePlayer.shared.play(.ready) }
      }
      Section(L.t("Conversation", "Konuşma")) {
        Picker(L.t("Language", "Dil"), selection: $language) {
          Text(L.t("Match my language", "Benim dilimle konuş")).tag("auto")
          Text("Türkçe").tag("tr")
          Text("English").tag("en")
        }
        Picker(L.t("Conversation tone", "Konuşma tonu"), selection: $verbosity) {
          Text(L.t("Natural, short first", "Doğal, önce kısa")).tag("concise")
          Text(L.t("Detailed", "Detaylı")).tag("detailed")
        }
      }
      Section(
        header: Text(L.t("Offline announcements", "Çevrimdışı duyurular")),
        footer: Text(L.t(
          "Only when the live voice cannot speak (a failed or dropped connection), an Apple voice installed on this iPhone says a short sentence. Better voices can be downloaded in iOS Settings → Accessibility → Spoken Content → Voices.",
          "Yalnızca canlı ses konuşamadığında (kurulamayan veya kopan bağlantı) bu iPhone'daki bir Apple sesi kısa bir cümle söyler. Daha iyi sesler iOS Ayarlar → Erişilebilirlik → Seslendirilen İçerik → Sesler'den indirilebilir."))) {
        LabeledContent(L.t("Apple voice", "Apple sesi"), value: fallbackVoiceName)
        Button(L.t("Test", "Dene")) {
          LocalAnnouncer.shared.say(ConnectionFeedback.failureText(turkish: L.isTurkish), turkish: L.isTurkish)
        }
        .disabled(voice.isActive)
      }
    }
    .navigationTitle(L.t("Voice", "Ses"))
  }

  private func suffix(for id: String) -> String {
    if id == JarvisStyle.suggestedVoice && jarvisStyle { return L.t(" (Jarvis Style)", " (Jarvis tarzı)") }
    if id == VoiceCatalog.defaultVoice { return L.t(" (default)", " (varsayılan)") }
    return ""
  }

  private var fallbackVoiceName: String {
    guard let voice = LocalAnnouncer.voice(turkish: L.isTurkish, jarvis: jarvisStyle) else { return "—" }
    let quality: String
    switch voice.quality {
    case .premium: quality = "premium"
    case .enhanced: quality = "enhanced"
    default: quality = "default"
    }
    return "\(voice.name) (\(voice.language), \(quality))"
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
      LabeledContent(L.t("Style", "Tarz"), value: jarvisStyle ? L.t("Jarvis Style", "Jarvis tarzı") : L.t("Natural", "Doğal"))
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
        Text(L.t("The selected voice and style are used from the next conversation.", "Seçilen ses ve tarz sonraki konuşmada kullanılır."))
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var jarvisSection: some View {
    Section(
      header: Text("Jarvis Style"),
      footer: Text(L.t(
        "A composed, courteous, quietly witty assistant style: the closest of ChatGPT's voices (Cove, “composed and direct” in ChatGPT's own words) plus style instructions. It is a style, not a copy of any actor or film character; no film audio or voice clone is used. Pick another voice below if you prefer — none of these voices is guaranteed to have a British accent.",
        "Ölçülü, nazik, hafif esprili bir asistan tarzı: ChatGPT seslerinden en yakını (ChatGPT'nin kendi tanımıyla “ölçülü ve net” Cove) ve tarz talimatları. Bir tarzdır; herhangi bir oyuncunun veya film karakterinin kopyası değildir, film sesi ya da ses klonu kullanılmaz. İsterseniz aşağıdan başka bir ses seçin — bu seslerin hiçbirinde İngiliz aksanı garanti değildir."))) {
      Toggle(isOn: Binding(
        get: { jarvisStyle },
        set: { enabled in
          JarvisStyle.setEnabled(enabled)
          jarvisStyle = enabled
          voiceName = UserDefaults.standard.string(forKey: AssistantPreferences.voiceKey) ?? voiceName
          if enabled && greetingRaw == GreetingStyle.normal.rawValue { greetingRaw = GreetingStyle.jarvis.rawValue }
          if !enabled && greetingRaw == GreetingStyle.jarvis.rawValue { greetingRaw = GreetingStyle.normal.rawValue }
        })) {
        Label("Jarvis Style", systemImage: "sparkles")
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
