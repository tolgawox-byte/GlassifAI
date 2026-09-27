import Foundation
import QuartzCore
import UIKit

/// When Live Vision may send a new scene description. Pure functions, so the
/// adaptive sampling can be unit tested.
enum LiveVisionPolicy {
  /// Never more often than this (seconds), even when the view keeps changing.
  static let minimumInterval: TimeInterval = 6
  /// Mean thumbnail difference (0…255) that counts as "the view changed".
  static let sceneChangeThreshold = 14.0
  /// A stable view is refreshed at most this often.
  static let heartbeatInterval: TimeInterval = 45
  static let maxMinutesKey = "autoloom.liveVision.maxMinutes"
  static let defaultMaxMinutes = 10
  static let maxMinuteChoices = [5, 10, 20, 30]

  static var maxDuration: TimeInterval {
    let stored = UserDefaults.standard.integer(forKey: maxMinutesKey)
    return TimeInterval((stored > 0 ? stored : defaultMaxMinutes) * 60)
  }

  /// Seconds between updates for the current device conditions, or nil to
  /// pause (critical thermal state).
  static func interval(
    thermal: ProcessInfo.ThermalState,
    batteryLevel: Float,
    charging: Bool
  ) -> TimeInterval? {
    switch thermal {
    case .critical: return nil
    case .serious: return minimumInterval * 2.5
    default: break
    }
    if !charging, batteryLevel >= 0, batteryLevel < 0.2 { return minimumInterval * 2 }
    return minimumInterval
  }

  static func shouldUpdate(sceneDifference: Double?, sinceLast: TimeInterval?, interval: TimeInterval) -> Bool {
    guard let sinceLast else { return true }
    guard sinceLast >= interval else { return false }
    if let sceneDifference, sceneDifference >= sceneChangeThreshold { return true }
    return sinceLast >= heartbeatInterval
  }
}

/// Live Vision ("start live vision", "keep looking"): while a conversation
/// runs, the voice model receives short descriptions of the current view as
/// silent context, so follow-up questions work without asking for the camera
/// each time. Specific questions still go through the normal vision path with
/// a fresh, full-quality frame.
@MainActor
final class LiveVisionController: ObservableObject {
  static let shared = LiveVisionController()

  enum Status: Equatable {
    case off
    case watching
    case describing
    case paused(String)

    var label: String {
      switch self {
      case .off: "Off"
      case .watching: "Watching"
      case .describing: "Looking"
      case .paused(let reason): "Paused — \(reason)"
      }
    }
  }

  @Published private(set) var status: Status = .off
  @Published private(set) var startedAt: Date?
  @Published private(set) var updateCount = 0
  @Published private(set) var skippedStable = 0
  @Published private(set) var lastSummary: String?
  @Published private(set) var lastUpdateAt: Date?
  @Published private(set) var lastError: String?
  @Published private(set) var lastStopReason: String?

  var isActive: Bool { status != .off }

  /// Delivers a note to the live voice session without having it spoken.
  var contextSink: (String) -> Bool = { EmbeddedCodexBridge.appendContext($0, speakable: false) }
  /// Whether a voice conversation is running (supplied by the call screen).
  var isVoiceActive: () -> Bool = { false }

  private var loop: Task<Void, Never>?
  private var lastThumbnail: [UInt8]?
  private var lastSentAt: CFTimeInterval?
  private var nextCheckAt: CFTimeInterval?
  private var inFlight = false

  private init() {}

