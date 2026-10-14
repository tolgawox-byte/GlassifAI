import Combine
import CryptoKit
import Foundation
import MWDATCore
import SwiftUI

#if canImport(MWDATMockDevice)
import MWDATMockDevice
#endif

// MARK: - Connection model (pure, unit-tested)

/// Where the Ray-Ban connection is, from the SDK starting to a usable
/// camera. Registration with Meta AI and the physical link to the glasses
/// are separate steps: a registered app can be far from its glasses, and a
/// connected pair can still have no camera.
enum GlassesConnectionPhase: String, Equatable, CaseIterable {
  case sdkUnavailable = "SDK_UNAVAILABLE"
  /// Just launched: an earlier registration may not be restored yet.
  case restoring = "RESTORING"
  case notRegistered = "NOT_REGISTERED"
  case registrationStarting = "REGISTRATION_STARTING"
  case waitingForMetaAI = "WAITING_FOR_META_AI"
  /// Meta AI did not send the approval back (cancelled or the callback was
  /// lost): offered again instead of spinning.
  case registrationStalled = "REGISTRATION_STALLED"
  case registeredNoDevice = "REGISTERED_NO_DEVICE"
  /// The iPhone's Bluetooth is off or AutoLoom may not use it.
  case bluetoothUnavailable = "BLUETOOTH_UNAVAILABLE"
  case deviceDisconnected = "DEVICE_DISCONNECTED"
  case deviceConnecting = "DEVICE_CONNECTING"
  case deviceConnected = "DEVICE_CONNECTED"
  /// This build's Meta toolkit is too old for the glasses.
  case appUpdateRequired = "APP_UPDATE_REQUIRED"
  /// The glasses' software or their DAT app needs an update in Meta AI.
  case glassesUpdateRequired = "GLASSES_UPDATE_REQUIRED"
  case requestingCameraPermission = "REQUESTING_CAMERA_PERMISSION"
  case cameraPermissionNeeded = "CAMERA_PERMISSION_NEEDED"
  /// The DAT 1.0 device session is starting on the glasses.
  case startingSession = "STARTING_SESSION"
  /// The wearer paused the session (a temple tap) or the system did.
  case sessionPaused = "SESSION_PAUSED"
  /// The DAT app on the glasses did not come up.
  case glassesAppUnavailable = "GLASSES_APP_UNAVAILABLE"
  /// The glasses keep refusing sessions: a power cycle is needed.
  case glassesRefusing = "GLASSES_REFUSING"
  /// The glasses treat their microphone link (HFP) as a call and keep the
  /// camera off until it ends (current glasses software, Meta #206/#332).
  case glassesInCall = "GLASSES_IN_CALL"
  case startingCamera = "STARTING_CAMERA"
  case cameraStreaming = "CAMERA_STREAMING"
  case cameraFailed = "CAMERA_FAILED"
  case ready = "READY"

  /// The glasses are linked to this iPhone, whatever the camera is doing.
  var isLinked: Bool {
    switch self {
    case .deviceConnected, .appUpdateRequired, .glassesUpdateRequired, .requestingCameraPermission,
         .cameraPermissionNeeded, .startingSession, .sessionPaused, .glassesAppUnavailable, .glassesRefusing,
         .glassesInCall, .startingCamera, .cameraStreaming, .cameraFailed, .ready:
      true
    default:
      false
    }
  }

  /// The Meta AI registration flow is needed or under way.
  var needsSetupScreen: Bool {
    switch self {
    case .notRegistered, .registrationStarting, .waitingForMetaAI, .registrationStalled: true
    default: false
    }
  }

  /// Linked, but only the user can make the glasses usable (an update, a
  /// power cycle, Developer Mode in Meta AI).
  var needsUserAction: Bool {
    switch self {
    case .appUpdateRequired, .glassesUpdateRequired, .glassesAppUnavailable, .glassesRefusing, .glassesInCall,
         .bluetoothUnavailable: true
    default: false
    }
  }
}

/// The facts the phase is derived from. Independent of the SDK types so the
/// state machine can be tested without glasses.
struct GlassesConnectionSnapshot: Equatable {
  enum Registration: String, Equatable { case unavailable, available, registering, registered }
  enum Link: String, Equatable { case unknown, disconnected, connecting, connected }
  enum Permission: String, Equatable { case unknown, checking, requesting, granted, denied }
  enum Stream: String, Equatable { case stopped, waiting, streaming }
  /// The DAT 1.0 device session.
  enum Session: String, Equatable { case none, starting, started, paused, stopping, stopped }
  /// A compatibility value that blocks the camera.
  enum CompatibilityIssue: String, Equatable { case glassesUpdate, appUpdate }

  var sdkConfigured = false
  var registration: Registration = .unavailable
  var restoring = false
  var registrationRequested = false
  var registrationStalled = false
  var bluetooth: BluetoothAccess = .unknown
  var deviceCount = 0
  /// The SDK's device selector picked a connected device.
  var activeDevice = false
  var link: Link = .unknown
  var compatibilityIssue: CompatibilityIssue?
  var hasMockDevice = false
  /// The Ray-Ban camera is the chosen source.
  var cameraWanted = false
  var permission: Permission = .unknown
  var session: Session = .none
  var sessionProblem: GlassesSessionProblem?
  var stream: Stream = .stopped
  var hasFrames = false
  var cameraFailure: String?
}

/// What the user sees for the connection: a few plain words, never enum
/// names (those are in Settings → Developer → Ray-Ban connection).
struct GlassesUserStatus: Equatable {
  enum Tone: Equatable { case connected, working, attention, idle }
  var title: String
  var detail: String?
  var tone: Tone
  /// One clean recovery action when automatic recovery needs the user.
  var showsTryAgain: Bool
}

enum GlassesConnectionReducer {
  static func phase(for s: GlassesConnectionSnapshot) -> GlassesConnectionPhase {
    guard s.sdkConfigured else { return .sdkUnavailable }
    let registered = s.registration == .registered || s.hasMockDevice
    if !registered {
      if s.registrationStalled { return .registrationStalled }
      if s.registration == .registering { return .waitingForMetaAI }
      if s.registrationRequested { return .registrationStarting }
      if s.restoring { return .restoring }
      return .notRegistered
    }
    let linked = s.link == .connected || s.activeDevice
    if !linked {
      if s.bluetooth.blocksLink { return .bluetoothUnavailable }
      if s.link == .connecting { return .deviceConnecting }
      return s.deviceCount == 0 ? .registeredNoDevice : .deviceDisconnected
    }
    // Versions first: nothing after the link can work until they match.
    if s.compatibilityIssue == .appUpdate || s.sessionProblem == .sdkTooOld { return .appUpdateRequired }
    if s.compatibilityIssue == .glassesUpdate || s.sessionProblem == .glassesAppUpdateRequired {
      return .glassesUpdateRequired
    }
    guard s.cameraWanted else { return .deviceConnected }
    switch s.stream {
    case .streaming: return s.hasFrames ? .ready : .cameraStreaming
    case .waiting:
      if s.session == .paused { return .sessionPaused }
      return s.session == .starting ? .startingSession : .startingCamera
    case .stopped: break
    }
    if case .refusing = s.sessionProblem { return .glassesRefusing }
    if s.sessionProblem == .callActive { return .glassesInCall }
    if s.sessionProblem == .glassesAppUnavailable { return .glassesAppUnavailable }
    if s.session == .paused { return .sessionPaused }
    switch s.permission {
    case .checking, .requesting: return .requestingCameraPermission
    case .denied: return .cameraPermissionNeeded
    case .unknown, .granted: break
    }
    if s.session == .starting { return .startingSession }
    return s.cameraFailure == nil ? .startingCamera : .cameraFailed
  }

