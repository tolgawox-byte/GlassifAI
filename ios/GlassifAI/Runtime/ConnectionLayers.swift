import CoreBluetooth
import Foundation
import SwiftUI

// MARK: - Session failures (DAT 1.0), in the app's own terms

/// A DAT 1.0 `DeviceSessionError`, independent of the SDK type so the rules
/// can be tested without glasses. Meta: "Do not collapse these errors into a
/// single 'incompatible versions' state."
enum GlassesSessionFailure: Equatable {
  case noEligibleDevice
  /// `insufficientSDKVersion`: only a newer AutoLoom build helps.
  case sdkTooOld
  /// `datAppOnTheGlassesUpdateRequired`: update it in Meta AI → App connections.
  case glassesAppUpdateRequired
  /// `dwaUnavailable`: the DAT app on the glasses did not come up.
  case glassesAppUnavailable
  /// `dwaOutOfStuRange`: works, outside the recommended version range.
  case versionWarning
  /// Thermal, battery or peak-power limits.
  case deviceHealth(String)
  /// The app asked in the wrong state (already exists, already stopped…).
  case appState(String)
  case unexpected(String)

  /// "Device unavailable" or "Session ended by device". Meta's issue tracker
  /// (facebook/meta-wearables-dat-ios #292) shows the glasses refusing every
  /// new session this way after a firmware update or after the Bluetooth
  /// hands-free microphone was released and set up again; only switching the
  /// glasses off and on with the power switch cleared it.
  var isRefusal: Bool {
    guard case .unexpected(let text) = self else { return false }
    let lower = text.lowercased()
    return lower.contains("device unavailable") || lower.contains("ended by device")
  }

  var summary: String {
    switch self {
    case .noEligibleDevice: "no eligible device"
    case .sdkTooOld: "insufficient SDK version (needs a newer app build)"
    case .glassesAppUpdateRequired: "the DAT app on the glasses needs an update"
    case .glassesAppUnavailable: "the DAT app on the glasses is unavailable"
    case .versionWarning: "versions outside the recommended range (not blocking)"
    case .deviceHealth(let what): "device health: \(what)"
    case .appState(let text): "session state: \(text)"
    case .unexpected(let text): "unexpected: \(text)"
    }
  }
}

/// What the user must know or do about the glasses session.
enum GlassesSessionProblem: Equatable {
  case sdkTooOld
  case glassesAppUpdateRequired
  case glassesAppUnavailable
  /// The glasses refused this many sessions in a short time.
  case refusing(count: Int)
  /// The glasses ended or refused the session while their microphone was
  /// connected over Bluetooth hands-free: current glasses software treats
  /// that as a call and stops the camera until it ends (Meta, SDK issues
  /// #206 and #332, 2026-10-13).
  case callActive
  case deviceHealth(String)
  case versionWarning

  /// A session that starts proves the glasses accept the app; only the
  /// non-blocking version warning stays.
  var clearsWhenASessionStarts: Bool { self != .versionWarning }

  /// Retrying alone cannot help: a newer build, an update in Meta AI or a
  /// power cycle of the glasses comes first.
  var blocksAutomaticRetry: Bool {
    switch self {
    case .sdkTooOld, .glassesAppUpdateRequired, .refusing, .callActive: true
    case .glassesAppUnavailable, .deviceHealth, .versionWarning: false
    }
  }
}

enum GlassesSessionProblemPolicy {
  /// Refusals counted within this window…
  static let refusalWindow: TimeInterval = 180
  /// …this many of them mean the glasses need a power cycle.
  static let refusalLimit = 3

  /// `handsFreeActive`: the glasses' microphone was the audio input when it
  /// happened. Then even one refusal is the call rule, not bad luck.
  static func problem(
    after failure: GlassesSessionFailure, refusalsInWindow: Int, handsFreeActive: Bool = false
  ) -> GlassesSessionProblem? {
    if failure.isRefusal, handsFreeActive { return .callActive }
    switch failure {
    case .sdkTooOld: return .sdkTooOld
    case .glassesAppUpdateRequired: return .glassesAppUpdateRequired
    case .glassesAppUnavailable: return .glassesAppUnavailable
    case .versionWarning: return .versionWarning
    case .deviceHealth(let what): return .deviceHealth(what)
    case .noEligibleDevice, .appState: return nil
    case .unexpected:
      guard failure.isRefusal, refusalsInWindow >= refusalLimit else { return nil }
      return .refusing(count: refusalsInWindow)
    }
  }
}

// MARK: - The glasses microphone and the Ray-Ban camera

