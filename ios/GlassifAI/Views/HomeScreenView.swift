import MWDATCore
import SwiftUI

/// The Ray-Ban connect screen, shown only while Meta AI registration is
/// needed. One primary action at a time: Connect, waiting for Meta AI, or
/// Try Again when Meta AI did not answer.
struct HomeScreenView: View {
  @ObservedObject var connection: WearableConnectionCoordinator
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.glasses.rawValue
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var taps = 0

  private var phase: GlassesConnectionPhase { connection.phase }
  private var isWaiting: Bool { phase == .registrationStarting || phase == .waitingForMetaAI }

  var body: some View {
    NavigationStack {
      ZStack {
        GlassifAIBackdrop()
        ScrollView {
          VStack(spacing: 28) {
            Spacer(minLength: 24)
            GlassesLinkAnimation(visual: GlassesLinkVisual.from(phase), size: 190)
            VStack(spacing: 10) {
              Text(title)
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
              Text(subtitle)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            }

            if connection.registrationLost && phase == .notRegistered {
              Label {
                Text(L.t(
                  "AutoLoom is no longer connected in Meta AI — for example because another glasses app was connected in Developer Mode, which allows one app at a time. Connect again below.",
                  "AutoLoom artık Meta AI'da bağlı değil — örneğin Developer Mode'da başka bir gözlük uygulaması bağlandığı için (aynı anda yalnızca bir uygulama). Aşağıdan yeniden bağla."))
                  .font(.footnote)
              } icon: {
                Image(systemName: "info.circle")
              }
              .padding(14)
              .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
              .transition(.opacity)
            }

            if phase == .notRegistered {
              VStack(alignment: .leading, spacing: 18) {
                capability(L.t("Ask hands-free visual questions", "Eller serbest görsel sorular sorun"), icon: "viewfinder")
                capability(L.t("Hear live answers you can interrupt", "Sözünü kesebileceğiniz canlı yanıtlar"), icon: "waveform")
                capability(L.t("Credentials stay on your iPhone", "Kimlik bilgileri iPhone'unuzda kalır"), icon: "lock.fill")
              }
              .padding(.vertical, 4)
              .transition(.opacity)
            }

            VStack(spacing: 12) {
              primaryButton
              Button {
                captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
              } label: {
                Label(L.t("Use iPhone camera", "iPhone kamerasını kullan"), systemImage: "iphone")
                  .frame(maxWidth: .infinity)
              }
              .buttonStyle(.bordered)
              .buttonBorderShape(.roundedRectangle(radius: 14))
              .controlSize(.large)
            }

            Text(L.t("Meta AI opens briefly to approve the connection. Your registration stays until you remove it in Settings.",
                     "Bağlantıyı onaylamak için Meta AI kısa süre açılır. Kayıt, Ayarlar'dan kaldırana kadar kalır."))
              .font(.footnote)
              .foregroundStyle(.secondary)
              .multilineTextAlignment(.center)

            ConnectChecklist()
          }
          .frame(maxWidth: 420)
          .padding(.horizontal, 28)
          .frame(maxWidth: .infinity)
          .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: phase)
        }
        .scrollIndicators(.hidden)
      }
    }
    .sensoryFeedback(.impact(weight: .light), trigger: taps)
  }

  private var title: String {
    switch phase {
    case .registrationStarting: L.t("Opening Meta AI…", "Meta AI açılıyor…")
    case .waitingForMetaAI: L.t("Approve in Meta AI", "Meta AI'da onayla")
    case .registrationStalled: L.t("Meta AI didn't confirm", "Meta AI onay göndermedi")
    default: L.t("Connect your Ray-Ban", "Ray-Ban'ını bağla")
    }
  }

  private var subtitle: String {
    switch phase {
    case .registrationStarting, .waitingForMetaAI:
      L.t("Allow AutoLoom in Meta AI, then come back here.", "Meta AI'da AutoLoom'a izin ver, sonra buraya geri dön.")
    case .registrationStalled:
      connection.status.detail ?? L.t("The approval did not come back to AutoLoom.", "Onay AutoLoom'a geri gelmedi.")
    default:
      L.t("Give AutoLoom Media Glasses your first-person view.", "AutoLoom Media Glasses gözünüzden görsün.")
    }
  }

  @ViewBuilder
  private var primaryButton: some View {
    Button {
      taps += 1
      if phase == .registrationStalled {
        connection.retry()
      } else {
        connection.connect()
      }
    } label: {
      HStack(spacing: 10) {
        if isWaiting {
          ProgressView().tint(.white)
        } else {
          Image(systemName: phase == .registrationStalled ? "arrow.clockwise" : "eyeglasses")
            .contentTransition(.symbolEffect(.replace))
        }
        Text(buttonTitle)
          .contentTransition(.opacity)
      }
      .frame(maxWidth: .infinity)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.roundedRectangle(radius: 14))
    .controlSize(.large)
    // Registration already in progress: no second flow.
    .disabled(isWaiting || phase == .sdkUnavailable)
  }

  private var buttonTitle: String {
    switch phase {
    case .registrationStarting, .waitingForMetaAI: L.t("Waiting for Meta AI…", "Meta AI bekleniyor…")
    case .registrationStalled: L.t("Try Again", "Tekrar dene")
    default: L.t("Connect glasses", "Gözlüğü bağla")
    }
  }

  private func capability(_ title: String, icon: String) -> some View {
    HStack(spacing: 14) {
      Image(systemName: icon)
        .foregroundStyle(.tint)
        .frame(width: 24)
      Text(title)
        .font(.body)
      Spacer(minLength: 0)
    }
  }
}

