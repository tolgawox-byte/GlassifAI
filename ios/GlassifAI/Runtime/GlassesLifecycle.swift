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
    if let error = metrics.lastDecodeError { detail += " · last decode error \(error)" }
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
