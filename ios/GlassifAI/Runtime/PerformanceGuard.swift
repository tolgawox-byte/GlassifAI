import Foundation
import SwiftUI
import UIKit

/// Keeps the heavy features inside the phone's thermal limits and says so
/// when it acts. At critical temperature Live Vision and Remote Assist stop;
/// a Ray-Ban recording is never stopped here, so its file stays intact.
/// Live Vision already slows itself with heat and low battery
/// (`LiveVisionPolicy`), and Remote Assist halves its frame rate when hot.
@MainActor
final class PerformanceGuard: ObservableObject {
  static let shared = PerformanceGuard()

  @Published private(set) var thermal = ProcessInfo.processInfo.thermalState
  @Published private(set) var lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
  @Published private(set) var lastAction: String?
  private var observers: [NSObjectProtocol] = []

  struct Actions: Equatable {
    var stopLiveVision = false
    var stopSharing = false
    var message: String?
  }

  /// What to stop at this temperature; a recording is never on the list.
  nonisolated static func actions(thermal: ProcessInfo.ThermalState, liveVision: Bool, sharing: Bool) -> Actions {
    guard thermal == .critical, liveVision || sharing else { return Actions() }
    return Actions(
      stopLiveVision: liveVision, stopSharing: sharing,
      message: L.t(
        "The phone is very hot: Live Vision and sharing stopped. A recording keeps going.",
        "Telefon çok ısındı: canlı görüş ve paylaşım durdu. Kayıt devam ediyor."))
  }

  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { _ in
      Task { @MainActor in PerformanceGuard.shared.update() }
    })
    observers.append(center.addObserver(forName: Notification.Name.NSProcessInfoPowerStateDidChange, object: nil, queue: .main) { _ in
      Task { @MainActor in PerformanceGuard.shared.update() }
    })
    update()
  }

  func update() {
    thermal = ProcessInfo.processInfo.thermalState
    lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
    let live = LiveVisionController.shared
    let sharing = RemoteAssistServer.shared
    let actions = Self.actions(thermal: thermal, liveVision: live.isActive, sharing: sharing.isSharing)
    if actions.stopLiveVision { _ = live.stop(reason: "the phone is too hot") }
    if actions.stopSharing { sharing.stop(.thermal) }
    if let message = actions.message {
      lastAction = message
      AssistantOrchestrator.shared.postNotice(message)
    }
  }

  var thermalTitle: String {
    switch thermal {
    case .nominal: L.t("Normal", "Normal")
    case .fair: L.t("Warm", "Ilık")
    case .serious: L.t("Hot — features slow down", "Sıcak — özellikler yavaşlar")
    case .critical: L.t("Very hot — Live Vision and sharing stop", "Çok sıcak — canlı görüş ve paylaşım durur")
    @unknown default: L.t("Unknown", "Bilinmiyor")
    }
  }
}

/// Settings → Performance: temperature, battery and what is running.
struct PerformanceView: View {
  @ObservedObject private var guardian = PerformanceGuard.shared
  @ObservedObject private var liveVision = LiveVisionController.shared
  @ObservedObject private var sharing = RemoteAssistServer.shared
  @ObservedObject private var media = RayBanMediaCoordinator.shared

  var body: some View {
    List {
      Section {
        LabeledContent(L.t("Temperature", "Sıcaklık"), value: guardian.thermalTitle)
        LabeledContent(L.t("Low Power Mode", "Düşük Güç Modu"), value: guardian.lowPower ? L.t("On", "Açık") : L.t("Off", "Kapalı"))
        if UIDevice.current.isBatteryMonitoringEnabled, UIDevice.current.batteryLevel >= 0 {
          LabeledContent(L.t("Battery", "Pil"), value: "\(Int(UIDevice.current.batteryLevel * 100))%")
        }
        if let action = guardian.lastAction { Text(action).font(.caption).foregroundStyle(.orange) }
      } header: {
        Text(L.t("This iPhone", "Bu iPhone"))
      }
      Section {
        LabeledContent(L.t("Live Vision", "Canlı görüş"), value: liveVision.isActive
          ? L.t("\(liveVision.updateCount) notes, \(liveVision.skippedStable) skipped", "\(liveVision.updateCount) not, \(liveVision.skippedStable) atlandı")
          : L.t("Off", "Kapalı"))
        LabeledContent(L.t("Remote Assist", "Uzaktan yardım"), value: sharing.isSharing ? L.t("Sharing", "Paylaşılıyor") : L.t("Off", "Kapalı"))
        LabeledContent(L.t("Recording", "Kayıt"), value: media.isRecording ? L.t("Recording", "Kaydediyor") : L.t("Off", "Kapalı"))
        Text(MediaResourceCoordinator.shared.summary).font(.caption).foregroundStyle(.secondary)
      } header: {
        Text(L.t("Running", "Çalışan"))
      } footer: {
        Text(L.t(
          "Live Vision sends a frame only when the scene changes (at most one every few seconds, slower when hot or on low battery). Sharing sends about two frames a second, one when hot. Nothing sends 30 frames a second to a model.",
          "Canlı görüş yalnızca sahne değişince kare gönderir (en fazla birkaç saniyede bir; sıcakta ve düşük pilde daha seyrek). Paylaşım saniyede yaklaşık iki kare, sıcakta bir kare gönderir. Hiçbir şey bir modele saniyede 30 kare göndermez."))
      }
    }
    .navigationTitle(L.t("Performance", "Performans"))
  }
}