  static func status(for phase: GlassesConnectionPhase, cameraIssue: String? = nil) -> GlassesUserStatus {
    let connected = L.t("Ray-Ban Connected", "Ray-Ban bağlı")
    switch phase {
    case .sdkUnavailable:
      return GlassesUserStatus(
        title: L.t("Ray-Ban unavailable", "Ray-Ban kullanılamıyor"),
        detail: L.t("The glasses connection could not start on this iPhone.", "Gözlük bağlantısı bu iPhone'da başlatılamadı."),
        tone: .attention, showsTryAgain: false)
    case .restoring:
      return GlassesUserStatus(title: L.t("Connecting to Ray-Ban…", "Ray-Ban'a bağlanıyor…"), detail: nil, tone: .working, showsTryAgain: false)
    case .notRegistered:
      return GlassesUserStatus(
        title: L.t("Not connected", "Bağlı değil"),
        detail: L.t("Connect your glasses through Meta AI.", "Gözlüğünü Meta AI üzerinden bağla."),
        tone: .idle, showsTryAgain: false)
    case .registrationStarting:
      return GlassesUserStatus(title: L.t("Opening Meta AI…", "Meta AI açılıyor…"), detail: nil, tone: .working, showsTryAgain: false)
    case .waitingForMetaAI:
      return GlassesUserStatus(
        title: L.t("Approve in Meta AI", "Meta AI'da onayla"),
        detail: L.t("Allow AutoLoom in Meta AI, then come back.", "Meta AI'da AutoLoom'a izin ver, sonra geri dön."),
        tone: .working, showsTryAgain: false)
    case .registrationStalled:
      return GlassesUserStatus(
        title: L.t("Meta AI didn't confirm", "Meta AI onay göndermedi"),
        detail: cameraIssue ?? L.t("The approval did not come back to AutoLoom.", "Onay AutoLoom'a geri gelmedi."),
        tone: .attention, showsTryAgain: true)
    case .registeredNoDevice, .deviceDisconnected:
      return GlassesUserStatus(
        title: L.t("Wake your glasses", "Gözlüğünü uyandır"),
        detail: L.t("Open them and keep them near your iPhone.", "Gözlüğü aç ve iPhone'a yakın tut."),
        tone: .idle, showsTryAgain: false)
    case .bluetoothUnavailable:
      return GlassesUserStatus(
        title: L.t("Bluetooth is off", "Bluetooth kapalı"),
        detail: cameraIssue ?? L.t("Turn on Bluetooth and allow it for AutoLoom (Settings → AutoLoom).",
                                   "Bluetooth'u aç ve AutoLoom'a izin ver (Ayarlar → AutoLoom)."),
        tone: .attention, showsTryAgain: false)
    case .deviceConnecting:
      return GlassesUserStatus(title: L.t("Connecting…", "Bağlanıyor…"), detail: nil, tone: .working, showsTryAgain: false)
    case .deviceConnected, .ready:
      return GlassesUserStatus(title: connected, detail: nil, tone: .connected, showsTryAgain: false)
    case .appUpdateRequired:
      return GlassesUserStatus(
        title: L.t("AutoLoom update needed", "AutoLoom güncellemesi gerekiyor"),
        detail: L.t("The glasses no longer accept the Meta toolkit in this build (DAT \(GlassesSDKInfo.datVersion)). The iPhone camera still works.",
                    "Gözlük bu sürümdeki Meta araç setini (DAT \(GlassesSDKInfo.datVersion)) artık kabul etmiyor. iPhone kamerası çalışmaya devam eder."),
        tone: .attention, showsTryAgain: false)
    case .glassesUpdateRequired:
      return GlassesUserStatus(
        title: L.t("Update in Meta AI", "Meta AI'da güncelleme gerekiyor"),
        detail: cameraIssue ?? L.t("Update the glasses and their DAT app in Meta AI, then try again.",
                                   "Meta AI'da gözlüğü ve gözlükteki DAT uygulamasını güncelle, sonra tekrar dene."),
        tone: .attention, showsTryAgain: true)
    case .requestingCameraPermission:
      return GlassesUserStatus(
        title: connected, detail: L.t("Checking camera permission…", "Kamera izni kontrol ediliyor…"),
        tone: .connected, showsTryAgain: false)
    case .startingSession:
      return GlassesUserStatus(
        title: connected, detail: L.t("Opening the glasses session…", "Gözlük oturumu açılıyor…"),
        tone: .connected, showsTryAgain: false)
    case .sessionPaused:
      return GlassesUserStatus(
        title: connected, detail: L.t("Paused — tap the glasses' temple to resume.", "Duraklatıldı — devam etmek için gözlüğün sapına dokun."),
        tone: .connected, showsTryAgain: false)
    case .glassesAppUnavailable:
      return GlassesUserStatus(
        title: L.t("Glasses app not reachable", "Gözlükteki uygulamaya ulaşılamıyor"),
        detail: L.t("In Meta AI check Developer Mode and that the DAT app is installed on the glasses, then try again.",
                    "Meta AI'da Geliştirici Modu'nu ve gözlükte DAT uygulamasının kurulu olduğunu kontrol et, sonra tekrar dene."),
        tone: .attention, showsTryAgain: true)
    case .glassesInCall:
      return GlassesUserStatus(
        title: L.t("Camera paused by a call", "Kamera görüşme yüzünden kapalı"),
        detail: L.t("The glasses treat their microphone link as a call and keep the camera off until it ends (current Meta glasses software). AutoLoom uses the iPhone microphone with the Ray-Ban camera; a phone call also does this.",
                    "Gözlük, mikrofon bağlantısını görüşme sayıyor ve görüşme bitene kadar kamerayı kapalı tutuyor (Meta'nın güncel gözlük yazılımı). AutoLoom, Ray-Ban kamerasıyla iPhone mikrofonunu kullanır; bir telefon görüşmesi de bunu yapar."),
        tone: .attention, showsTryAgain: true)
    case .glassesRefusing:
      return GlassesUserStatus(
        title: L.t("The glasses refuse the connection", "Gözlük bağlantıyı reddediyor"),
        detail: L.t("Switch the glasses off and on with their power switch (the case is not enough), then try again.",
                    "Gözlüğü güç düğmesiyle kapatıp aç (kutuya koymak yetmez), sonra tekrar dene."),
        tone: .attention, showsTryAgain: true)
    case .startingCamera, .cameraStreaming:
      return GlassesUserStatus(title: connected, detail: L.t("Starting camera…", "Kamera başlıyor…"), tone: .connected, showsTryAgain: false)
    case .cameraPermissionNeeded:
      return GlassesUserStatus(
        title: L.t("Permission needed", "İzin gerekli"),
        detail: L.t("Allow camera access for AutoLoom in Meta AI.", "Meta AI'da AutoLoom için kamera iznini aç."),
        tone: .attention, showsTryAgain: true)
    case .cameraFailed:
      return GlassesUserStatus(
        title: connected,
        detail: cameraIssue ?? L.t("Camera unavailable — trying again", "Kamera kullanılamıyor — yeniden deneniyor"),
        tone: .attention, showsTryAgain: true)
    }
  }

  enum ConnectDecision: Equatable {
    /// Something is already in progress (or cannot work): no second flow.
    case ignore
    /// Registered already: never register again, look at the glasses.
    case refresh
    case startRegistration
  }

  static func connectDecision(for phase: GlassesConnectionPhase) -> ConnectDecision {
    switch phase {
    case .sdkUnavailable, .restoring, .registrationStarting, .waitingForMetaAI:
      .ignore
    case .notRegistered, .registrationStalled:
      .startRegistration
    case .registeredNoDevice, .bluetoothUnavailable, .deviceDisconnected, .deviceConnecting, .deviceConnected,
         .appUpdateRequired, .glassesUpdateRequired, .requestingCameraPermission, .cameraPermissionNeeded,
         .startingSession, .sessionPaused, .glassesAppUnavailable, .glassesRefusing, .glassesInCall,
         .startingCamera, .cameraStreaming, .cameraFailed, .ready:
      .refresh
    }
  }

