import MWDATCore
import SwiftUI

struct HomeScreenView: View {
  @ObservedObject var viewModel: WearablesViewModel
  let onRegistered: () -> Void
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.glasses.rawValue

  var body: some View {
    NavigationStack {
      ZStack {
        GlassifAIBackdrop()
        ScrollView {
          VStack(spacing: 32) {
            Spacer(minLength: 36)
            GlassifAIMark(size: 104)
            VStack(spacing: 10) {
              Text(L.t("Connect Meta glasses", "Meta gözlüğü bağlayın"))
                .font(.largeTitle.bold())
                .multilineTextAlignment(.center)
              Text(L.t("Give AutoLoom Media Glasses your first-person view.", "AutoLoom Media Glasses gözünüzden görsün."))
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            }

            VStack(alignment: .leading, spacing: 18) {
              capability(L.t("Ask hands-free visual questions", "Eller serbest görsel sorular sorun"), icon: "viewfinder")
              capability(L.t("Hear live answers you can interrupt", "Sözünü kesebileceğiniz canlı yanıtlar"), icon: "waveform")
              capability(L.t("Credentials stay on your iPhone", "Kimlik bilgileri iPhone'unuzda kalır"), icon: "lock.fill")
            }
            .padding(.vertical, 8)

            VStack(spacing: 12) {
              Button {
                viewModel.connectGlasses()
              } label: {
                HStack {
                  Image(systemName: "eyeglasses")
                  Text(viewModel.registrationState == .registering ? L.t("Connecting…", "Bağlanıyor…") : L.t("Connect glasses", "Gözlüğü bağla"))
                  if viewModel.registrationState == .registering {
                    Spacer()
                    ProgressView()
                  }
                }
                .frame(maxWidth: .infinity)
              }
              .buttonStyle(.borderedProminent)
              .buttonBorderShape(.roundedRectangle(radius: 14))
              .controlSize(.large)
              .disabled(viewModel.registrationState == .registering)

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

            Text(L.t("Meta AI opens briefly to approve the connection.", "Bağlantıyı onaylamak için Meta AI kısa süre açılır."))
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
          .frame(maxWidth: 420)
          .padding(.horizontal, 28)
          .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
      }
    }
    .onChange(of: viewModel.registrationState) { _, state in
      if state == .registered { onRegistered() }
    }
    .onAppear {
      if viewModel.registrationState == .registered { onRegistered() }
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