  /// Starts Live Vision and returns what the voice model should tell the user.
  func start() -> String {
    let orchestrator = AssistantOrchestrator.shared
    guard orchestrator.captureSource() != .off else {
      return "Live vision needs a camera, but the camera is turned off in the app. The user can switch the camera to Ray-Ban or iPhone."
    }
    guard isVoiceActive() else {
      return "Live vision works during a voice conversation. Start a conversation first."
    }
    if isActive {
      return "Live vision is already on."
    }
    UIDevice.current.isBatteryMonitoringEnabled = true
    status = .watching
    startedAt = Date()
    updateCount = 0
    skippedStable = 0
    lastSummary = nil
    lastUpdateAt = nil
    lastError = nil
    lastStopReason = nil
    lastThumbnail = nil
    lastSentAt = nil
    nextCheckAt = nil
    loop?.cancel()
    loop = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let self, !Task.isCancelled else { return }
        await self.tick()
      }
    }
    let minutes = Int(LiveVisionPolicy.maxDuration / 60)
    return "Live vision is on. You will receive short background notes about the view when it changes, for up to \(minutes) minutes. Confirm briefly; the user can say stop live vision to end it."
  }

  /// Stops Live Vision. Returns what the voice model should tell the user.
  @discardableResult
  func stop(reason: String) -> String {
    guard isActive else { return "Live vision was not on." }
    loop?.cancel()
    loop = nil
    inFlight = false
    status = .off
    lastStopReason = reason
    return "Live vision is off."
  }

  private func tick() async {
    guard isActive, !inFlight else { return }
    if let startedAt, Date().timeIntervalSince(startedAt) >= LiveVisionPolicy.maxDuration {
      stop(reason: "time limit reached")
      _ = contextSink("[Live view] Live vision stopped after its time limit.")
      return
    }
    guard isVoiceActive() else {
      stop(reason: "conversation ended")
      return
    }
    let orchestrator = AssistantOrchestrator.shared
    let source: FrameSourceKind
    switch orchestrator.captureSource() {
    case .off:
      status = .paused("camera off")
      return
    case .glasses: source = .glasses
    case .iPhoneCamera: source = .iPhone
    }
    let device = UIDevice.current
    guard let interval = LiveVisionPolicy.interval(
      thermal: ProcessInfo.processInfo.thermalState,
      batteryLevel: device.batteryLevel,
      charging: device.batteryState == .charging || device.batteryState == .full) else {
      status = .paused("phone too warm")
      return
    }
    let frames = FrameStore.shared.recentFrames(source: source, maxAge: AssistantOrchestrator.maxFrameAge)
    guard let newest = frames.last else {
      status = .paused("waiting for camera")
      return
    }
    if case .paused = status { status = .watching }
    let now = CACurrentMediaTime()
    let sinceLast = lastSentAt.map { now - $0 }
    // Cheap early exits before measuring anything.
    if let sinceLast, sinceLast < interval { return }
    if let nextCheckAt, now < nextCheckAt { return }

    inFlight = true
    defer { inFlight = false }
    // Change detection looks at the newest frame only.
    let newestBuffer = newest.pixelBuffer
    let newestMetrics = await Task.detached(priority: .utility) {
      FrameQuality.measure(newestBuffer)
    }.value
    let thumbnail = newestMetrics?.thumbnail
    var difference: Double?
    if let thumbnail, let lastThumbnail {
      difference = FrameQuality.sceneDifference(thumbnail, lastThumbnail)
    }
    guard LiveVisionPolicy.shouldUpdate(sceneDifference: difference, sinceLast: sinceLast, interval: interval) else {
      skippedStable += 1
      nextCheckAt = CACurrentMediaTime() + 1
      return
    }
    // A note will be sent: use the best recent frame of the current view.
    let candidates = frames
    let maxAge = AssistantOrchestrator.maxFrameAge
    let selection = await Task.detached(priority: .utility) {
      FrameSelector.select(from: candidates, maxAge: maxAge)
    }.value
    let chosen = selection?.frame ?? newest
    status = .describing
    do {
      let summary = try await orchestrator.describeLiveView(chosen)
      guard isActive else { return }
      lastThumbnail = thumbnail
      lastSentAt = CACurrentMediaTime()
      lastSummary = summary
      lastUpdateAt = Date()
      updateCount += 1
      lastError = nil
      let time = Date().formatted(date: .omitted, time: .standard)
      if !contextSink("[Live view \(time)] \(summary)") {
        lastError = "voice session did not accept the note"
      }
      status = .watching
    } catch {
      lastError = LogSanitizer.sanitize(error.localizedDescription, limit: 140)
      // Back off after a failure instead of retrying every tick.
      lastSentAt = CACurrentMediaTime()
      status = .watching
    }
  }
}