  /// Bounded backoff between camera start attempts while the glasses are
  /// linked: 2, 4, 8, 15, then every 30 s. Never a busy loop, and never two
  /// session attempts within 2 s: Meta says rapid cycling wedges the glasses
  /// until a power cycle (SDK issues #231 and #332).
  static func retryDelay(afterFailures failures: Int) -> TimeInterval {
    let steps: [TimeInterval] = [2, 4, 8, 15, 30]
    return steps[min(max(failures, 0), steps.count - 1)]
  }

  /// Meta AI opens within seconds of the request.
  static let metaAIOpenTimeout: TimeInterval = 10
  /// Back in AutoLoom this long without the approval: offer it again.
  static let registrationReturnGrace: TimeInterval = 12
  static let registrationTotalLimit: TimeInterval = 120

  static func registrationStalled(requestedAt: Date, leftAppAt: Date?, returnedAt: Date?, now: Date) -> Bool {
    if now.timeIntervalSince(requestedAt) > registrationTotalLimit { return true }
    guard let leftAppAt else {
      // Meta AI never came up.
      return now.timeIntervalSince(requestedAt) > metaAIOpenTimeout
    }
    guard let returnedAt, returnedAt >= leftAppAt else { return false }
    return now.timeIntervalSince(returnedAt) > registrationReturnGrace
  }

  /// How long a launch waits for the SDK to restore an earlier registration
  /// before showing the connect screen.
  static func restoringGrace(wasRegistered: Bool) -> TimeInterval {
    wasRegistered ? 6 : 1.5
  }

  /// A stream that stays "starting" this long with the glasses linked is
  /// restarted.
  static let cameraStartTimeout: TimeInterval = 25
  /// The "Ray-Ban Connected" confirmation at most this often.
  static let connectedNoticeInterval: TimeInterval = 30
}

/// The MWDAT configuration the app actually runs with (read from the
/// installed bundle, so a re-signed sideload is checked as it is). Values of
/// MetaAppID, ClientToken and TeamID are never shown, only whether they are
/// set.
struct DATConfigurationAudit: Equatable {
  var bundleIdentifier: String
  var appLinkURLScheme: String?
  var urlSchemes: [String]
  var metaAppID: String
  var clientToken: String
  var teamID: String
  var analyticsOptOut: Bool

  static var current: DATConfigurationAudit {
    audit(Bundle.main.infoDictionary ?? [:], bundleIdentifier: Bundle.main.bundleIdentifier ?? "—")
  }

  static func audit(_ info: [String: Any], bundleIdentifier: String) -> DATConfigurationAudit {
    let mwdat = info["MWDAT"] as? [String: Any] ?? [:]
    let schemes = (info["CFBundleURLTypes"] as? [[String: Any]] ?? [])
      .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
    let analytics = mwdat["Analytics"] as? [String: Any]
    return DATConfigurationAudit(
      bundleIdentifier: bundleIdentifier,
      appLinkURLScheme: mwdat["AppLinkURLScheme"] as? String,
      urlSchemes: schemes,
      metaAppID: describe(mwdat["MetaAppID"]),
      clientToken: describe(mwdat["ClientToken"]),
      teamID: describe(mwdat["TeamID"]),
      analyticsOptOut: (analytics?["OptOut"] as? Bool) ?? false)
  }

  private static func describe(_ value: Any?) -> String {
    guard let text = (value as? String)?.trimmingCharacters(in: .whitespaces) else { return "missing" }
    if text.isEmpty { return "empty" }
    if text == "0" { return "0 (Developer Mode)" }
    return "set (\(text.count) characters)"
  }

  /// Problems that stop Meta AI from calling the app back.
  var problems: [String] {
    var found: [String] = []
    guard let scheme = appLinkURLScheme, !scheme.isEmpty else {
      return ["MWDAT AppLinkURLScheme is missing"]
    }
    let bare = scheme.replacingOccurrences(of: "://", with: "")
    if !urlSchemes.contains(bare) {
      found.append("AppLinkURLScheme \(scheme) is not a registered URL scheme (\(urlSchemes.joined(separator: ", ")))")
    }
    if !scheme.hasSuffix("://") {
      found.append("AppLinkURLScheme should end with ://")
    }
    return found
  }

  /// Settings that are known to break DAT for some setups, said once.
  var warnings: [String] {
    var found: [String] = []
    // Meta's known issues list the '-' in an iOS bundle id as unsupported
    // (facebook/meta-wearables-dat-ios #212, #282). Some re-signing tools
    // change the bundle id of a sideloaded IPA.
    if bundleIdentifier.contains("-") {
      found.append("The bundle identifier contains '-', which Meta's toolkit has rejected; re-sign without changing the bundle id")
    }
    return found
  }

  var summary: String {
    "bundle \(bundleIdentifier); AppLinkURLScheme \(appLinkURLScheme ?? "missing"); URL schemes \(urlSchemes.joined(separator: ", ")); " +
      "MetaAppID \(metaAppID); ClientToken \(clientToken); TeamID \(teamID); analytics opt-out \(analyticsOptOut ? "yes" : "no")"
  }
}

extension GlassesConnectionSnapshot.Registration {
  init(_ state: RegistrationState) {
    switch state {
    case .unavailable: self = .unavailable
    case .available: self = .available
    case .registering: self = .registering
    case .registered: self = .registered
    }
  }
}

extension GlassesConnectionSnapshot.Link {
  init(_ state: LinkState) {
    switch state {
    case .disconnected: self = .disconnected
    case .connecting: self = .connecting
    case .connected: self = .connected
    }
  }
}

// MARK: - Coordinator

/// The one source of truth for the Ray-Ban connection: Meta AI registration,
/// the registered devices, the link to the glasses, camera permission and
/// the camera stream. Screens read `phase` and `status`; only this type
/// starts registration or the glasses camera.
///
/// - Registration is started only when the app is not registered, and only
///   once at a time. An already registered app never registers again; it
///   looks for its glasses.
/// - A temporary disconnect never unregisters. The camera starts again by
///   itself when the glasses come back, with a bounded backoff.
/// - Meta AI's callback is handled at the root of the app, whatever screen
///   is showing, so it cannot be lost to a cold launch.
@MainActor
final class WearableConnectionCoordinator: ObservableObject {
  static let shared = WearableConnectionCoordinator()

