import MWDATCore
import SwiftUI
import UIKit

struct StreamSessionView: View {
  let wearables: WearablesInterface?
  @ObservedObject private var connection: WearableConnectionCoordinator
  @StateObject private var viewModel: StreamSessionViewModel
  @StateObject private var voice = GlassifAIRealtimeSession()
  @StateObject private var camera = GlassifAICamera()
  @AppStorage(CaptureSource.defaultsKey) private var captureSourceRaw = CaptureSource.iPhoneCamera.rawValue
  @State private var gestureSession: GlassesGestureSession?
  @State private var lastActivatedSource: CaptureSource?
  @Environment(\.scenePhase) private var scenePhase

  private var captureSource: CaptureSource {
    CaptureSource(rawValue: captureSourceRaw) ?? .iPhoneCamera
  }

  init(wearables: WearablesInterface?, connection: WearableConnectionCoordinator = .shared) {
    self.wearables = wearables
    self._connection = ObservedObject(wrappedValue: connection)
    self._viewModel = StateObject(wrappedValue: StreamSessionViewModel(wearables: wearables))
  }

  var body: some View {
    AppShellView(
      captureSource: captureSource,
      glassesStream: viewModel,
      voice: voice,
      camera: camera,
      connection: connection)
    .task {
      let stream = viewModel
      // The glasses stream is part of the connection state; the coordinator
      // starts it whenever the glasses are registered and linked.
      connection.bind(stream: stream)
      AssistantOrchestrator.shared.glassesStillPhoto = { timeout in
        await stream.captureStillForVision(timeout: timeout)
      }
      AssistantOrchestrator.shared.glassesStreamState = { stream.lastStreamState }
      AssistantOrchestrator.shared.glassesTransport = { stream.activeTransport.shortLabel }
      // Ray-Ban photos and videos: straight from the glasses stream, never
      // the preview; recording does not depend on the conversation.
      let media = RayBanMediaCoordinator.shared
      media.isStreaming = { stream.streamingStatus == .streaming }
      media.takeStill = { timeout in await stream.captureUserPhoto(timeout: timeout) }
      stream.isRecordingVideo = { media.isRecording }
      let recorder = media.recorder
      stream.frameIngestor.setSampleTap { sample in recorder.append(sample) }
      stream.frameIngestor.setDecodedTap { buffer, time in recorder.appendDecoded(buffer, pts: time) }
      let lifecycle = GlassesLifecycleMonitor.shared
      lifecycle.isStreamRunning = { stream.isStreaming }
      lifecycle.transportLabel = { stream.activeTransport.shortLabel }
      lifecycle.start()
      let voiceSession = voice
      LiveVisionController.shared.isVoiceActive = { voiceSession.isActive }
      WakePhraseListener.shared.isConversationActive = { voiceSession.isActive }
      WakePhraseListener.shared.glassesConnected = connection.glassesLinkConnected
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
        // A hands-free start: bring the glasses camera back now for visual
        // questions if it is not running.
        if source == .glasses, !stream.isStreaming, voiceSession.isActive {
          WearableConnectionCoordinator.shared.requestStartSoon(reason: "conversation started")
        }
      }
      if gestureSession == nil, let wearables {
        gestureSession = GlassesGestureSession(wearables: wearables)
      }
      AudioRouteMonitor.shared.start()
      // Cloud agents are not tried offline.
      NetworkStatus.shared.start()
      VoiceCatalog.migrateStoredSelection()
      ConnectionFeedback.migrateStoredValue()
      await activateCaptureSource()
      await updateGestureSession()
      await WakePhraseListener.shared.refresh()
    }
    .onChange(of: captureSourceRaw) { _, _ in
      Task { await switchCaptureSource() }
    }
    .onChange(of: voice.state) { _, _ in
      Task {
        await updateGestureSession()
        await WakePhraseListener.shared.refresh()
      }
    }
    .onChange(of: connection.devices.first) { _, _ in
      Task { await updateGestureSession() }
    }
    .onChange(of: connection.glassesLinkConnected) { previous, connected in
      // A real SDK event: the glasses' link to the phone came up or dropped.
      WakePhraseListener.shared.glassesConnected = connected
      if previous == true, connected == false, voice.isActive, captureSource == .glasses {
        voice.announceGlassesDisconnected()
      }
    }
    .onChange(of: scenePhase) { _, phase in
      // The glasses stream is never stopped because the app left the
      // screen: with the HEVC transport it keeps delivering while the phone
      // is locked, and vision reads those frames, not the UI. The
      // coordinator only re-reads the SDK state and restarts what stopped.
      switch phase {
      case .active:
        connection.sceneBecameActive()
        // Photos saves that waited for the app (permission prompt) or failed.
        Task { await RayBanMediaCoordinator.shared.retryPendingSaves() }
      case .inactive, .background: connection.sceneResigned()
      @unknown default: break
      }
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
          let deviceId = connection.devices.first ?? wearables?.devices.first else {
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
      // Not wanted first, so the stop is not counted as a camera failure.
      connection.setCameraWanted(false)
      if viewModel.isStreaming { await viewModel.stopSession() }
      await camera.start()
    case .off:
      connection.setCameraWanted(false)
      await camera.stop()
      if viewModel.isStreaming { await viewModel.stopSession() }
      FrameStore.shared.reset()
    case .glasses:
      await camera.stop()
      // Started by the coordinator as soon as the glasses are registered
      // and linked, and again whenever they come back.
      connection.setCameraWanted(true)
    }
  }
}