/// What Meta requires before a developer app can connect, in the order it
/// is checked (Meta's DAT setup and version pages, and the recovery Meta's
/// engineers give in the SDK's issue tracker).
struct ConnectChecklist: View {
  @State private var expanded = false

  private let steps: [(String, String)] = [
    (L.t("Meta AI app 290 or newer and glasses software 128 or newer (Meta AI → Devices → your glasses → Settings → General → About).",
         "Meta AI 290 veya üstü ve gözlük yazılımı 128 veya üstü (Meta AI → Cihazlar → gözlüğün → Ayarlar → Genel → Hakkında)."),
     "arrow.down.circle"),
    (L.t("Developer Mode on: Meta AI → Settings → App info → tap the version 5 times. If Meta AI offers to install DAT on the glasses, wear them and keep Meta AI open.",
         "Geliştirici Modu açık: Meta AI → Ayarlar → Uygulama bilgisi → sürüme 5 kez dokun. Meta AI gözlüğe DAT kurmayı önerirse gözlüğü tak ve Meta AI'ı açık tut."),
     "hammer"),
    (L.t("Developer Mode keeps one app at a time: after trying another glasses app, connect AutoLoom again.",
         "Geliştirici Modu aynı anda tek uygulamaya izin verir: başka bir gözlük uygulaması denediysen AutoLoom'u yeniden bağla."),
     "1.circle"),
    (L.t("iPhone Bluetooth on, and allowed for AutoLoom (Settings → AutoLoom → Bluetooth).",
         "iPhone'da Bluetooth açık ve AutoLoom'a izinli (Ayarlar → AutoLoom → Bluetooth)."),
     "dot.radiowaves.left.and.right"),
    (L.t("Still refused? Switch the glasses off and on with the power switch (the case is not enough), then try again.",
         "Hâlâ reddediyor mu? Gözlüğü güç düğmesiyle kapatıp aç (kutuya koymak yetmez), sonra tekrar dene."),
     "power"),
  ]

  var body: some View {
    DisclosureGroup(isExpanded: $expanded) {
      VStack(alignment: .leading, spacing: 12) {
        ForEach(steps.indices, id: \.self) { index in
          Label {
            Text(steps[index].0).font(.footnote)
          } icon: {
            Image(systemName: steps[index].1).foregroundStyle(.tint)
          }
        }
      }
      .padding(.top, 8)
    } label: {
      Text(L.t("Before connecting", "Bağlanmadan önce"))
        .font(.subheadline.weight(.semibold))
    }
    .padding(14)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
  }
}