/// Meta, 2026-10-13 (SDK issues #206 and #332): on current glasses software
/// the glasses end a DAT camera session as soon as their microphone connects
/// over Bluetooth hands-free (HFP), in every order, including the documented
/// one, and decline new sessions while that "call" lasts. "Nothing on the app
/// or SDK side keeps HFP and a camera session running together on this
/// firmware"; a glasses-side fix is coming, with no date. HFP also takes
/// 40–70 % of the camera's Bluetooth frames (#260).
///
/// So while the Ray-Ban camera is the chosen source, conversations and the
/// wake phrase keep the glasses' HFP route closed and use the iPhone's
/// microphone and speaker. On by default; turn it off once Meta's fix has
/// reached the glasses.
enum GlassesCameraAudio {
  static let defaultsKey = "autoloom.glasses.cameraSafeAudio"

  static var keepsHandsFreeClosed: Bool {
    UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
  }

  /// The camera source chosen now (what the wake phrase listener checks).
  static var currentSource: CaptureSource {
    CaptureSource(rawValue: UserDefaults.standard.string(forKey: CaptureSource.defaultsKey) ?? "") ?? .iPhoneCamera
  }

  /// Bluetooth hands-free must stay out of the audio session.
  static func blocksHandsFree(source: CaptureSource, cameraSafe: Bool = GlassesCameraAudio.keepsHandsFreeClosed) -> Bool {
    source == .glasses && cameraSafe
  }
}

/// The audio of one conversation: the glasses' hands-free microphone and
/// speakers, or the iPhone's (Bluetooth hands-free then stays closed).
struct ConversationAudio: Equatable {
  let prefersGlassesHandsFree: Bool
  let forcesBuiltIn: Bool
}

extension AudioRoutePreference {
  /// What a conversation uses with this camera source. The Ray-Ban camera
  /// with camera-safe audio (the default) always gets the iPhone's
  /// microphone and speaker; otherwise the preference decides as before.
  func conversationAudio(
    for captureSource: CaptureSource, cameraSafe: Bool = GlassesCameraAudio.keepsHandsFreeClosed
  ) -> ConversationAudio {
    if GlassesCameraAudio.blocksHandsFree(source: captureSource, cameraSafe: cameraSafe) {
      return ConversationAudio(prefersGlassesHandsFree: false, forcesBuiltIn: true)
    }
    return ConversationAudio(prefersGlassesHandsFree: prefersGlassesAudio(for: captureSource), forcesBuiltIn: self == .iPhone)
  }
}

/// Meta's documented ordering for HFP with a DAT camera stream: add the
/// camera, set up the HFP microphone and let the route settle, then start the
/// stream ("starting the DAT stream before HFP is ready can cause the audio
/// route to fail silently"). Only used when camera-safe audio is off (on
/// current glasses software every order ends the session, see above). On by
/// default; Settings → Developer → Ray-Ban connection can turn it off.
enum GlassesAudioOrder {
  static let defaultsKey = "autoloom.glasses.microphoneFirst"

  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
  }
}

// MARK: - Bluetooth permission and power

/// The app's Bluetooth permission and, once allowed, whether Bluetooth is on.
/// DAT links the glasses over Bluetooth: without the permission, or with
/// Bluetooth off, the glasses look asleep unless this is said.
enum BluetoothAccess: String, Equatable {
  case unknown
  case ready
  case poweredOff
  case denied
  case notDetermined
  case unsupported

  /// The glasses cannot link at all in this state.
  var blocksLink: Bool {
    switch self {
    case .poweredOff, .denied, .unsupported: true
    case .unknown, .ready, .notDetermined: false
    }
  }

  static func from(authorization: CBManagerAuthorization, state: CBManagerState?) -> BluetoothAccess {
    switch authorization {
    case .denied, .restricted: return .denied
    case .notDetermined: return .notDetermined
    case .allowedAlways: break
    @unknown default: return .unknown
    }
    guard let state else { return .unknown }
    switch state {
    case .poweredOn: return .ready
    case .poweredOff: return .poweredOff
    case .unauthorized: return .denied
    case .unsupported: return .unsupported
    case .resetting, .unknown: return .unknown
    @unknown default: return .unknown
    }
  }
}

/// Watches the Bluetooth state without scanning or connecting. The manager is
/// created only once the permission is granted: creating it earlier would
/// show the system prompt by itself (the Meta SDK asks when it needs to).
@MainActor
final class BluetoothAccessMonitor: NSObject, CBCentralManagerDelegate {
  private var manager: CBCentralManager?
  private var lastState: CBManagerState?
  private(set) var access: BluetoothAccess = .unknown
  var onChange: ((BluetoothAccess) -> Void)?

