import SwiftUI

/// First-run introduction in seven short pages. Permissions are not asked
/// here: each is requested later, only when a feature needs it.
struct OnboardingView: View {
  static let completedKey = "autoloom.onboarding.v1.completed"

  let onFinish: () -> Void
  @State private var page = 0
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  private struct Page {
    let symbol: String?
    let title: String
    let text: String
  }

  private var pages: [Page] {
    let name = AssistantIdentity.name
    return [
      Page(
        symbol: nil,
        title: AutoLoomBrand.appName,
        text: L.t("Your assistant for Ray-Ban Meta glasses and iPhone. \(AutoLoomBrand.tagline)",
                  "Ray-Ban Meta gözlük ve iPhone için asistanınız. Gör. Sor. Anla.")),
      Page(
        symbol: "waveform",
        title: L.t("Just talk", "Sadece konuşun"),
        text: L.t("Ask anything in Turkish or English. Interrupt any time — say “Dur” or “Stop”.",
                  "Türkçe ya da İngilizce her şeyi sorun. İstediğiniz an sözünü kesin — “Dur” demeniz yeter.")),
      Page(
        symbol: "eye",
        title: L.t("It sees what you see", "Gördüğünüzü görür"),
        text: L.t("Ask about what's in front of you. It reads signs, labels, screens and model numbers through your glasses or iPhone.",
                  "Önünüzdekini sorun. Gözlüğünüz veya iPhone'unuzla tabelaları, etiketleri, ekranları ve model numaralarını okur.")),
      Page(
        symbol: "brain",
        title: L.t("It remembers — when you ask", "İstediğinizde hatırlar"),
        text: L.t("Say “remember that…” or “bunu hatırla”. Memories stay on this iPhone, and you can edit or delete them any time.",
                  "“Şunu hatırla…” ya da “bunu hatırla” deyin. Anılar bu iPhone'da kalır; istediğiniz an düzenleyip silebilirsiniz.")),
      Page(
        symbol: "checklist",
        title: L.t("It gets things done", "İşlerinizi halleder"),
        text: L.t("Reminders, calendar, notes and directions — always with your OK. Calls and messages need a tap.",
                  "Anımsatıcı, takvim, not ve yol tarifi — her zaman onayınızla. Arama ve mesaj için dokunmanız gerekir.")),
      Page(
        symbol: "lock.shield",
        title: L.t("Private by design", "Gizlilik öncelikli"),
        text: L.t("A camera image leaves the phone only when a question needs it. Each permission is asked only when a feature needs it.",
                  "Kamera görüntüsü yalnızca bir soru gerektirdiğinde telefondan çıkar. Her izin yalnızca gerektiğinde istenir.")),
      Page(
        symbol: "sparkles",
        title: L.t("Meet \(name)", "\(name) ile tanışın"),
        text: L.t("Change the name, voice and wake phrase any time in Settings. Next, connect your ChatGPT account.",
                  "İsmi, sesi ve uyandırma ifadesini Ayarlar'dan istediğiniz an değiştirin. Şimdi ChatGPT hesabınızı bağlayın.")),
    ]
  }

  var body: some View {
    ZStack {
      GlassifAIBackdrop()
      VStack(spacing: 24) {
        HStack {
          Spacer()
          if page < pages.count - 1 {
            Button(L.t("Skip", "Geç")) { onFinish() }
              .foregroundStyle(.secondary)
          }
        }
        .frame(height: 32)
        .padding(.horizontal, 24)

        TabView(selection: $page) {
          ForEach(Array(pages.enumerated()), id: \.offset) { entry in
            pageView(entry.element, index: entry.offset)
              .tag(entry.offset)
          }
        }
        .tabViewStyle(.page(indexDisplayMode: .always))
        .indexViewStyle(.page(backgroundDisplayMode: .interactive))

        Button {
          if page < pages.count - 1 {
            if reduceMotion { page += 1 } else { withAnimation(.easeInOut) { page += 1 } }
          } else {
            onFinish()
          }
        } label: {
          Text(page < pages.count - 1 ? L.t("Continue", "Devam") : L.t("Get started", "Başlayalım"))
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.bottom, 24)
      }
    }
    .preferredColorScheme(.dark)
    .tint(AutoLoomTheme.electricBlue)
  }

  private func pageView(_ item: Page, index: Int) -> some View {
    VStack(spacing: 28) {
      Spacer(minLength: 20)
      if let symbol = item.symbol {
        ZStack {
          AssistantOrb(mood: index.isMultiple(of: 2) ? .listening : .thinking, size: 170)
          Image(systemName: symbol)
            .font(.system(size: 40, weight: .semibold))
            .foregroundStyle(.white)
        }
      } else {
        GlassifAIMark(size: 150)
          .padding(.vertical, 20)
      }
      VStack(spacing: 12) {
        Text(item.title)
          .font(.title.bold())
          .multilineTextAlignment(.center)
        Text(item.text)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(.horizontal, 32)
      Spacer(minLength: 40)
    }
    .accessibilityElement(children: .combine)
  }
}
