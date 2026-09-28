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
struct GlassesGestureInterpreter {
  private(set) var previousState: DeviceSessionState?
  private var becameActive = false

  mutating func receive(_ state: DeviceSessionState) -> GlassesGestureAction? {
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
      return .endCall
    case .idle, .starting, .stopping:
      return nil
    }
  }

  mutating func reset() {
    previousState = nil
    becameActive = false
  }
}

/// Meta's fixed temple gestures as call controls during a voice call.
///
/// DAT 1.0 allows one `DeviceSession` per pair of glasses, so this no longer
/// runs a session of its own (as it did on 0.5.0): it follows the camera's
/// session, whose state the stream view model publishes. `stopped` carries no
/// reason, so the stop cases cannot be told apart; the app's own teardown is
/// ignored explicitly.
@MainActor
final class GlassesGestureSession {
  private let states: AnyPublisher<DeviceSessionState, Never>
  private var subscription: AnyCancellable?
  private var interpreter = GlassesGestureInterpreter()
  private var onTap: (() -> Void)?
  private var onStop: (() -> Void)?

  init(states: AnyPublisher<DeviceSessionState, Never>) {
    self.states = states
  }

  func start(
    deviceId: DeviceIdentifier,
    onTap: @escaping () -> Void,
    onStop: @escaping () -> Void
  ) async {
    self.onTap = onTap
    self.onStop = onStop
    guard subscription == nil else { return }
    interpreter.reset()
    subscription = states
      .removeDuplicates()
      .sink { [weak self] state in
        self?.receive(state)
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

  private func receive(_ state: DeviceSessionState) {
    let previous = interpreter.previousState
    NSLog(
      "[GlassifAI] glasses gesture state: %@ -> %@",
      previous?.description ?? "none",
      state.description)
    switch interpreter.receive(state) {
    case .toggleMicrophoneMute:
      onTap?()
    case .endCall:
      onStop?()
    case nil:
      break
    }
  }
}