  func refresh() {
    if manager == nil, CBManager.authorization == .allowedAlways {
      manager = CBCentralManager(
        delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
    }
    update()
  }

  nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
    let state = central.state
    MainActor.assumeIsolated {
      lastState = state
      update()
    }
  }

  private func update() {
    let value = BluetoothAccess.from(authorization: CBManager.authorization, state: lastState)
    guard value != access else { return }
    access = value
    onChange?(value)
  }
}

// MARK: - Signing of the installed app

/// What the installed app was signed with, read from its embedded
/// provisioning profile (sideloaded IPAs are re-signed on the owner's side).
/// Only dates, kinds and yes/no facts: never team names, identifiers or
/// device lists.
struct ProvisioningSummary: Equatable {
  var present: Bool
  var expires: Date?
  var isDevelopment: Bool?
  var hasWiFiInfoEntitlement = false
  var hasHotspotEntitlement = false

  static func read(bundle: Bundle = .main) -> ProvisioningSummary {
    guard let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
          let data = try? Data(contentsOf: url) else {
      return ProvisioningSummary(present: false)
    }
    return parse(data)
  }

  /// The profile is a signed container with a plain property list inside.
  static func parse(_ data: Data) -> ProvisioningSummary {
    guard let start = data.range(of: Data("<?xml".utf8)),
          let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex),
          let plist = try? PropertyListSerialization.propertyList(
            from: data.subdata(in: start.lowerBound..<end.upperBound), format: nil) as? [String: Any] else {
      return ProvisioningSummary(present: true)
    }
    let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
    return ProvisioningSummary(
      present: true,
      expires: plist["ExpirationDate"] as? Date,
      isDevelopment: entitlements["get-task-allow"] as? Bool,
      hasWiFiInfoEntitlement: entitlements["com.apple.developer.networking.wifi-info"] != nil,
      hasHotspotEntitlement: entitlements["com.apple.developer.networking.HotspotConfiguration"] != nil)
  }

  func summary(now: Date = Date()) -> String {
    guard present else { return "no embedded profile (simulator, or an unsigned build)" }
    var parts: [String] = []
    if let isDevelopment { parts.append(isDevelopment ? "development profile" : "distribution profile") }
    if let expires {
      let days = Int((expires.timeIntervalSince(now) / 86_400).rounded(.down))
      parts.append(days < 0 ? "expired" : "expires in \(days) day\(days == 1 ? "" : "s")")
    }
    parts.append(hasHotspotEntitlement && hasWiFiInfoEntitlement
      ? "Wi-Fi streaming entitlements present" : "no Wi-Fi streaming entitlements (Bluetooth only)")
    return parts.joined(separator: " · ")
  }
}

// MARK: - The Meta SDK's own log

/// The DAT SDK writes its own log in the app's caches
/// (`MetaWearablesDAT.log`). Its lines name causes the API does not report,
/// such as "This app is no longer registered", the glasses' DAT app (DWA),
/// link switching or authentication (SDK issues #292 and #301). Only lines
/// with such words are shown, sanitized, with long identifiers masked.
enum DATLogReader {
  static let keywords = [
    "error", "fail", "registered", "registration", "dwa", "l2cap", "link", "session", "trust", "manifest",
    "unavailable", "ended by device", "compatib", "version", "permission", "timeout", "disconnect", "refus",
  ]

  /// Where the SDK keeps its log: any `.log` file under a `MetaWearablesDAT`
  /// folder in the app's caches.
  static func logFiles(in caches: URL? = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first) -> [URL] {
    guard let caches else { return [] }
    let root = caches.appendingPathComponent("MetaWearablesDAT", isDirectory: true)
    guard let enumerator = FileManager.default.enumerator(
      at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { return [] }
    var files: [URL] = []
    for case let url as URL in enumerator where url.pathExtension == "log" {
      files.append(url)
    }
    return files.sorted { $0.lastPathComponent < $1.lastPathComponent }
  }

  /// The last `limit` interesting lines of the newest log, sanitized.
  static func recentLines(limit: Int = 30, files: [URL] = DATLogReader.logFiles()) -> [String] {
    guard let newest = files.max(by: { modified($0) < modified($1) }),
          let handle = try? FileHandle(forReadingFrom: newest) else { return [] }
    defer { try? handle.close() }
    let size = (try? handle.seekToEnd()) ?? 0
    let tail: UInt64 = 128 * 1_024
    try? handle.seek(toOffset: size > tail ? size - tail : 0)
    guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8)
      ?? String(data: data, encoding: .isoLatin1) else { return [] }
    return filter(text, limit: limit)
  }

