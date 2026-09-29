/*
 * Copyright (c) Meta Platforms, Inc. and affiliates.
 * All rights reserved.
 *
 * This source code is licensed under the license found in the
 * LICENSE file in the root directory of this source tree.
 */

//
// GlassifAIApp.swift
//
// GlassifAI opens with a camera-first voice experience. Meta glasses are an
// optional visual source selected in Settings, and their connection flow only
// appears when needed.
//

import Foundation
import MWDATCore
import SwiftUI


@main
struct GlassifAIApp: App {
  /// nil when the Wearables SDK could not start (no hardware, e.g. the
  /// simulator). Accessing `Wearables.shared` after a failed `configure()`
  /// traps, so nothing glasses-related may be built in that case. The camera
  /// experience does not depend on it.
  private let wearables: WearablesInterface?

  init() {
    var available: WearablesInterface?
    var failure: Error?
    do {
      try Wearables.configure()
      available = Wearables.shared
    } catch {
      failure = error
      NSLog("[GlassifAI] Wearables SDK unavailable: \(error)")
    }
    self.wearables = available
    if ScreenshotMode.isActive {
      MainActor.assumeIsolated { ScreenshotDemo.seed() }
    } else if !AppRuntime.isUnitTestHost {
      // Registration, devices and the link are observed from launch, before
      // any screen, so a Meta AI callback that launches the app is handled.
      let configured = available
      MainActor.assumeIsolated {
        WearableConnectionCoordinator.shared.attach(wearables: configured, configureError: failure)
      }
    }
  }

  var body: some Scene {
    WindowGroup {
      if AppRuntime.isUnitTestHost {
        // Unit tests only use the app as their host: keep the screen static
        // (no onboarding animation, no sign-in restore) so tests run on a
        // quiet simulator.
        Color.black
      } else if ScreenshotMode.isActive {
        ScreenshotRootView()
      } else {
        VisionRootView(wearables: wearables)
          .preferredColorScheme(.dark)
          // Meta AI's registration and permission callbacks, whatever screen
          // is showing (sign-in may still be restoring after a cold launch).
          .onOpenURL { url in
            WearableConnectionCoordinator.shared.handleOpenURL(url)
          }
      }
    }
  }
}

enum AppRuntime {
  static let isUnitTestHost = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
}

private enum GlassifAIPreviewMode {
  static var showsOnboarding: Bool {
    #if DEBUG
    ProcessInfo.processInfo.arguments.contains("--preview-onboarding")
    #else
    false
    #endif
  }
}

/// Authentication and all AI traffic are device-local; Meta remains only the
/// optional glasses hardware bridge.
struct VisionRootView: View {
  let wearables: WearablesInterface?
  @State private var auth = ChatGPTAuthSession.shared
  @AppStorage(OnboardingView.completedKey) private var onboardingCompleted = false

  var body: some View {
    Group {
      if !onboardingCompleted {
        OnboardingView { onboardingCompleted = true }
      } else if GlassifAIPreviewMode.showsOnboarding || !auth.isAuthenticated {
        AccessCodeView()
      } else if let wearables {
        GlassesCapableRootView(wearables: wearables)
      } else {
        StreamSessionView(wearables: nil)
      }
    }
    .task {
      if case .loading = auth.status { await auth.restore() }
    }
  }
}

struct AccessCodeView: View {
  var body: some View {
    ZStack {
      GlassifAIBackdrop()
      ScrollView {
        VStack(spacing: 36) {
          Spacer(minLength: 72)
          AuthenticationHeader()
          ChatGPTLoginView()
          Label(L.t("Credentials stay on this iPhone", "Kimlik bilgileri bu iPhone'da kalır"), systemImage: "lock.fill")
            .font(.footnote)
            .foregroundStyle(.secondary)
          Spacer(minLength: 40)
        }
        .frame(maxWidth: 420)
        .padding(.horizontal, 28)
        .frame(maxWidth: .infinity)
      }
      .scrollIndicators(.hidden)
    }
  }
}

private struct AuthenticationHeader: View {
  var body: some View {
    VStack(spacing: 18) {
      GlassifAIMark(size: 116)
      VStack(spacing: 8) {
        Text(AutoLoomBrand.appName)
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)
        Text(AutoLoomBrand.tagline)
          .font(.headline)
          .foregroundStyle(.secondary)
      }
      Text(L.t("Natural voice, vision, and live web answers for your iPhone and Meta glasses, using your ChatGPT account.", "ChatGPT hesabınızla iPhone ve Meta gözlüğünüz için doğal ses, görüntü ve canlı web yanıtları."))
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 320)
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(.isHeader)
  }
}

private struct ChatGPTLoginView: View {
  @Environment(\.openURL) private var openURL
  @State private var auth = ChatGPTAuthSession.shared
  @State private var showConsent = false
  private var displayStatus: ChatGPTAuthStatus {
    GlassifAIPreviewMode.showsOnboarding ? .unauthenticated : auth.status
  }

