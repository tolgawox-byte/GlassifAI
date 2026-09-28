import Combine
import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  private let wearablesViewModel: WearablesViewModel?
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var voice = GlassifAIRealtimeSession()
  @StateObject private var camera = GlassifAICamera()
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @State private var glassesAutoStarted = false
  @State private var glassesRegistered = false
  @State private var gestureSession: GlassesGestureSession?
  @State private var lastActivatedSource: CaptureSource?
  @Environment(\.scenePhase) private var scenePhase

  private var captureSource: CaptureSource {
    CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
  }

  private var glassesPlaceholder: (title: String, caption: String) {
    switch viewModel.glassesIssue {
    case .sdkUnavailable:
      (L.t("Glasses unavailable", "Gözlük kullanılamıyor"),
       L.t("Use the iPhone camera or try again on a supported device.", "iPhone kamerasını kullanın veya desteklenen bir cihazda tekrar deneyin."))
    case .permissionNeeded:
      (L.t("Permission needed", "İzin gerekli"),
       L.t("Allow camera access for AutoLoom Media Glasses in the Meta AI app.", "Meta AI uygulamasında AutoLoom Media Glasses için kamera izni verin."))
    case .hingesClosed:
      (L.t("Glasses folded", "Gözlük katlı"),
       L.t("Open the hinges to begin seeing through your glasses.", "Gözlükten görmek için menteşeleri açın."))
    case .reconnecting:
      (L.t("Reconnecting", "Yeniden bağlanıyor"),
       L.t("Your view will appear as soon as the glasses wake up.", "Gözlük uyanır uyanmaz görüntü gelecek."))
    case .thermal:
      (L.t("Glasses are warm", "Gözlük ısındı"),
       L.t("The camera may slow down or pause until the glasses cool down.", "Gözlük soğuyana kadar kamera yavaşlayabilir veya duraklayabilir."))
    case nil:
      (L.t("Waiting for glasses", "Gözlük bekleniyor"),
       L.t("Open your glasses and keep them near your iPhone.", "Gözlüğü açın ve iPhone'a yakın tutun."))
    }
  }

  private var needsGlassesSetup: Bool {
    guard captureSource == .glasses, let wearablesViewModel else { return false }
    return wearablesViewModel.registrationState != .registered
      && !glassesRegistered
      && !wearablesViewModel.hasMockDevice
  }

  init(wearables: WearablesInterface?, wearablesVM: WearablesViewModel?) {
    self.wearables = wearables
    self.wearablesViewModel = wearablesVM
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    AppShellView(
      captureSource: captureSource,
      glassesStream: viewModel,
      glassesPlaceholder: glassesPlaceholder,
      voice: voice,
      camera: camera,
      glassesDeviceName: glassesDeviceName,
      wearablesViewModel: wearablesViewModel,
      needsGlassesSetup: needsGlassesSetup,
      onGlassesRegistered: {
        glassesRegistered = true
        glassesAutoStarted = false
        Task { await activateCaptureSource() }
      })
    .task {
      let stream = viewModel
      AssistantOrchestrator.shared.glassesStillPhoto = { timeout in
        await stream.captureStillForVision(timeout: timeout)
      }
      AssistantOrchestrator.shared.glassesStreamState = { stream.lastStreamState }
      AssistantOrchestrator.shared.glassesTransport = { stream.activeTransport.shortLabel }
      let lifecycle = GlassesLifecycleMonitor.shared
      lifecycle.isStreamRunning = { stream.isStreaming }
      lifecycle.transportLabel = { stream.activeTransport.shortLabel }
      lifecycle.start()
      let voiceSession = voice
      LiveVisionController.shared.isVoiceActive = { voiceSession.isActive }
      WakePhraseListener.shared.isConversationActive = { voiceSession.isActive }
      WakePhraseListener.shared.glassesConnected = wearablesViewModel?.glassesLinkConnected
      WakePhraseListener.shared.glassesWorn = wearablesViewModel?.glassesWorn
      if let wearables {
        MetaVoiceInvocationListener.shared.listen(
          wearables: wearables, deviceId: wearablesViewModel?.devices.first ?? wearables.devices.first)
      }
      VoiceStartCoordinator.shared.register(isActive: { voiceSession.isActive }) { reason in
        // The conversation takes over the microphone.
        WakePhraseListener.shared.stopListening(reason: nil)
        let source = CaptureSource(rawValue: UserDefaults.standard.string(forKey: CaptureSource.defaultsKey) ?? "")
          ?? .iPhoneCamera
        let route = AudioRoutePreference.current
        // The chime and "Bağlandım, dinliyorum." come only when the
        // connection is really ready, never when the wake phrase is heard.
        await voiceSession.start(
          prefersBluetoothHFP: route.prefersGlassesAudio(for: source),
          forcesBuiltInAudio: route == .iPhone,
          reason: reason)
        // A hands-free start in the background: bring the glasses camera
        // back for visual questions (it pauses in the background when idle).
        if source == .glasses, !stream.isStreaming, voiceSession.isActive {
          glassesAutoStarted = false
          await activateCaptureSource()
        }
      }
      if gestureSession == nil, wearables != nil {
        gestureSession = GlassesGestureSession(states: viewModel.$deviceSessionState.eraseToAnyPublisher())
      }
      glassesRegistered =
        wearablesViewModel?.registrationState == .registered ||
        wearablesViewModel?.hasMockDevice == true
      AudioRouteMonitor.shared.start()
      VoiceCatalog.migrateStoredSelection()
      ConnectionFeedback.migrateStoredValue()
      await activateCaptureSource()
      await updateGestureSession()
      await WakePhraseListener.shared.refresh()
    }
    .onChange(of: captureSourceRaw) { _, _ in
      glassesAutoStarted = false
      Task { await switchCaptureSource() }
    }
    .onChange(of: voice.state) { _, _ in
      Task {
        await updateGestureSession()
        await WakePhraseListener.shared.refresh()
      }
    }
    .onChange(of: wearablesViewModel?.devices.first) { _, device in
      Task { await updateGestureSession() }
      if let wearables {
        MetaVoiceInvocationListener.shared.listen(wearables: wearables, deviceId: device ?? wearables.devices.first)
      }
    }
    .onChange(of: wearablesViewModel?.registrationState) { _, _ in
      if let wearables {
        MetaVoiceInvocationListener.shared.listen(
          wearables: wearables, deviceId: wearablesViewModel?.devices.first ?? wearables.devices.first)
      }
    }
    .onChange(of: viewModel.hasActiveDevice) { _, available in
      // DAT 1.0 ends the session when the glasses go away (folded, off, out
      // of range) and does not reconnect it; a new one starts when they are
      // back.
      guard available, captureSource == .glasses, !viewModel.isStreaming else { return }
      glassesAutoStarted = false
      Task { await activateCaptureSource() }
    }
    .onChange(of: wearablesViewModel?.glassesWorn) { _, worn in
      // DAT 1.0: glasses put on arm hands-free listening; taken off, it rests.
      WakePhraseListener.shared.glassesWorn = worn
    }
    .onChange(of: wearablesViewModel?.glassesLinkConnected) { previous, connected in
      // A real SDK event: the glasses' link to the phone came up or dropped.
      WakePhraseListener.shared.glassesConnected = connected
      if previous == true, connected == false, voice.isActive, captureSource == .glasses {
        voice.announceGlassesDisconnected()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      // The glasses stream is never stopped because the app left the
      // screen: with the HEVC transport it keeps delivering while the phone
      // is locked, and vision reads those frames, not the UI.
      guard phase == .active, captureSource == .glasses, !viewModel.isStreaming else { return }
      // A stream that stopped while away is started again.
      glassesAutoStarted = false
      Task { await activateCaptureSource() }
    }
    .onDisappear {
      VoiceStartCoordinator.shared.unregister()
      Task {
        await gestureSession?.stop()
        await voice.stop()
        await camera.stop()
        if viewModel.isStreaming { await viewModel.stopSession() }
      }
    }
    .alert(L.t("Camera unavailable", "Kamera kullanılamıyor"), isPresented: $viewModel.showError) {
      Button("OK") { viewModel.dismissError() }
    } message: {
      Text(viewModel.errorMessage)
    }
  }

  private var glassesDeviceName: String? {
    guard let wearables,
          let id = wearablesViewModel?.devices.first ?? wearables.devices.first,
          let device = wearables.deviceForIdentifier(id) else { return nil }
    return device.nameOrId()
  }

  /// Switching the camera no longer ends the conversation unless the audio
  /// route has to change (for example Ray-Ban audio → iPhone speaker).
  private func switchCaptureSource() async {
    let previous = lastActivatedSource ?? captureSource
    let route = AudioRoutePreference.current
    let audioChanges = route.prefersGlassesAudio(for: previous) != route.prefersGlassesAudio(for: captureSource)
    AssistantOrchestrator.shared.cancelAll(reason: "camera source changed", voiceOnly: false)
    viewModel.stillPhotos.cancel()
    FrameStore.shared.reset()
    if audioChanges && voice.isActive {
      await gestureSession?.stop()
      await voice.stop()
      await activateCaptureSource()
      await voice.start(
        prefersBluetoothHFP: route.prefersGlassesAudio(for: captureSource),
        forcesBuiltInAudio: route == .iPhone)
    } else {
      await activateCaptureSource()
    }
    await updateGestureSession()
  }

  private func updateGestureSession() async {
    guard captureSource == .glasses,
          voice.isActive,
          let gestureSession,
          let deviceId = wearablesViewModel?.devices.first ?? wearables?.devices.first else {
      await gestureSession?.stop()
      return
    }

    await gestureSession.start(
      deviceId: deviceId,
      onTap: {
        voice.toggleMicrophoneMuted()
        NSLog(
          "[GlassifAI] glasses temple tap: microphone %@",
          voice.isMicrophoneMuted ? "muted" : "live")
      },
      onStop: {
        Task { @MainActor in
          if voice.isActive {
            await voice.stop()
          }
        }
      })
  }

  private func activateCaptureSource() async {
    lastActivatedSource = captureSource
    switch captureSource {
    case .iPhoneCamera:
      glassesAutoStarted = false
      // The gestures follow the glasses session (DAT 1.0): the app's own stop
      // must not read as the wearer ending the call.
      await gestureSession?.stop()
      if viewModel.isStreaming { await viewModel.stopSession() }
      await camera.start()
    case .off:
      glassesAutoStarted = false
      await camera.stop()
      await gestureSession?.stop()
      if viewModel.isStreaming { await viewModel.stopSession() }
      FrameStore.shared.reset()
    case .glasses:
      await camera.stop()
      guard let wearablesViewModel,
            wearablesViewModel.registrationState == .registered ||
              glassesRegistered ||
              wearablesViewModel.hasMockDevice else { return }
      guard !glassesAutoStarted else { return }
      glassesAutoStarted = true
      for _ in 0..<20 {
        await viewModel.handleStartStreaming()
        if viewModel.isStreaming || captureSource != .glasses { break }
        try? await Task.sleep(nanoseconds: 3_000_000_000)
      }
      if !viewModel.isStreaming { glassesAutoStarted = false }
    }
  }
}