  /// Keeps the lines that name a cause; masks identifiers and sanitizes.
  static func filter(_ text: String, limit: Int) -> [String] {
    let lines = text.split(whereSeparator: \.isNewline).map(String.init)
    let picked = lines.filter { line in
      let lower = line.lowercased()
      return keywords.contains { lower.contains($0) }
    }
    return picked.suffix(limit).map { LogSanitizer.sanitize(maskIdentifiers($0), limit: 300) }
  }

  /// Serials, UUIDs and long hex or digit runs become "[id]"; a device id
  /// never leaves the phone in a copied report.
  static func maskIdentifiers(_ line: String) -> String {
    let patterns = [
      #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"#,
      #"\b[0-9A-Fa-f]{12,}\b"#,
      #"\b\d{9,}\b"#,
    ]
    var output = line
    for pattern in patterns {
      output = output.replacingOccurrences(of: pattern, with: "[id]", options: .regularExpression)
    }
    return output
  }

  private static func modified(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
  }
}

// MARK: - The layers, one row each

/// One layer of the Ray-Ban connection and what was really measured for it.
struct ConnectionLayer: Identifiable, Equatable {
  enum State: String, Equatable { case ok, working, problem, off, unknown }
  let id: String
  let title: String
  let value: String
  let state: State
}

/// Facts from the connection, the stream, the voice session and the audio
/// route, collected for the layer table. Nothing here is a guess: a value the
/// app cannot measure is "—".
struct ConnectionLayerFacts: Equatable {
  var bluetooth: BluetoothAccess = .unknown
  var sdkConfigured = false
  var registration = "—"
  var link = "—"
  var compatibility = "—"
  var worn: Bool?
  var hingeOpen: Bool?
  var battery: Int?
  var sessionState = "—"
  var sessionProblem: GlassesSessionProblem?
  var cameraWanted = false
  var cameraPermission = "—"
  var streamState = "—"
  var measuredFPS: Double = 0
  var lastFrameAgeMs: Int?
  var frameSource = "—"
  var microphone = "—"
  var microphoneIsGlasses = false
  var output = "—"
  var voiceState = "—"
  var voiceActive = false
  var dataChannelOpen: Bool?
}