  var body: some View {
    VStack(spacing: 16) {
      switch displayStatus {
      case .loading, .connecting:
        ProgressView(L.t("Connecting securely…", "Güvenli bağlanılıyor…"))
          .frame(maxWidth: .infinity, minHeight: 72)
      case .pending(let login):
        VStack(spacing: 18) {
          Text(L.t("Finish connecting", "Bağlantıyı tamamlayın"))
            .font(.headline)
          Text(L.t("Enter this one-time code on OpenAI’s verification page.", "Bu tek kullanımlık kodu OpenAI doğrulama sayfasına girin."))
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Text(verbatim: login.userCode)
            .font(.system(.title2, design: .monospaced).bold())
            .tracking(3)
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
          HStack {
            Button {
              UIPasteboard.general.string = login.userCode
            } label: {
              Label(L.t("Copy", "Kopyala"), systemImage: "doc.on.doc")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            Button {
              openURL(login.verificationUrl)
            } label: {
              Label(L.t("Open OpenAI", "OpenAI'yi aç"), systemImage: "arrow.up.right")
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
          }
          .controlSize(.large)
        }
      case .authenticated(let user):
        Label(user.email ?? user.name ?? "ChatGPT connected", systemImage: "checkmark.circle.fill")
          .font(.headline)
          .foregroundStyle(.green)
          .frame(maxWidth: .infinity, minHeight: 64)
      case .error(let message):
        VStack(spacing: 14) {
          Label(L.t("Couldn’t connect", "Bağlanılamadı"), systemImage: "exclamationmark.triangle.fill")
            .font(.headline)
            .foregroundStyle(.red)
          Text(message)
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
          Button(L.t("Try Again", "Tekrar dene")) { showConsent = true }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
      case .unauthenticated:
        Button { showConsent = true } label: {
          HStack {
            Image(systemName: "bubble.left.and.text.bubble.right")
            Text(L.t("Continue with ChatGPT", "ChatGPT ile devam et"))
            Spacer()
            Image(systemName: "chevron.right")
              .font(.caption.bold())
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: 14))
        .controlSize(.large)
      }
    }
    .padding(20)
    .glassifAIPanel()
    .sheet(isPresented: $showConsent) {
      ChatGPTConsentView {
        showConsent = false
        Task {
          if let login = try? await auth.startLogin() {
            openURL(login.verificationUrl)
          }
        }
      }
    }
  }
}

struct ChatGPTConsentView: View {
  let onContinue: () -> Void
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      VStack(alignment: .leading, spacing: 24) {
        GlassifAIMark(size: 76)
          .frame(maxWidth: .infinity)
        VStack(alignment: .leading, spacing: 8) {
          Text(L.t("Connect ChatGPT", "ChatGPT'yi bağlayın"))
            .font(.title2.bold())
          Text("AutoLoom Media Glasses uses your ChatGPT account for live voice, vision, and web search requests. It is an independent app, not an official OpenAI or Meta product.")
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        VStack(alignment: .leading, spacing: 18) {
          consentRow(L.t("Credentials are protected by this iPhone’s Keychain", "Kimlik bilgileri bu iPhone'un Anahtar Zinciri ile korunur"), icon: "key.fill")
          consentRow(L.t("A camera frame is sent only when a question needs to see", "Kamera karesi yalnızca bir soru görmeyi gerektirdiğinde gönderilir"), icon: "camera.fill")
          consentRow(L.t("Disconnecting removes the local session", "Bağlantıyı kesmek yerel oturumu siler"), icon: "trash")
        }
        Spacer(minLength: 12)
        Button(L.t("Continue", "Devam"), action: onContinue)
          .buttonStyle(.borderedProminent)
          .buttonBorderShape(.roundedRectangle(radius: 14))
          .controlSize(.large)
          .frame(maxWidth: .infinity)
        Button(L.t("Cancel", "Vazgeç"), role: .cancel) { dismiss() }
          .frame(maxWidth: .infinity, minHeight: 44)
      }
      .padding(24)
      .navigationBarTitleDisplayMode(.inline)
    }
    .presentationDetents([.medium, .large])
  }

  private func consentRow(_ text: String, icon: String) -> some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: icon)
        .foregroundStyle(.tint)
        .frame(width: 24)
      Text(text)
        .font(.subheadline)
    }
  }
}


/// The full app when the glasses SDK is available. The connection itself is
/// owned by `WearableConnectionCoordinator` (attached at launch); Meta AI's
/// callbacks are handled by the app's root `onOpenURL`.
private struct GlassesCapableRootView: View {
  let wearables: WearablesInterface
  @ObservedObject private var connection = WearableConnectionCoordinator.shared

  var body: some View {
    StreamSessionView(wearables: wearables, connection: connection)
      .alert(
        L.t("Ray-Ban", "Ray-Ban"),
        isPresented: Binding(
          get: { connection.userAlert != nil },
          set: { if !$0 { connection.userAlert = nil } })
      ) {
        Button("OK") { connection.userAlert = nil }
      } message: {
        Text(connection.userAlert ?? "")
      }
  }
}
