import AVFoundation
import Contacts
import CoreLocation
import EventKit
import Foundation
import Speech
import UserNotifications

/// Every iOS permission the app can use. Each is asked only when a feature
/// needs it (for example Contacts the first time you say "call Ahmet").
enum AppPermission: String, CaseIterable, Identifiable {
  case microphone
  case camera
  case speech
  case reminders
  case calendars
  case contacts
  case notifications
  case location

  var id: String { rawValue }

  var label: String {
    switch self {
    case .microphone: L.t("Microphone", "Mikrofon")
    case .camera: L.t("iPhone camera", "iPhone kamerası")
    case .speech: L.t("Speech recognition", "Konuşma tanıma")
    case .reminders: L.t("Reminders", "Anımsatıcılar")
    case .calendars: L.t("Calendars", "Takvimler")
    case .contacts: L.t("Contacts", "Kişiler")
    case .notifications: L.t("Notifications", "Bildirimler")
    case .location: L.t("Location", "Konum")
    }
  }

  var systemImage: String {
    switch self {
    case .microphone: "mic"
    case .camera: "camera"
    case .speech: "waveform.badge.mic"
    case .reminders: "checklist"
    case .calendars: "calendar"
    case .contacts: "person.crop.circle"
    case .notifications: "bell"
    case .location: "location"
    }
  }

  /// When the app asks for it.
  var purpose: String {
    switch self {
    case .microphone:
      L.t("Asked when you start your first conversation.", "İlk konuşmayı başlattığınızda sorulur.")
    case .camera:
      L.t("Asked when you choose the iPhone camera.", "iPhone kamerasını seçtiğinizde sorulur.")
    case .speech:
      L.t("Only for the wake phrase; recognition stays on this iPhone.",
          "Yalnızca uyandırma ifadesi için; tanıma bu iPhone'da kalır.")
    case .reminders:
      L.t("Asked the first time you create or list reminders.", "İlk kez anımsatıcı oluşturduğunuzda sorulur.")
    case .calendars:
      L.t("Asked the first time you ask about or add events.", "İlk kez takvim sorduğunuzda sorulur.")
    case .contacts:
      L.t("Asked the first time you call or look up someone by name.",
          "İlk kez birini adıyla aradığınızda sorulur.")
    case .notifications:
      L.t("Asked the first time you ask to be notified.", "İlk kez bildirim istediğinizde sorulur.")
    case .location:
      L.t("Only if you attach places to visual memories.", "Yalnızca görsel anılara konum eklerseniz.")
    }
  }
}

enum PermissionState: Equatable {
  case notAsked
  case granted
  case limited
  case denied

  var label: String {
    switch self {
    case .notAsked: L.t("Not asked yet", "Henüz sorulmadı")
    case .granted: L.t("Allowed", "İzin verildi")
    case .limited: L.t("Limited", "Sınırlı")
    case .denied: L.t("Not allowed", "İzin yok")
    }
  }
}

enum PermissionCenter {
  @MainActor
  static func state(_ permission: AppPermission) async -> PermissionState {
    switch permission {
    case .microphone:
      switch AVAudioApplication.shared.recordPermission {
      case .granted: return .granted
      case .denied: return .denied
      default: return .notAsked
      }
    case .camera:
      switch AVCaptureDevice.authorizationStatus(for: .video) {
      case .authorized: return .granted
      case .notDetermined: return .notAsked
      default: return .denied
      }
    case .speech:
      switch SFSpeechRecognizer.authorizationStatus() {
      case .authorized: return .granted
      case .notDetermined: return .notAsked
      default: return .denied
      }
    case .reminders:
      switch EKEventStore.authorizationStatus(for: .reminder) {
      case .fullAccess, .authorized: return .granted
      case .notDetermined: return .notAsked
      default: return .denied
      }
    case .calendars:
      switch EKEventStore.authorizationStatus(for: .event) {
      case .fullAccess, .authorized: return .granted
      case .writeOnly: return .limited
      case .notDetermined: return .notAsked
      default: return .denied
      }
    case .contacts:
      let status = CNContactStore.authorizationStatus(for: .contacts)
      if status == .authorized { return .granted }
      if status == .notDetermined { return .notAsked }
      if #available(iOS 18.0, *), status == .limited { return .limited }
      return .denied
    case .notifications:
      switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
      case .authorized, .provisional, .ephemeral: return .granted
      case .notDetermined: return .notAsked
      default: return .denied
      }
    case .location:
      switch CLLocationManager().authorizationStatus {
      case .authorizedWhenInUse, .authorizedAlways: return .granted
      case .notDetermined: return .notAsked
      default: return .denied
      }
    }
  }
}

/// One location fix for a visual memory or note, only when the user turned
/// "Attach location" on. Never tracked in the background.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
  static let shared = LocationProvider()

  private let manager = CLLocationManager()
  private var continuation: CheckedContinuation<CLLocation?, Never>?

  private override init() {
    super.init()
    manager.delegate = self
    manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
  }

  func requestPermission() {
    if manager.authorizationStatus == .notDetermined {
      manager.requestWhenInUseAuthorization()
    }
  }

  var isAuthorized: Bool {
    manager.authorizationStatus == .authorizedWhenInUse || manager.authorizationStatus == .authorizedAlways
  }

  func currentLocation(timeout: TimeInterval = 5) async -> MemoryLocation? {
    guard isAuthorized, continuation == nil else { return nil }
    let location: CLLocation? = await withCheckedContinuation { (continuation: CheckedContinuation<CLLocation?, Never>) in
      self.continuation = continuation
      manager.requestLocation()
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        self?.finish(nil)
      }
    }
    guard let location else { return nil }
    let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first
    let name = [placemark?.name, placemark?.locality].compactMap { $0 }.joined(separator: ", ")
    return MemoryLocation(
      latitude: location.coordinate.latitude,
      longitude: location.coordinate.longitude,
      placeName: name.isEmpty ? nil : name)
  }

  private func finish(_ location: CLLocation?) {
    continuation?.resume(returning: location)
    continuation = nil
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
    let last = locations.last
    Task { @MainActor [weak self] in self?.finish(last) }
  }

  nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
    Task { @MainActor [weak self] in self?.finish(nil) }
  }
}
