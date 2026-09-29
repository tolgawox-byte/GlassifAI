import Foundation
import SwiftUI

/// CI screenshots of the main screens: launched with
/// `-AutoLoomScreenshot <screen>`, the app skips onboarding and sign-in,
/// fills throwaway stores with demo data and opens that screen. Real data,
/// accounts and the glasses are never touched; a normal launch never has the
/// argument (`scripts/ci-screenshots.sh` passes it on the CI simulator only).
enum ScreenshotMode {
  static let screen: String? = {
    guard let value = UserDefaults.standard.string(forKey: "AutoLoomScreenshot"), !value.isEmpty else { return nil }
    return value
  }()

  static var isActive: Bool { screen != nil }

  /// File-backed stores use this folder instead of Application Support.
  static let sandbox: URL = FileManager.default.temporaryDirectory
    .appendingPathComponent("autoloom-screenshots", isDirectory: true)

  /// The folder a store should use: the sandbox while taking screenshots.
  static var storeDirectory: URL? { isActive ? sandbox : nil }

  /// The tab the shell opens with ("memory", "tasks"…); nil for other screens.
  static var initialTab: AppTab? {
    guard let screen else { return nil }
    return AppTab(rawValue: screen)
  }

  /// Screens shown on their own (not a tab of the shell).
  static let standaloneScreens: Set<String> = [
    "dealer", "vehicle", "shopping", "intelligence", "personality", "captures", "commands", "commandlab", "search",
    "privacy", "skills", "visualmemory", "translation", "remoteassist", "routines", "timeline", "performance",
  ]
}

/// Demo content for screenshots: plausible, clearly fictional, Turkish first.
@MainActor
enum ScreenshotDemo {
  private(set) static var vehicleID: UUID?

  static func seed() {
    guard ScreenshotMode.isActive else { return }
    try? FileManager.default.removeItem(at: ScreenshotMode.sandbox)
    try? FileManager.default.createDirectory(at: ScreenshotMode.sandbox, withIntermediateDirectories: true)
    // Nothing may start a camera, a microphone or a prompt.
    UserDefaults.standard.set(CaptureSource.off.rawValue, forKey: CaptureSource.defaultsKey)

    let memory = MemoryStore.shared
    let calendar = Calendar.current
    let tomorrowTen = calendar.date(
      bySettingHour: 10, minute: 0, second: 0, of: calendar.date(byAdding: .day, value: 1, to: Date()) ?? Date())
    memory.addNote(
      title: nil, content: "Corolla'nın sol arka lastiği değişecek; müşteri cuma teslim istiyor.", source: "demo")
    memory.addNote(
      title: nil, content: "Kanada piyasası: 2019 Civic LX için üç benzer ilan, 19.500–22.000 CAD (28 Eylül).",
      source: "demo")
    memory.addNote(title: nil, content: "Servis randevusu için yedek anahtarı ofise bırak.", source: "demo")
    memory.remember("Ev adresim Moda Caddesi 5, Kadıköy", source: "demo")
    memory.remember("Kahveyi şekersiz içerim", source: "demo")
    memory.addTask(title: "Civic'in teslim evraklarını hazırla", dueAt: Date().addingTimeInterval(3 * 3_600), source: "demo")
    memory.addTask(title: "Lastik siparişini onayla", dueAt: tomorrowTen, source: "demo")
    memory.addTask(title: "Corolla fotoğraflarını tamamla", source: "demo")

    let dealer = DealerStore.shared
    let vehicle = dealer.start()
    dealer.update(vehicle.id) { session in
      session.year = 2019
      session.make = "Honda"
      session.model = "Civic"
      session.trim = "LX"
      session.color = "Beyaz"
      session.stockNumber = "512"
      session.vin = "2HGFC2F59KH512345"
      session.odometer = OdometerReading(value: 45_320, unit: .km, at: Date(), source: "spoken")
      session.damage = [
        DamageFinding(zone: BodyZone.parse("sağ ön jant"), kind: .scratch, text: "Sağ ön jant çizik"),
        DamageFinding(zone: BodyZone.parse("arka tampon"), kind: .scratch, text: "Arka tamponda hafif çizik"),
      ]
      for label in [CaptureLabel.front, .front, .side, .rear, .wheel, .vin] { _ = session.tickPhoto(for: label) }
      session.status = .photos
    }
    vehicleID = vehicle.id
    let older = dealer.start()
    dealer.update(older.id) { session in
      session.year = 2021
      session.make = "Toyota"
      session.model = "Corolla"
      session.stockNumber = "498"
      session.odometer = OdometerReading(value: 31_870, unit: .km, at: Date(), source: "camera")
      session.status = .listing
    }
    dealer.activate(vehicle.id)

    ShoppingListStore.shared.add(["Süt", "Ekmek", "Yumurta", "Domates"])
    ParkingStore.shared.save(ParkingSpot(
      latitude: 40.9903, longitude: 29.0292, placeName: "Kadıköy Otoparkı", note: "B2 katı, 45 numara"))

    let timers = TimerCenter.shared
    timers.scheduleNotification = { _ in false }
    timers.removeNotifications = { _ in }
    Task { _ = await timers.start(seconds: 7 * 60, label: "Yumurta") }
  }
}

/// The root while taking screenshots: a tab of the shell or one screen.
struct ScreenshotRootView: View {
  var body: some View {
    Group {
      switch ScreenshotMode.screen ?? "" {
      case "dealer": NavigationStack { DealerHomeView() }
      case "vehicle":
        NavigationStack {
          if let id = ScreenshotDemo.vehicleID { VehicleDetailView(vehicleID: id) } else { DealerHomeView() }
        }
      case "shopping": NavigationStack { ShoppingListView() }
      case "intelligence": NavigationStack { IntelligenceSettingsView() }
      case "personality": NavigationStack { PersonalitySettingsView() }
      case "captures": NavigationStack { CapturesView() }
      case "commands": NavigationStack { CommandLibraryView() }
      case "commandlab": NavigationStack { CommandLabView() }
      default: StreamSessionView(wearables: nil)
      }
    }
    .preferredColorScheme(.dark)
  }
}
