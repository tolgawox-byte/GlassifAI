import AVFoundation
import Foundation

/// Which microphone/speaker the voice conversation should use. Independent of
/// the camera source: a connected Ray-Ban camera does not imply that its
/// microphone and speakers are the active audio route.
enum AudioRoutePreference: String, CaseIterable, Identifiable {
  case automatic = "auto"
  case glasses = "glasses"
  case iPhone = "iphone"

  static let defaultsKey = "autoloom.audio.route"

  var id: String { rawValue }

  var label: String {
    switch self {
    case .automatic: "Automatic"
    case .glasses: "Glasses"
    case .iPhone: "iPhone"
    }
  }

  static var current: AudioRoutePreference {
    AudioRoutePreference(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .automatic
  }

  /// Automatic keeps the original behaviour: glasses audio when the glasses
  /// are the camera (or the camera is off), iPhone audio in iPhone-camera mode.
  func prefersGlassesAudio(for captureSource: CaptureSource) -> Bool {
    switch self {
    case .automatic: captureSource != .iPhoneCamera
    case .glasses: true
    case .iPhone: false
    }
  }
}

/// Publishes the live audio route and reacts to interruptions (phone calls,
/// Siri), Bluetooth route changes, and media-server resets.
@MainActor
final class AudioRouteMonitor: ObservableObject {
  static let shared = AudioRouteMonitor()

  struct Port: Equatable {
    let name: String
    let type: String
  }

  @Published private(set) var inputs: [Port] = []
  @Published private(set) var outputs: [Port] = []
  @Published private(set) var availableInputs: [Port] = []
  @Published private(set) var isInterrupted = false
  @Published private(set) var lastEvent = "—"
  /// Name the Meta SDK reports for the connected glasses, used to pick the
  /// matching Bluetooth hands-free port.
  var glassesName: String?

  var onInterruptionEnded: (() -> Void)?
  var onMediaServicesReset: (() -> Void)?

  private var observers: [NSObjectProtocol] = []

  private init() {}

  func start() {
    guard observers.isEmpty else { refresh(); return }
    let center = NotificationCenter.default
    let session = AVAudioSession.sharedInstance()
    observers.append(center.addObserver(
      forName: AVAudioSession.routeChangeNotification, object: session, queue: .main
    ) { [weak self] notification in
      let reason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
        .flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
      Task { @MainActor in
        self?.lastEvent = "Route changed: \(Self.describe(reason))"
        self?.refresh()
      }
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.interruptionNotification, object: session, queue: .main
    ) { [weak self] notification in
      let type = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
        .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
      let options = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
        .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
      Task { @MainActor in
        self?.handleInterruption(type: type, options: options)
      }
    })
    observers.append(center.addObserver(
      forName: AVAudioSession.mediaServicesWereResetNotification, object: session, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.lastEvent = "Audio services were reset"
        self?.onMediaServicesReset?()
        self?.refresh()
      }
    })
    refresh()
  }

  func refresh() {
    let session = AVAudioSession.sharedInstance()
    inputs = session.currentRoute.inputs.map { Port(name: $0.portName, type: Self.describe($0.portType)) }
    outputs = session.currentRoute.outputs.map { Port(name: $0.portName, type: Self.describe($0.portType)) }
    availableInputs = (session.availableInputs ?? []).map { Port(name: $0.portName, type: Self.describe($0.portType)) }
  }

  var inputSummary: String {
    inputs.isEmpty ? "—" : inputs.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")
  }

  var outputSummary: String {
    outputs.isEmpty ? "—" : outputs.map { "\($0.name) (\($0.type))" }.joined(separator: ", ")
  }

  var isUsingBluetoothAudio: Bool {
    inputs.contains { $0.type.hasPrefix("Bluetooth") } || outputs.contains { $0.type.hasPrefix("Bluetooth") }
  }

  private func handleInterruption(type: AVAudioSession.InterruptionType?, options: AVAudioSession.InterruptionOptions) {
    switch type {
    case .began:
      isInterrupted = true
      lastEvent = "Audio interrupted (call, Siri, or another app)"
    case .ended:
      isInterrupted = false
      lastEvent = options.contains(.shouldResume) ? "Interruption ended, resuming" : "Interruption ended"
      if options.contains(.shouldResume) {
        try? AVAudioSession.sharedInstance().setActive(true)
      }
      onInterruptionEnded?()
    default:
      break
    }
    refresh()
  }

  /// Picks the glasses' hands-free input without grabbing another Bluetooth
  /// headset. Meta-named ports win; an unnamed port is only used when it is
  /// the only hands-free device, so AirPods are never chosen by accident.
  nonisolated static func preferredGlassesInput(
    from available: [AVAudioSessionPortDescription]?,
    glassesName: String? = nil
  ) -> AVAudioSessionPortDescription? {
    let handsFree = (available ?? []).filter { $0.portType == .bluetoothHFP }
    if let named = handsFree.first(where: { isGlassesPortName($0.portName, glassesName: glassesName) }) {
      return named
    }
    return handsFree.count == 1 ? handsFree.first : nil
  }

  nonisolated static func isGlassesPortName(_ name: String, glassesName: String? = nil) -> Bool {
    let lower = name.lowercased()
    if let glassesName, !glassesName.isEmpty, lower.contains(glassesName.lowercased()) { return true }
    return ["ray-ban", "rayban", "ray ban", "meta", "oakley"].contains { lower.contains($0) }
  }

  private static func describe(_ type: AVAudioSession.Port) -> String {
    switch type {
    case .bluetoothHFP: "Bluetooth HFP"
    case .bluetoothA2DP: "Bluetooth A2DP"
    case .bluetoothLE: "Bluetooth LE"
    case .builtInMic: "iPhone mic"
    case .builtInSpeaker: "iPhone speaker"
    case .builtInReceiver: "iPhone receiver"
    case .headphones: "Headphones"
    case .headsetMic: "Headset mic"
    case .carAudio: "CarPlay"
    case .airPlay: "AirPlay"
    case .usbAudio: "USB audio"
    default: type.rawValue
    }
  }

  private static func describe(_ reason: AVAudioSession.RouteChangeReason?) -> String {
    switch reason {
    case .newDeviceAvailable: "device connected"
    case .oldDeviceUnavailable: "device disconnected"
    case .categoryChange: "category change"
    case .override: "override"
    case .wakeFromSleep: "wake from sleep"
    case .noSuitableRouteForCategory: "no suitable route"
    case .routeConfigurationChange: "configuration change"
    default: "other"
    }
  }
}
