import Foundation
import UIKit

/// Where the Ray-Ban vision pipeline stands. Vision works in the first three
/// states: the AI reads decoded glasses sample buffers (FrameStore), never
/// the phone's screen, so a locked screen only removes the preview.
enum GlassesPipelineState: String, Equatable {
  case foregroundActive = "ForegroundActive"
  case backgroundStreaming = "BackgroundStreaming"
  case screenLockedStreaming = "ScreenLockedStreaming"
  /// The app is in the background or locked and glasses frames stopped.
  case suspended = "Suspended"
  /// No glasses stream is running.
  case disconnected = "Disconnected"

  var allowsVision: Bool {
    self == .foregroundActive || self == .backgroundStreaming || self == .screenLockedStreaming
  }

  /// Frames older than this mean the stream stopped delivering.
  static let staleAfterMs = 3_000

  static func derive(
    appActive: Bool,
    screenLocked: Bool,
    streamRunning: Bool,
    lastSampleAgeMs: Int?
  ) -> GlassesPipelineState {
    guard streamRunning else { return .disconnected }
    if appActive { return .foregroundActive }
    let delivering = lastSampleAgeMs.map { $0 < staleAfterMs } ?? false
    guard delivering else { return .suspended }
    return screenLocked ? .screenLockedStreaming : .backgroundStreaming
  }
}

/// Settings → Camera & Ray-Ban → "Continue vision with the screen locked".
enum LockedScreenVision {
  static let defaultsKey = "autoloom.vision.lockedScreen"

  /// On unless the user turned it off.
  static var isEnabled: Bool {
    UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
  }

  /// Meta DAT 0.5: the HEVC (hvc1) transport keeps streaming while the app
  /// is in the background; the default raw transport pauses.
  static func isSupported(transport: GlassesVideoTransport?) -> Bool {
    transport == .hevc
  }

  static func statusLine(transport: GlassesVideoTransport?) -> String {
    guard isEnabled else { return "off (Settings)" }
    return isSupported(transport: transport)
      ? "on (HEVC keeps streaming; physical test required)"
      : "unavailable on the raw transport"
  }

  /// What the voice model is told when a Ray-Ban question arrives while the
  /// phone is locked and the setting is off.
  static let offReason =
    "Vision with the screen locked is turned off in Settings (Camera & Ray-Ban), so nothing can be seen until the phone is unlocked."
}

/// Bounded recovery when the Ray-Ban stream says "streaming" but no fresh
/// image reaches the frame store. It never answers with an older frame; it
/// only rebuilds the decoder or, on screen, restarts the stream, within
/// limits. In the background the stream is never restarted (Meta documents
/// that streaming continues there, not that a new start works), so a locked
/// phone falls back to a glasses still photo instead.
enum RayBanStallPolicy {
  enum Action: Equatable {
    case none
    case restartDecoder(swapMode: Bool)
    case restartStream(reason: String)
  }

  struct Input: Equatable {
    var streaming: Bool
    var hevc: Bool
    var background: Bool
    var recording: Bool
    /// Time since the stream reached "streaming".
    var streamingFor: TimeInterval
    var lastSampleAgeMs: Int?
    var lastImageAgeMs: Int?
    var keyframeWaitMs: Int?
    /// Decoder rebuilds since the last image.
    var decoderRestarts: Int
    var lastDecoderRestartAt: Date?
    var streamRestarts: [Date]
    var now: Date
  }

  /// The transport watchdog judges the first seconds of a stream.
  static let startupGrace: TimeInterval = 10
  static let noSamplesMs = 10_000
  static let noImageMs = 3_000
  static let keyframeWaitLimitMs = 8_000
  static let decoderRestartSpacing: TimeInterval = 5
  static let maxStreamRestarts = 3
  static let streamRestartWindow: TimeInterval = 600

  static func decide(_ input: Input) -> Action {
    guard input.streaming, input.streamingFor >= startupGrace else { return .none }
    let restartsInWindow = input.streamRestarts.filter { input.now.timeIntervalSince($0) < streamRestartWindow }
    // A recording keeps its stream; a restart would cut the file.
    let mayRestartStream = !input.background && !input.recording && restartsInWindow.count < maxStreamRestarts
    let sampleAge = input.lastSampleAgeMs ?? Int.max
    let imageAge = input.lastImageAgeMs ?? Int.max
    // 1. Nothing arrives at all.
    if sampleAge >= noSamplesMs {
      guard mayRestartStream else { return .none }
      return .restartStream(reason: "no Ray-Ban samples for \(noSamplesMs / 1_000) s")
    }
    guard sampleAge < 2_000, imageAge >= noImageMs, input.hevc else { return .none }
    // 2. Only P-frames the decoder cannot use: a new stream starts with a
    // keyframe (DAT 0.5 has no keyframe request).
    if let wait = input.keyframeWaitMs {
      guard wait >= keyframeWaitLimitMs, mayRestartStream else { return .none }
      return .restartStream(reason: "no keyframe for \(wait / 1_000) s")
    }
    // 3. Samples arrive and the decoder is not waiting, yet no image comes
    // out: rebuild it, in the other mode after the first rebuild.
    if let last = input.lastDecoderRestartAt, input.now.timeIntervalSince(last) < decoderRestartSpacing {
      return .none
    }
    return .restartDecoder(swapMode: input.decoderRestarts >= 1)
  }
}

