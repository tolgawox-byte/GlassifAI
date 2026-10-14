import Combine
import Foundation
import MWDATCore

enum GlassesGestureAction: Equatable {
  case toggleMicrophoneMute
  case endCall
}

/// Turns device-session transitions into call controls. DAT exposes session
/// states rather than raw gesture events:
/// - started → paused or paused → started: temple tap, toggle microphone mute
/// - an active session → stopped: long press, doff, fold or link loss, end call
///
/// A stop this app caused (switching the camera, a recovery, a new transport)
/// is not the wearer's and never ends the call.
struct GlassesGestureInterpreter {
  private(set) var previousState: DeviceSessionState?
  private var becameActive = false

  mutating func receive(_ state: DeviceSessionState, byApp: Bool = false) -> GlassesGestureAction? {
    let previous = previousState
    previousState = state

    switch state {
    case .started:
      becameActive = true
      return previous == .paused ? .toggleMicrophoneMute : nil
    case .paused:
      return previous == .started ? .toggleMicrophoneMute : nil
    case .stopped:
      guard becameActive else { return nil }
      becameActive = false
      return byApp ? nil : .endCall
    case .idle, .starting, .stopping:
      return nil
    }
  }

  mutating func reset() {
    previousState = nil
    becameActive = false
  }

  /// Starts from the session's current state: in a call that begins with
  /// the camera running, the first temple tap mutes and a fold ends the call.
  mutating func seed(_ state: DeviceSessionState?) {
    previousState = state
    becameActive = state == .started || state == .paused
  }
}

/// Meta's fixed temple gestures as call controls during a voice call.
///
/// DAT 1.0 allows one `DeviceSession` per pair of glasses, so this no longer
/// runs a session of its own (as it did on DAT 0.5.0): it follows the
/// camera's session, whose changes the stream view model publishes. `stopped`
/// carries no reason, so the wearer's stop cases cannot be told apart.
@MainActor
final class GlassesGestureSession {
  private let events: AnyPublisher<GlassesSessionEvent?, Never>
  private var subscription: AnyCancellable?
  private var interpreter = GlassesGestureInterpreter()
  private var onTap: (() -> Void)?
  private var onStop: (() -> Void)?

  init(events: AnyPublisher<GlassesSessionEvent?, Never>) {
    self.events = events
  }

  func start(
    deviceId: DeviceIdentifier,
    current: DeviceSessionState? = nil,
    onTap: @escaping () -> Void,
    onStop: @escaping () -> Void
  ) async {
    self.onTap = onTap
    self.onStop = onStop
    guard subscription == nil else { return }
    interpreter.reset()
    interpreter.seed(current)
    // Only changes from now on: an old event must not toggle the microphone.
    subscription = events
      .dropFirst()
      .compactMap { $0 }
      .removeDuplicates()
      .sink { [weak self] event in
        self?.receive(event)
      }
    NSLog("[GlassifAI] glasses gestures follow the camera session")
  }

  func stop() async {
    subscription?.cancel()
    subscription = nil
    interpreter.reset()
    onTap = nil
    onStop = nil
  }

  private func receive(_ event: GlassesSessionEvent) {
    let previous = interpreter.previousState
    NSLog(
      "[GlassifAI] glasses gesture state: %@ -> %@%@",
      previous?.description ?? "none",
      event.state.description,
      event.byApp ? " (app)" : "")
    switch interpreter.receive(event.state, byApp: event.byApp) {
    case .toggleMicrophoneMute:
      onTap?()
    case .endCall:
      onStop?()
    case nil:
      break
    }
  }
}