enum ConnectionLayerReport {
  static func layers(_ facts: ConnectionLayerFacts) -> [ConnectionLayer] {
    var rows: [ConnectionLayer] = []
    let bluetoothState: ConnectionLayer.State = switch facts.bluetooth {
    case .ready: .ok
    case .notDetermined, .unknown: .unknown
    case .poweredOff, .denied, .unsupported: .problem
    }
    rows.append(ConnectionLayer(
      id: "bluetooth", title: L.t("Bluetooth (iPhone)", "Bluetooth (iPhone)"),
      value: bluetoothText(facts.bluetooth), state: bluetoothState))
    rows.append(ConnectionLayer(
      id: "sdk", title: "Meta DAT SDK \(GlassesSDKInfo.datVersion)",
      value: facts.sdkConfigured ? L.t("started", "başladı") : L.t("not started", "başlamadı"),
      state: facts.sdkConfigured ? .ok : .problem))
    rows.append(ConnectionLayer(
      id: "registration", title: L.t("Meta AI registration", "Meta AI kaydı"),
      value: facts.registration, state: facts.registration == "registered" ? .ok : .working))
    var linkValue = facts.link
    if facts.compatibility != "—", facts.compatibility != "compatible" { linkValue += " · \(facts.compatibility)" }
    if let worn = facts.worn { linkValue += worn ? L.t(" · worn", " · takılı") : L.t(" · not worn", " · takılı değil") }
    if facts.hingeOpen == false { linkValue += L.t(" · folded", " · katlı") }
    if let battery = facts.battery { linkValue += " · %\(battery)" }
    rows.append(ConnectionLayer(
      id: "link", title: L.t("Glasses link (Bluetooth)", "Gözlük bağlantısı (Bluetooth)"),
      value: linkValue, state: facts.link == "connected" ? .ok : facts.link == "connecting" ? .working : .off))
    let sessionState: ConnectionLayer.State
    if facts.sessionProblem != nil, facts.sessionProblem != .versionWarning {
      sessionState = .problem
    } else {
      sessionState = facts.sessionState == "started" ? .ok
        : facts.sessionState == "starting" || facts.sessionState == "paused" ? .working : .off
    }
    rows.append(ConnectionLayer(
      id: "session", title: L.t("Glasses session (DAT)", "Gözlük oturumu (DAT)"),
      value: facts.sessionProblem.map { "\(facts.sessionState) · \(problemText($0))" } ?? facts.sessionState,
      state: facts.cameraWanted ? sessionState : .off))
    let streaming = facts.streamState == "streaming"
    let fresh = (facts.lastFrameAgeMs ?? Int.max) < 1_500
    var streamValue = facts.cameraWanted ? facts.streamState : L.t("not chosen", "seçili değil")
    if facts.cameraWanted, streaming {
      streamValue += String(format: " · %.0f fps", facts.measuredFPS)
      if let age = facts.lastFrameAgeMs { streamValue += " · " + L.t("last frame \(age) ms", "son kare \(age) ms") }
    }
    rows.append(ConnectionLayer(
      id: "camera", title: L.t("Ray-Ban camera", "Ray-Ban kamerası"),
      value: streamValue + (facts.cameraPermission == "denied" ? L.t(" · permission off", " · izin kapalı") : ""),
      state: !facts.cameraWanted ? .off : streaming && fresh ? .ok : streaming ? .working
        : facts.cameraPermission == "denied" ? .problem : .working))
    rows.append(ConnectionLayer(
      id: "source", title: L.t("Image the assistant sees", "Asistanın gördüğü görüntü"),
      value: facts.frameSource, state: facts.frameSource == "—" ? .off : .ok))
    rows.append(ConnectionLayer(
      id: "microphone", title: L.t("Microphone", "Mikrofon"),
      value: facts.microphone + (facts.microphoneIsGlasses ? L.t(" (glasses)", " (gözlük)") : ""),
      state: facts.microphone == "—" ? .off : .ok))
    rows.append(ConnectionLayer(
      id: "output", title: L.t("Sound output", "Ses çıkışı"),
      value: facts.output, state: facts.output == "—" ? .off : .ok))
    let channel = facts.dataChannelOpen.map { $0 ? L.t("open", "açık") : L.t("closed", "kapalı") } ?? "—"
    rows.append(ConnectionLayer(
      id: "voice", title: L.t("Realtime AI session", "Gerçek zamanlı AI oturumu"),
      value: "\(facts.voiceState) · data channel \(channel)",
      state: facts.voiceActive ? (facts.dataChannelOpen == true ? .ok : .working) : .off))
    return rows
  }

  static func bluetoothText(_ access: BluetoothAccess) -> String {
    switch access {
    case .ready: L.t("allowed, on", "izinli, açık")
    case .poweredOff: L.t("off — turn Bluetooth on", "kapalı — Bluetooth'u aç")
    case .denied: L.t("not allowed — Settings → AutoLoom → Bluetooth", "izin yok — Ayarlar → AutoLoom → Bluetooth")
    case .notDetermined: L.t("not asked yet", "henüz sorulmadı")
    case .unsupported: L.t("not supported", "desteklenmiyor")
    case .unknown: "—"
    }
  }

  static func problemText(_ problem: GlassesSessionProblem) -> String {
    switch problem {
    case .sdkTooOld: L.t("this build's Meta toolkit is too old", "bu sürümün Meta araç seti eski")
    case .glassesAppUpdateRequired: L.t("DAT app on the glasses needs an update", "gözlükteki DAT uygulaması güncellenmeli")
    case .glassesAppUnavailable: L.t("DAT app on the glasses not reachable", "gözlükteki DAT uygulamasına ulaşılamıyor")
    case .refusing(let count): L.t("the glasses refused \(count) sessions", "gözlük \(count) oturumu reddetti")
    case .callActive: L.t("the glasses treat the microphone link as a call", "gözlük mikrofon bağlantısını görüşme sayıyor")
    case .deviceHealth(let what): L.t("glasses limit: \(what)", "gözlük sınırı: \(what)")
    case .versionWarning: L.t("versions outside the recommended range", "sürümler önerilen aralığın dışında")
    }
  }
}

extension ConnectionLayer.State {
  var color: Color {
    switch self {
    case .ok: .green
    case .working: AutoLoomTheme.electricBlue
    case .problem: .orange
    case .off, .unknown: .secondary
    }
  }

  var symbol: String {
    switch self {
    case .ok: "checkmark.circle.fill"
    case .working: "circle.dotted"
    case .problem: "exclamationmark.triangle.fill"
    case .off: "minus.circle"
    case .unknown: "questionmark.circle"
    }
  }
}