/// Watches the app lifecycle, the screen lock and the glasses stream, and
/// records every change of `GlassesPipelineState` with the frame counters,
/// so a physical lock-screen test shows exactly where frames stop.
@MainActor
final class GlassesLifecycleMonitor: ObservableObject {
  static let shared = GlassesLifecycleMonitor()

  struct Transition: Identifiable, Equatable {
    let id = UUID()
    let at: Date
    let from: GlassesPipelineState
    let to: GlassesPipelineState
    let detail: String
  }

  @Published private(set) var state: GlassesPipelineState = .disconnected
  @Published private(set) var transitions: [Transition] = []
  @Published private(set) var screenLocked = false

  /// Supplied by the camera screen: whether a glasses stream runs, and its
  /// transport ("HEVC (hvc1)" or "raw").
  var isStreamRunning: @MainActor () -> Bool = { false }
  var transportLabel: @MainActor () -> String = { "—" }

  private var observers: [NSObjectProtocol] = []
  private var loop: Task<Void, Never>?

  private init() {}

  func start() {
    guard observers.isEmpty else { return }
    let center = NotificationCenter.default
    let names: [(Notification.Name, String)] = [
      (UIApplication.didEnterBackgroundNotification, "app entered background"),
      (UIApplication.willEnterForegroundNotification, "app entering foreground"),
      (UIApplication.didBecomeActiveNotification, "app active"),
      (UIApplication.willResignActiveNotification, "app resigning active"),
    ]
    for (name, reason) in names {
      observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor in self?.evaluate(reason: reason) }
      })
    }
    // Protected data becomes unavailable when a passcode-locked phone locks.
    observers.append(center.addObserver(
      forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.screenLocked = true
        self?.evaluate(reason: "screen locked")
      }
    })
    observers.append(center.addObserver(
      forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor in
        self?.screenLocked = false
        self?.evaluate(reason: "screen unlocked")
      }
    })
    loop = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 2_000_000_000)
        self?.evaluate(reason: nil)
      }
    }
    evaluate(reason: "started")
  }

  func evaluate(reason: String?) {
    let metrics = FrameStore.shared.snapshot()
    let appActive = UIApplication.shared.applicationState == .active
    if appActive { screenLocked = false }
    let next = GlassesPipelineState.derive(
      appActive: appActive,
      screenLocked: screenLocked,
      streamRunning: isStreamRunning(),
      lastSampleAgeMs: metrics.lastSampleAgeMs)
    guard next != state else { return }
    var detail = "\(reason ?? "frames") · \(transportLabel()) · samples \(metrics.compressedSamples + metrics.rawSamples)"
    detail += " · decoded \(metrics.decodedFrames) · bg samples \(metrics.backgroundSamples)"
    detail += " · bg decoded \(metrics.backgroundDecoded) · bg failures \(metrics.backgroundFailures)"
    detail += " · decoder \(metrics.softwareDecode ? "software" : "hardware")"
    if let wait = metrics.keyframeWaitMs { detail += " · keyframe wait \(wait) ms" }
    if let error = metrics.lastDecodeError { detail += " · last decode error \(error)" }
    if metrics.recoveries > 0 { detail += " · recoveries \(metrics.recoveries) (\(metrics.lastRecovery))" }
    transitions.append(Transition(at: Date(), from: state, to: next, detail: detail))
    if transitions.count > 40 { transitions.removeFirst(transitions.count - 40) }
    NSLog("[AutoLoom] glasses pipeline %@ → %@ (%@)", state.rawValue, next.rawValue, detail)
    state = next
  }

  /// An honest sentence for the voice model when a visual question arrives
  /// and no fresh glasses frame exists.
  func unavailableReason(transportIsRaw: Bool) -> String? {
    let metrics = FrameStore.shared.snapshot()
    switch state {
    case .suspended:
      if transportIsRaw {
        return "The Ray-Ban stream is on the raw transport, which Meta pauses while the phone is locked or the app is in the background. Settings, Camera and Ray-Ban, Video transport HEVC keeps it running."
      }
      if metrics.backgroundSamples > 0 && metrics.backgroundDecoded == 0 {
        let code = metrics.lastDecodeError.map { " (decoder error \($0))" } ?? ""
        return "Frames still arrive from the glasses while the phone is locked, but the iPhone could not decode them\(code)."
      }
      return "The glasses stopped sending frames while the phone is locked or the app is in the background."
    case .disconnected:
      return "The Ray-Ban camera stream is not running."
    default:
      return nil
    }
  }
}