  struct Transition: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let text: String
  }

  @Published private(set) var phase: GlassesConnectionPhase = .sdkUnavailable
  @Published private(set) var snapshot = GlassesConnectionSnapshot()
  @Published private(set) var devices: [DeviceIdentifier] = []
  @Published private(set) var deviceName: String?
  @Published private(set) var compatibility = "—"
  @Published private(set) var lastError: String?
  @Published private(set) var transitions: [Transition] = []
  /// Camera start attempts since the stream last ran.
  @Published private(set) var reconnectAttempts = 0
  /// Bumped when the glasses become linked, for the short visual
  /// confirmation (at most every 30 s, never spoken).
  @Published private(set) var connectedNotice = 0
  /// Registered before, but not any more when the app started (Developer
  /// Mode keeps one third-party app registered at a time).
  @Published private(set) var registrationLost = false
  /// Something only the user can fix, shown once.
  @Published var userAlert: String?
  /// The glasses' own state (DAT 1.0 `DeviceState`): worn, folded, battery,
  /// heat. nil until the SDK reports it.
  @Published private(set) var worn: Bool?
  @Published private(set) var hingeOpen: Bool?
  @Published private(set) var batteryLevel: Int?
  @Published private(set) var thermal = "—"
  /// When the glasses link last came up, and when frames last started.
  @Published private(set) var lastLinkedAt: Date?
  @Published private(set) var lastReadyAt: Date?
  /// A user-started registration finished in this run (the Ray-Ban camera is
  /// then chosen if the iPhone camera was).
  @Published private(set) var registrationCompletions = 0

  private(set) var wearables: WearablesInterface?
  private(set) var configureError: String?
  private weak var stream: StreamSessionViewModel?
  private var streamCancellables: Set<AnyCancellable> = []
  private var registrationTask: Task<Void, Never>?
  private var devicesTask: Task<Void, Never>?
  private var linkTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var compatibilityTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private var deviceStateTokens: [DeviceIdentifier: AnyListenerToken] = [:]
  private let bluetoothMonitor = BluetoothAccessMonitor()
  private var audioRouteCancellable: AnyCancellable?
  private var listenerRetryTask: Task<Void, Never>?
  private var restoreTask: Task<Void, Never>?
  private var registrationWatch: Task<Void, Never>?
  private var attemptTask: Task<Void, Never>?
  private var startWatchdog: Task<Void, Never>?
  private var registrationRequestedAt: Date?
  private var leftAppAt: Date?
  private var returnedAt: Date?
  private var failures = 0
  private var nextAttemptAt = Date.distantPast
  private var startInFlight = false
  private var permissionRequestAllowed = true
  private var lastConnectedNoticeAt = Date.distantPast
  private var isForeground = true
  private var cameraIssue: String?
  /// The user chose Forget glasses (so a lost registration is expected).
  private var userForgot = false

  static let wasRegisteredKey = "autoloom.glasses.wasRegistered"

  private init() {}

  var status: GlassesUserStatus {
    GlassesConnectionReducer.status(for: phase, cameraIssue: cameraIssue)
  }

  /// For hands-free arming: nil until a device is known.
  var glassesLinkConnected: Bool? {
    devices.isEmpty && !snapshot.activeDevice ? nil : (snapshot.link == .connected || snapshot.activeDevice)
  }

  var isRegistered: Bool {
    snapshot.registration == .registered || snapshot.hasMockDevice
  }

  var hasMockDevice: Bool { snapshot.hasMockDevice }

  /// The glasses stream's codec and raw state, for diagnostics.
  var transportLabel: String { stream?.activeTransport.shortLabel ?? "—" }
  var streamStateLabel: String { stream?.lastStreamState ?? "—" }

  /// A short hash of the device identifier, never the identifier itself.
  var deviceHash: String {
    guard let id = devices.first else { return "—" }
    let digest = SHA256.hash(data: Data(id.utf8))
    return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
  }

  // MARK: Setup

  /// Called once at launch, right after `Wearables.configure()`.
  func attach(wearables: WearablesInterface?, configureError: Error?) {
    guard self.wearables == nil, snapshot.sdkConfigured == false else { return }
    self.wearables = wearables
    self.configureError = configureError.map { LogSanitizer.sanitize(String(describing: $0), limit: 200) }
    snapshot.sdkConfigured = wearables != nil
    guard let wearables else {
      record("SDK unavailable: \(self.configureError ?? "configure failed")")
      evaluate(reason: "SDK unavailable")
      return
    }
    record("SDK configured (DAT \(GlassesSDKInfo.datVersion))")
    let config = DATConfigurationAudit.current
    for problem in config.problems + config.warnings { record("config: \(problem)") }
    bluetoothMonitor.onChange = { [weak self] access in
      guard let self else { return }
      self.snapshot.bluetooth = access
      self.record("bluetooth \(access.rawValue)")
      self.evaluate(reason: "bluetooth")
    }
    bluetoothMonitor.refresh()
    applyRegistration(wearables.registrationState, source: "launch", force: true)
    applyDevices(wearables.devices)
    if snapshot.registration != .registered {
      snapshot.restoring = true
      let grace = GlassesConnectionReducer.restoringGrace(
        wasRegistered: UserDefaults.standard.bool(forKey: Self.wasRegisteredKey))
      restoreTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: UInt64(grace * 1_000_000_000))
        guard !Task.isCancelled else { return }
        self?.endRestoring()
      }
    }
    registrationTask = Task { @MainActor [weak self] in
      for await state in wearables.registrationStateStream() {
        self?.applyRegistration(state, source: "event")
      }
    }
    devicesTask = Task { @MainActor [weak self] in
      for await ids in wearables.devicesStream() {
        self?.applyDevices(ids)
      }
    }
    evaluate(reason: "attached")
  }

  /// The glasses stream view model: its state is part of the connection.
  func bind(stream: StreamSessionViewModel) {
    guard self.stream !== stream else { return }
    self.stream = stream
    streamCancellables.removeAll()
    stream.$streamingStatus.removeDuplicates().sink { [weak self] status in
      self?.streamStatusChanged(status)
    }.store(in: &streamCancellables)
    stream.$hasReceivedFirstFrame.removeDuplicates().sink { [weak self] hasFrames in
      guard let self, self.snapshot.hasFrames != hasFrames else { return }
      self.snapshot.hasFrames = hasFrames
      if hasFrames { self.record("first glasses frame") }
      self.evaluate(reason: hasFrames ? "first frame" : "frames reset")
    }.store(in: &streamCancellables)
    stream.$hasActiveDevice.removeDuplicates().sink { [weak self] active in
      self?.activeDeviceChanged(active)
    }.store(in: &streamCancellables)
    stream.$glassesIssue.removeDuplicates().sink { [weak self] issue in
      self?.cameraIssueChanged(issue)
    }.store(in: &streamCancellables)
    stream.$deviceSessionState.removeDuplicates().sink { [weak self] state in
      self?.sessionStateChanged(state)
    }.store(in: &streamCancellables)
    stream.$sessionProblem.removeDuplicates().sink { [weak self] problem in
      self?.sessionProblemChanged(problem)
    }.store(in: &streamCancellables)
    // The call rule ends with the call: once the glasses' microphone link is
    // gone, the camera may start again (after the usual 2 s).
    audioRouteCancellable = AudioRouteMonitor.shared.$inputs
      .map { inputs in inputs.contains { $0.type == "Bluetooth HFP" } }
      .removeDuplicates()
      .sink { [weak self] handsFree in
        self?.handsFreeChanged(handsFree)
      }
    evaluate(reason: "stream bound")
  }

  private func handsFreeChanged(_ handsFree: Bool) {
    guard !handsFree, snapshot.sessionProblem == .callActive else { return }
    record("glasses microphone link closed: the camera may start again")
    stream?.clearSessionProblem()
    snapshot.sessionProblem = nil
    failures = max(failures, 1)
    nextAttemptAt = Date().addingTimeInterval(GlassesConnectionReducer.retryDelay(afterFailures: 0))
    attemptTask?.cancel()
    attemptTask = nil
    evaluate(reason: "call ended")
  }

  // MARK: User actions

  /// The Connect button: registers only when registration is really
  /// needed, never twice at once.
  func connect() {
    switch GlassesConnectionReducer.connectDecision(for: phase) {
    case .ignore:
      record("connect ignored (\(phase.rawValue))")
    case .refresh:
      record("connect: already registered, looking for the glasses")
      resetBackoff()
      refresh()
    case .startRegistration:
      startRegistration()
    }
  }

  /// The one recovery action ("Try Again").
  func retry() {
    record("try again")
    cameraIssue = nil
    snapshot.cameraFailure = nil
    permissionRequestAllowed = true
    if snapshot.permission == .denied { snapshot.permission = .unknown }
    // The user did what the screen asked (a power cycle, an update): the
    // glasses are judged afresh.
    stream?.clearSessionProblem()
    snapshot.sessionProblem = nil
    if snapshot.compatibilityIssue != nil { refresh() }
    resetBackoff()
    connect()
    evaluate(reason: "try again")
  }

  /// Opens Meta AI where the update the glasses need can be done.
  func openGlassesUpdate() {
    guard let wearables else { return }
    let appUpdate = snapshot.sessionProblem == .glassesAppUpdateRequired
    record(appUpdate ? "opening the DAT app update in Meta AI" : "opening the firmware update in Meta AI")
    Task { @MainActor [weak self] in
      do {
        if appUpdate {
          try await wearables.openDATGlassesAppUpdate()
        } else {
          try await wearables.openFirmwareUpdate()
        }
      } catch {
        self?.lastError = "open update: \(LogSanitizer.sanitize(String(describing: error), limit: 120))"
        self?.userAlert = L.t("Meta AI could not open the update page. Open Meta AI → Devices yourself.",
                              "Meta AI güncelleme sayfasını açamadı. Meta AI → Cihazlar'ı kendin aç.")
      }
    }
  }

  /// Settings → Forget glasses: the only place registration is removed.
  func forgetGlasses() {
    guard let wearables else { return }
    record("forget glasses (user)")
    userForgot = true
    UserDefaults.standard.set(false, forKey: Self.wasRegisteredKey)
    registrationLost = false
    Task { @MainActor [weak self] in
      do {
        try await wearables.startUnregistration()
      } catch let error as UnregistrationError {
        self?.lastError = "unregistration: \(error.description)"
        if error != .alreadyUnregistered {
          self?.userAlert = L.t("Meta AI could not remove the connection. Try again.", "Meta AI bağlantıyı kaldıramadı. Tekrar dene.")
        }
      } catch {
        self?.lastError = "unregistration: \(LogSanitizer.sanitize(String(describing: error), limit: 160))"
      }
    }
  }

  // Developer actions (Settings → Developer → Ray-Ban connection).

  func restartStream() {
    guard let stream else { return }
    record("restart stream (developer)")
    Task { @MainActor [weak self] in
      await stream.stopSession()
      self?.resetBackoff()
      self?.evaluate(reason: "restart stream")
    }
  }

  func reregister() {
    record("re-register (developer)")
    startRegistration()
  }

  /// The Ray-Ban camera is (or is no longer) the chosen source.
  func setCameraWanted(_ wanted: Bool) {
    guard wanted != snapshot.cameraWanted else {
      if wanted { evaluate(reason: "camera wanted") }
      return
    }
    snapshot.cameraWanted = wanted
    record(wanted ? "Ray-Ban camera chosen" : "Ray-Ban camera not chosen")
    if wanted {
      snapshot.cameraFailure = nil
      resetBackoff()
    } else {
      attemptTask?.cancel()
      attemptTask = nil
      startWatchdog?.cancel()
    }
    evaluate(reason: "camera source")
  }

  /// A conversation started: bring the camera back now if it should run.
  func requestStartSoon(reason: String) {
    guard snapshot.cameraWanted, snapshot.stream == .stopped else { return }
    record("start requested: \(reason)")
    resetBackoff()
    evaluate(reason: reason)
  }

  // MARK: App lifecycle

  func sceneBecameActive() {
    isForeground = true
    if registrationRequestedAt != nil, leftAppAt != nil { returnedAt = Date() }
    // The permission may have been changed in Settings meanwhile.
    bluetoothMonitor.refresh()
    refresh()
    if snapshot.stream == .stopped {
      // Coming back is a good moment to try at once.
      failures = min(failures, 1)
      nextAttemptAt = .distantPast
      attemptTask?.cancel()
      attemptTask = nil
    }
    evaluate(reason: "app active")
  }

  func sceneResigned() {
    isForeground = false
    if registrationRequestedAt != nil, leftAppAt == nil { leftAppAt = Date() }
  }

  // MARK: Meta AI callback

  /// Every URL the app opens passes here first; only Meta AI's callbacks
  /// (with `metaWearablesAction`) go to the SDK.
  func handleOpenURL(_ url: URL) {
    guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let action = components.queryItems?.first(where: { $0.name == "metaWearablesAction" }) else { return }
    guard let wearables else {
      record("Meta AI callback ignored: SDK unavailable")
      return
    }
    record("Meta AI callback received (\(LogSanitizer.sanitize(action.value ?? "action", limit: 40)))")
    Task { @MainActor [weak self] in
      do {
        // DAT 1.0: Meta AI can also start the registration itself (App
        // connections); the user approves it there, so the app continues it.
        _ = try await wearables.handleUrl(url, onRegistrationRequest: { request in
          Task { @MainActor in await WearableConnectionCoordinator.shared.continueRegistration(request) }
        })
        self?.record("Meta AI callback handled")
        self?.refresh()
      } catch {
        guard let self else { return }
        self.lastError = "callback: \(LogSanitizer.sanitize(String(describing: error), limit: 160))"
        self.record("Meta AI callback failed")
        if self.registrationRequestedAt != nil { self.markRegistrationStalled(detail: nil) }
      }
    }
  }

  // MARK: Registration

  private func startRegistration() {
    guard let wearables else { return }
    guard !snapshot.registrationRequested || snapshot.registrationStalled else {
      record("registration already in progress")
      return
    }
    snapshot.registrationRequested = true
    snapshot.registrationStalled = false
    cameraIssue = nil
    registrationRequestedAt = Date()
    leftAppAt = nil
    returnedAt = nil
    record("registration requested (Meta AI opens)")
    evaluate(reason: "connect")
    watchRegistration()
    Task { @MainActor [weak self] in
      do {
        try await wearables.startRegistration()
      } catch let error as RegistrationError {
        guard let self else { return }
        if error == .alreadyRegistered {
          self.record("Meta AI: already registered")
          self.finishRegistrationFlow()
          self.refresh()
        } else {
          self.lastError = "registration: \(error.description)"
          self.markRegistrationStalled(detail: Self.friendly(error))
        }
      } catch {
        guard let self else { return }
        self.lastError = "registration: \(LogSanitizer.sanitize(String(describing: error), limit: 160))"
        self.markRegistrationStalled(detail: nil)
      }
    }
  }

  private static func friendly(_ error: RegistrationError) -> String {
    switch error {
    case .metaAINotInstalled:
      L.t("Meta AI is not installed. Install it from the App Store, then try again.",
          "Meta AI yüklü değil. App Store'dan yükleyip tekrar dene.")
    case .networkUnavailable:
      L.t("No internet connection. Try again when you are online.",
          "İnternet bağlantısı yok. Bağlanınca tekrar dene.")
    case .configurationInvalid:
      L.t("Meta AI rejected AutoLoom's setup. Check that Developer Mode is on in Meta AI.",
          "Meta AI, AutoLoom'un ayarını kabul etmedi. Meta AI'da Developer Mode'un açık olduğunu kontrol et.")
    case .alreadyRegistered, .unknown:
      L.t("Meta AI could not finish connecting. Try again.", "Meta AI bağlantıyı tamamlayamadı. Tekrar dene.")
    }
  }

  private func watchRegistration() {
    registrationWatch?.cancel()
    registrationWatch = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 1_000_000_000)
        guard let self, let requestedAt = self.registrationRequestedAt else { return }
        if let wearables = self.wearables {
          // The event stream can miss a transition; the property cannot.
          self.applyRegistration(wearables.registrationState, source: "poll")
        }
        if self.snapshot.registration == .registered || self.registrationRequestedAt == nil { return }
        if GlassesConnectionReducer.registrationStalled(
          requestedAt: requestedAt, leftAppAt: self.leftAppAt, returnedAt: self.returnedAt, now: Date()) {
          self.markRegistrationStalled(detail: nil)
          return
        }
      }
    }
  }

  /// A registration Meta AI started (DAT 1.0). It is continued at once:
  /// the approval itself happens in Meta AI. Apps on DAT 0.x could not take
  /// part in this flow.
  func continueRegistration(_ request: RegistrationRequest) async {
    record("Meta AI started a registration")
    if registrationRequestedAt == nil {
      registrationRequestedAt = Date()
      snapshot.registrationRequested = true
      watchRegistration()
    }
    do {
      try await request.continueRegistration()
      record("registration continued in Meta AI")
    } catch {
      lastError = "registration request: \(LogSanitizer.sanitize(String(describing: error), limit: 120))"
      record("registration request failed")
      markRegistrationStalled(detail: nil)
    }
    evaluate(reason: "registration request")
  }

  private func markRegistrationStalled(detail: String?) {
    guard snapshot.registration != .registered else { return }
    snapshot.registrationStalled = true
    registrationRequestedAt = nil
    registrationWatch?.cancel()
    cameraIssue = detail
    record("registration: no approval from Meta AI")
    evaluate(reason: "registration stalled")
  }

  private func finishRegistrationFlow() {
    snapshot.registrationRequested = false
    snapshot.registrationStalled = false
    registrationRequestedAt = nil
    leftAppAt = nil
    returnedAt = nil
    registrationWatch?.cancel()
  }

  private func endRestoring() {
    guard snapshot.restoring else { return }
    snapshot.restoring = false
    if let wearables { applyRegistration(wearables.registrationState, source: "after launch grace") }
    if snapshot.registration != .registered, UserDefaults.standard.bool(forKey: Self.wasRegisteredKey) {
      registrationLost = true
      record("registration not restored (Developer Mode keeps one app registered at a time)")
    }
    evaluate(reason: "launch grace ended")
  }

  private func applyRegistration(_ state: RegistrationState, source: String, force: Bool = false) {
    let fact = GlassesConnectionSnapshot.Registration(state)
    guard force || fact != snapshot.registration else { return }
    let previous = snapshot.registration
    snapshot.registration = fact
    record("registration \(previous.rawValue) → \(fact.rawValue) (\(source))")
    if previous == .registered, fact != .registered, !force {
      if userForgot {
        userForgot = false
      } else {
        // Developer Mode keeps one third-party app registered at a time.
        registrationLost = true
        record("registration ended outside AutoLoom")
      }
    }
    if fact == .registered {
      let byUser = registrationRequestedAt != nil || snapshot.registrationRequested
      UserDefaults.standard.set(true, forKey: Self.wasRegisteredKey)
      registrationLost = false
      userForgot = false
      snapshot.restoring = false
      restoreTask?.cancel()
      finishRegistrationFlow()
      cameraIssue = nil
      resetBackoff()
      if byUser, previous != .registered {
        // Connecting the glasses means using their camera: the iPhone camera
        // is replaced by the Ray-Ban one (camera off stays off).
        registrationCompletions += 1
        let defaults = UserDefaults.standard
        if defaults.string(forKey: CaptureSource.defaultsKey) ?? CaptureSource.iPhoneCamera.rawValue
            == CaptureSource.iPhoneCamera.rawValue {
          defaults.set(CaptureSource.glasses.rawValue, forKey: CaptureSource.defaultsKey)
          record("camera source: Ray-Ban (after connecting)")
        }
      }
    }
    evaluate(reason: "registration \(fact.rawValue)")
  }

  // MARK: Devices and link

  /// Reads everything again from the SDK (launch, foreground, callback).
  func refresh() {
    guard let wearables else { return }
    applyRegistration(wearables.registrationState, source: "refresh")
    applyDevices(wearables.devices)
    if let id = devices.first, let device = wearables.deviceForIdentifier(id) {
      applyLink(device.linkState, source: "refresh")
    }
  }

  private func applyDevices(_ ids: [DeviceIdentifier]) {
    let changed = ids != devices
    devices = ids
    snapshot.deviceCount = ids.count
    #if canImport(MWDATMockDevice)
    snapshot.hasMockDevice = !MockDeviceKit.shared.pairedDevices.isEmpty
    #endif
    installListeners(for: ids)
    if changed { record("devices: \(ids.count)") }
    evaluate(reason: "devices")
  }

  private func installListeners(for ids: [DeviceIdentifier]) {
    guard let wearables else { return }
    let present = Set(ids)
    for (id, token) in linkTokens where !present.contains(id) {
      Task { await token.cancel() }
    }
    for (id, token) in compatibilityTokens where !present.contains(id) {
      Task { await token.cancel() }
    }
    for (id, token) in deviceStateTokens where !present.contains(id) {
      Task { await token.cancel() }
    }
    linkTokens = linkTokens.filter { present.contains($0.key) }
    compatibilityTokens = compatibilityTokens.filter { present.contains($0.key) }
    deviceStateTokens = deviceStateTokens.filter { present.contains($0.key) }
    if ids.isEmpty {
      deviceName = nil
      compatibility = "—"
      worn = nil
      hingeOpen = nil
      batteryLevel = nil
      thermal = "—"
      applyLink(nil, source: "no device")
      return
    }
    var unresolved = false
    for id in ids {
      guard let device = wearables.deviceForIdentifier(id) else {
        unresolved = true
        continue
      }
      if id == ids.first {
        deviceName = device.nameOrId()
        let current = device.compatibility()
        compatibility = String(describing: current)
        alertIfIncompatible(current)
        applyLink(device.linkState, source: "read")
      }
      if linkTokens[id] == nil {
        linkTokens[id] = device.addLinkStateListener { [weak self] state in
          Task { @MainActor [weak self] in self?.linkChanged(id: id, state: state) }
        }
      }
      if compatibilityTokens[id] == nil {
        compatibilityTokens[id] = device.addCompatibilityListener { [weak self] value in
          Task { @MainActor [weak self] in self?.compatibilityChanged(id: id, value) }
        }
      }
      // DAT 1.0: worn, folded, battery and heat, delivered at once and on
      // every change.
      if deviceStateTokens[id] == nil {
        deviceStateTokens[id] = device.addDeviceStateListener { [weak self] state in
          Task { @MainActor [weak self] in self?.deviceStateChanged(id: id, state) }
        }
      }
    }
    // A device the SDK cannot resolve yet gets its listeners on a later pass.
    listenerRetryTask?.cancel()
    if unresolved {
      listenerRetryTask = Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        guard let self, !Task.isCancelled else { return }
        self.installListeners(for: self.devices)
      }
    }
  }

  private func linkChanged(id: DeviceIdentifier, state: LinkState) {
    guard id == devices.first else { return }
    applyLink(state, source: "event")
  }

  private func applyLink(_ state: LinkState?, source: String) {
    let fact: GlassesConnectionSnapshot.Link = state.map { GlassesConnectionSnapshot.Link($0) } ?? .unknown
    guard fact != snapshot.link else { return }
    let wasConnected = snapshot.link == .connected
    snapshot.link = fact
    record("link \(fact.rawValue) (\(source))")
    if fact == .connected, !wasConnected {
      // A fresh link: try the camera at once. A link that dropped and came
      // back (the power cycle the screen asked for) is judged afresh.
      lastLinkedAt = Date()
      if snapshot.sessionProblem?.blocksAutomaticRetry == true || snapshot.sessionProblem == .glassesAppUnavailable {
        record("glasses back: refusals cleared")
        stream?.clearSessionProblem()
        snapshot.sessionProblem = nil
      }
      resetBackoff()
    }
    evaluate(reason: "link \(fact.rawValue)")
  }

  private func deviceStateChanged(id: DeviceIdentifier, _ state: DeviceState) {
    guard id == devices.first else { return }
    let newWorn: Bool? = switch state.donState {
    case .donned: true
    case .doffed: false
    case .unknown: nil
    }
    let newHinge: Bool? = switch state.hingeState {
    case .open: true
    case .closed: false
    case .unknown: nil
    }
    if newWorn != worn { record(newWorn.map { $0 ? "glasses worn" : "glasses taken off" } ?? "worn state unknown") }
    if newHinge != hingeOpen, newHinge == false { record("glasses folded") }
    worn = newWorn
    hingeOpen = newHinge
    batteryLevel = state.batteryLevel
    thermal = String(describing: state.thermalLevel)
  }

  /// The camera's device session (DAT 1.0), as part of the connection.
  private func sessionStateChanged(_ state: DeviceSessionState) {
    let fact: GlassesConnectionSnapshot.Session = switch state {
    case .idle: .none
    case .starting: .starting
    case .started: .started
    case .paused: .paused
    case .stopping: .stopping
    case .stopped: .stopped
    }
    guard fact != snapshot.session else { return }
    snapshot.session = fact
    record("session \(fact.rawValue)")
    evaluate(reason: "session \(fact.rawValue)")
  }

  private func sessionProblemChanged(_ problem: GlassesSessionProblem?) {
    guard problem != snapshot.sessionProblem else { return }
    snapshot.sessionProblem = problem
    if let problem {
      record("session problem: \(ConnectionLayerReport.problemText(problem))")
      if problem.blocksAutomaticRetry {
        // Retrying cannot help until the user acts: no busy attempts.
        attemptTask?.cancel()
        attemptTask = nil
      }
    }
    evaluate(reason: "session problem")
  }

  private func compatibilityChanged(id: DeviceIdentifier, _ value: Compatibility) {
    guard id == devices.first else { return }
    compatibility = String(describing: value)
    record("compatibility \(compatibility)")
    alertIfIncompatible(value)
  }

  /// The two ends that can be too old: the glasses' firmware (update in Meta
  /// AI), or this app's Meta toolkit, which only a new AutoLoom build fixes.
  /// Both are said plainly instead of retrying a camera that cannot start.
  private func alertIfIncompatible(_ value: Compatibility) {
    let issue: GlassesConnectionSnapshot.CompatibilityIssue?
    switch value {
    case .deviceUpdateRequired:
      issue = .glassesUpdate
      if snapshot.compatibilityIssue != .glassesUpdate {
        userAlert = L.t("Your glasses need a software update in Meta AI before AutoLoom can use them.",
                        "AutoLoom'un kullanabilmesi için gözlüğün Meta AI'da güncellenmesi gerekiyor.")
      }
    case .sdkUpdateRequired:
      issue = .appUpdate
      if snapshot.compatibilityIssue != .appUpdate {
        userAlert = L.t(
          "Your glasses need a newer AutoLoom build (Meta's toolkit in this build, DAT \(GlassesSDKInfo.datVersion), is too old for them). The iPhone camera still works.",
          "Gözlüğün daha yeni bir AutoLoom sürümü istiyor (bu sürümdeki Meta araç seti, DAT \(GlassesSDKInfo.datVersion), onun için eski). iPhone kamerası çalışmaya devam eder.")
      }
    default:
      issue = nil
    }
    guard issue != snapshot.compatibilityIssue else { return }
    snapshot.compatibilityIssue = issue
    evaluate(reason: "compatibility")
  }

  private func activeDeviceChanged(_ active: Bool) {
    guard active != snapshot.activeDevice else { return }
    snapshot.activeDevice = active
    record(active ? "active device selected" : "active device dropped")
    if active { resetBackoff() }
    evaluate(reason: "active device")
  }

  // MARK: Camera

  private func cameraIssueChanged(_ issue: StreamSessionViewModel.GlassesIssue?) {
    switch issue {
    case .permissionNeeded:
      snapshot.permission = .denied
      cameraIssue = nil
    case .hingesClosed:
      cameraIssue = L.t("The glasses are folded.", "Gözlük katlı.")
    case .thermal:
      cameraIssue = L.t("The glasses are warm; the camera waits until they cool down.",
                        "Gözlük ısındı; kamera soğuyana kadar bekliyor.")
    case .sdkUnavailable, .reconnecting, nil:
      cameraIssue = nil
    }
    evaluate(reason: "camera issue")
  }

  private func streamStatusChanged(_ status: StreamingStatus) {
    let fact: GlassesConnectionSnapshot.Stream
    switch status {
    case .streaming: fact = .streaming
    case .waiting: fact = .waiting
    case .stopped: fact = .stopped
    }
    guard fact != snapshot.stream else { return }
    snapshot.stream = fact
    record("stream \(fact.rawValue)")
    startWatchdog?.cancel()
    switch fact {
    case .streaming:
      failures = 0
      reconnectAttempts = 0
      snapshot.cameraFailure = nil
      snapshot.permission = .granted
    case .waiting:
      armStartWatchdog()
    case .stopped:
      if snapshot.cameraWanted, phase.isLinked, stream?.isSwitchingTransport != true {
        // Stopped while it should run: restarts back off.
        failures += 1
        nextAttemptAt = Date().addingTimeInterval(GlassesConnectionReducer.retryDelay(afterFailures: failures))
      }
    }
    evaluate(reason: "stream \(fact.rawValue)")
  }

  private func armStartWatchdog() {
    startWatchdog = Task { @MainActor [weak self] in
      try? await Task.sleep(nanoseconds: UInt64(GlassesConnectionReducer.cameraStartTimeout * 1_000_000_000))
      guard let self, !Task.isCancelled, self.snapshot.stream == .waiting, self.snapshot.cameraWanted,
            self.phase.isLinked, let stream = self.stream, !stream.isSwitchingTransport else { return }
      self.record("camera did not start within \(Int(GlassesConnectionReducer.cameraStartTimeout)) s; restarting it")
      self.failures += 1
      self.nextAttemptAt = Date().addingTimeInterval(GlassesConnectionReducer.retryDelay(afterFailures: self.failures))
      self.snapshot.cameraFailure = "start timeout"
      await stream.stopSession()
      self.evaluate(reason: "start watchdog")
    }
  }

  private func resetBackoff() {
    failures = 0
    nextAttemptAt = .distantPast
    // A wait scheduled with the old delay gives way to an attempt now.
    attemptTask?.cancel()
    attemptTask = nil
  }

  // MARK: Evaluation

  private func evaluate(reason: String) {
    let newPhase = GlassesConnectionReducer.phase(for: snapshot)
    if newPhase != phase {
      let old = phase
      phase = newPhase
      record("\(old.rawValue) → \(newPhase.rawValue) (\(reason))")
      // "Ray-Ban Connected" only when the glasses are usable.
      if newPhase.isLinked, !old.isLinked, !newPhase.needsUserAction { noteLinked() }
      if newPhase == .ready { lastReadyAt = Date() }
    }
    scheduleCameraStart()
  }

  private func noteLinked() {
    let now = Date()
    guard now.timeIntervalSince(lastConnectedNoticeAt) > GlassesConnectionReducer.connectedNoticeInterval else { return }
    lastConnectedNoticeAt = now
    connectedNotice += 1
  }

  /// Starts the camera once the glasses are linked, never twice at once,
  /// with a bounded backoff after failures.
  private func scheduleCameraStart() {
    // Versions that do not match, or glasses that keep refusing, wait for
    // the user (an update, a power cycle, Try Again) instead of retrying.
    guard snapshot.cameraWanted, phase.isLinked, stream != nil, wearables != nil,
          snapshot.compatibilityIssue == nil, snapshot.sessionProblem?.blocksAutomaticRetry != true else {
      attemptTask?.cancel()
      attemptTask = nil
      return
    }
    guard snapshot.stream == .stopped, !startInFlight, stream?.isSwitchingTransport != true else { return }
    // A denied permission waits for Try Again instead of reopening Meta AI.
    if snapshot.permission == .denied, !permissionRequestAllowed { return }
    guard attemptTask == nil else { return }
    let delay = max(0, nextAttemptAt.timeIntervalSinceNow)
    attemptTask = Task { @MainActor [weak self] in
      if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
      guard let self, !Task.isCancelled else { return }
      self.attemptTask = nil
      await self.attemptCameraStart()
    }
  }

  private func attemptCameraStart() async {
    guard snapshot.cameraWanted, phase.isLinked, snapshot.stream == .stopped, !startInFlight,
          let wearables, let stream else { return }
    startInFlight = true
    defer {
      startInFlight = false
      evaluate(reason: "attempt finished")
    }
    reconnectAttempts += 1
    nextAttemptAt = Date().addingTimeInterval(GlassesConnectionReducer.retryDelay(afterFailures: failures))
    record("camera start attempt \(reconnectAttempts)")
    do {
      snapshot.permission = .checking
      evaluate(reason: "checking permission")
      var status = try await wearables.checkPermissionStatus(.camera)
      if status != .granted {
        // Meta AI opens for the request, which only works on screen.
        guard permissionRequestAllowed, isForeground else {
          snapshot.permission = .denied
          if permissionRequestAllowed {
            // In the background: ask once the app is on screen again.
            failures += 1
            nextAttemptAt = Date().addingTimeInterval(GlassesConnectionReducer.retryDelay(afterFailures: failures))
          }
          record("camera permission not granted")
          return
        }
        permissionRequestAllowed = false
        snapshot.permission = .requesting
        evaluate(reason: "requesting permission")
        record("asking Meta AI for camera permission")
        status = try await wearables.requestPermission(.camera)
      }
      guard status == .granted else {
        snapshot.permission = .denied
        record("camera permission denied")
        return
      }
      snapshot.permission = .granted
      guard snapshot.cameraWanted, snapshot.stream == .stopped else { return }
      stream.applyStreamProfileIfNeeded()
      record("camera start (\(stream.activeTransport.shortLabel))")
      await stream.startSession()
    } catch let error as PermissionError {
      snapshot.permission = .unknown
      failures += 1
      nextAttemptAt = Date().addingTimeInterval(GlassesConnectionReducer.retryDelay(afterFailures: failures))
      lastError = "permission check: \(error.description)"
      if error == .metaAINotInstalled {
        userAlert = L.t("Meta AI is not installed on this iPhone.", "Bu iPhone'da Meta AI yüklü değil.")
      }
      record("permission check failed (\(error.description)); next try in \(Int(GlassesConnectionReducer.retryDelay(afterFailures: failures))) s")
    } catch {
      snapshot.permission = .unknown
      failures += 1
      nextAttemptAt = Date().addingTimeInterval(GlassesConnectionReducer.retryDelay(afterFailures: failures))
      lastError = "camera start: \(LogSanitizer.sanitize(String(describing: error), limit: 160))"
      record("camera start failed; next try in \(Int(GlassesConnectionReducer.retryDelay(afterFailures: failures))) s")
    }
  }

  // MARK: Diagnostics

  private func record(_ text: String) {
    let line = LogSanitizer.sanitize(text, limit: 240)
    transitions.append(Transition(at: Date(), text: line))
    if transitions.count > 60 { transitions.removeFirst(transitions.count - 60) }
    NSLog("[RayBan] %@", line)
  }

  /// Every layer of the connection as measured now, for the layer table
  /// (Settings → Developer → Ray-Ban connection).
  func layerFacts(voice: GlassifAIRealtimeSession?) -> ConnectionLayerFacts {
    let metrics = FrameStore.shared.snapshot()
    let route = AudioRouteMonitor.shared
    route.refresh()
    var facts = ConnectionLayerFacts()
    facts.bluetooth = snapshot.bluetooth
    facts.sdkConfigured = snapshot.sdkConfigured
    facts.registration = snapshot.registration.rawValue
    facts.link = snapshot.link.rawValue
    facts.compatibility = compatibility
    facts.worn = worn
    facts.hingeOpen = hingeOpen
    facts.battery = batteryLevel
    facts.sessionState = snapshot.session.rawValue
    facts.sessionProblem = snapshot.sessionProblem
    facts.cameraWanted = snapshot.cameraWanted
    facts.cameraPermission = snapshot.permission.rawValue
    facts.streamState = snapshot.stream.rawValue
    let glassesFrames = metrics.source == FrameSourceKind.glasses.rawValue
    facts.measuredFPS = glassesFrames ? metrics.measuredFPS : 0
    facts.lastFrameAgeMs = metrics.lastGlassesFrameAgeMs
    facts.frameSource = metrics.source == "—" ? "—"
      : "\(metrics.source) · \(metrics.inputResolution)" + (metrics.lastFrameAgeMs.map { " · \($0) ms" } ?? "")
    facts.microphone = route.inputSummary
    facts.microphoneIsGlasses = route.inputs.contains { $0.type == "Bluetooth HFP" }
    facts.output = route.outputSummary
    if let voice {
      facts.voiceState = String(describing: voice.state)
      facts.voiceActive = voice.isActive
      facts.dataChannelOpen = voice.isDataChannelOpen
    }
    return facts
  }

  /// A sanitized report for "Copy connection report": states, counts and
  /// errors, never identifiers, tokens or configuration values.
  func diagnosticsReport() -> String {
    let config = DATConfigurationAudit.current
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    let warnings = config.warnings
    let linkedAt: String = lastLinkedAt.map { formatter.string(from: $0) } ?? "never"
    let readyAt: String = lastReadyAt.map { formatter.string(from: $0) } ?? "never"
    let wornText: String = worn.map { $0 ? "yes" : "no" } ?? "—"
    let openText: String = hingeOpen.map { $0 ? "yes" : "no" } ?? "—"
    let batteryText: String = batteryLevel.map { "\($0)%" } ?? "—"
    let problemText: String = snapshot.sessionProblem.map { ConnectionLayerReport.problemText($0) } ?? "none"
    var lines: [String] = [
      "AutoLoom Ray-Ban connection report",
      "App \(AppInfo.version) (\(AppInfo.build)) · commit \(AppInfo.commit)",
      "DAT \(GlassesSDKInfo.datVersion) · SDK configured: \(snapshot.sdkConfigured ? "yes" : "no")\(configureError.map { " (\($0))" } ?? "")",
      "Config: \(config.summary)",
      "Config problems: \(config.problems.isEmpty ? "none" : config.problems.joined(separator: "; "))",
      "Config warnings: \(warnings.isEmpty ? "none" : warnings.joined(separator: "; "))",
      "Signing: \(ProvisioningSummary.read().summary())",
      "Bluetooth: \(snapshot.bluetooth.rawValue)",
      "Phase: \(phase.rawValue)",
      "Registration: \(snapshot.registration.rawValue)\(registrationLost ? " (not restored after launch)" : "")",
      "Devices: \(devices.count) · active device: \(snapshot.activeDevice ? "yes" : "no") · device: \(deviceHash)",
      "Link: \(snapshot.link.rawValue) · compatibility: \(compatibility) · last linked: \(linkedAt)",
      "Glasses: worn \(wornText) · open \(openText) · battery \(batteryText) · thermal \(thermal)",
      "Session: \(snapshot.session.rawValue) · problem: \(problemText) · last session error: \(stream?.lastSessionError ?? "none")",
      "Camera chosen: \(snapshot.cameraWanted ? "yes" : "no") · permission: \(snapshot.permission.rawValue) · stream: \(snapshot.stream.rawValue) · frames: \(snapshot.hasFrames ? "yes" : "no") · last ready: \(readyAt)",
      "Transport: \(stream?.activeTransport.shortLabel ?? "—") · last stream state: \(stream?.lastStreamState ?? "—")",
      "Camera-safe audio (no glasses microphone with the Ray-Ban camera): \(GlassesCameraAudio.keepsHandsFreeClosed ? "on" : "off")",
      "Microphone and camera order: \(stream?.audioOrderNote ?? "—")",
      "Start attempts since last stream: \(reconnectAttempts) · failures: \(failures)",
      "Last error: \(lastError ?? "none")",
      "Transitions:",
    ]
    for transition in transitions.suffix(40) {
      lines.append("  \(formatter.string(from: transition.at)) \(transition.text)")
    }
    let sdkLog = DATLogReader.recentLines(limit: 25)
    lines.append("Meta SDK log (matching lines, identifiers masked): \(sdkLog.isEmpty ? "none found" : "")")
    for line in sdkLog { lines.append("  \(line)") }
    return lines.map { LogSanitizer.sanitize($0, limit: 400) }.joined(separator: "\n")
  }
}
