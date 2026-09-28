import Foundation
import QuartzCore

/// Microphone and assistant-voice loudness for the orb. The realtime session
/// writes WebRTC's own `audioLevel` statistics about eight times a second;
/// the orb reads a smoothed value every frame without triggering SwiftUI
/// updates (it redraws on its own timeline anyway).
final class AudioLevelMeter: @unchecked Sendable {
  static let shared = AudioLevelMeter()

  enum Channel { case input, output }

  private let lock = NSLock()
  private var targets: [Channel: Double] = [.input: 0, .output: 0]
  private var values: [Channel: Double] = [.input: 0, .output: 0]
  private var lastRead: [Channel: CFTimeInterval] = [:]
  private var updatedAt: CFTimeInterval = 0

  /// WebRTC reports linear levels from 0 to 1; speech mostly sits between
  /// 0.01 and 0.3, so the square root spreads it over the display range.
  static func displayLevel(_ raw: Double) -> Double {
    min(1, sqrt(max(0, raw)) * 1.4)
  }

  func update(input: Double?, output: Double?) {
    lock.lock()
    defer { lock.unlock() }
    if let input { targets[.input] = Self.displayLevel(input) }
    if let output { targets[.output] = Self.displayLevel(output) }
    updatedAt = CACurrentMediaTime()
  }

  func reset() {
    lock.lock()
    defer { lock.unlock() }
    targets = [.input: 0, .output: 0]
    updatedAt = 0
  }

  /// A smoothed level: quick to rise, slower to fall, and back to zero when
  /// no sample arrived for a second.
  func level(_ channel: Channel, now: CFTimeInterval = CACurrentMediaTime()) -> Double {
    lock.lock()
    defer { lock.unlock() }
    let target = now - updatedAt > 1 ? 0 : targets[channel, default: 0]
    let current = values[channel, default: 0]
    let elapsed = min(0.25, max(0, now - (lastRead[channel] ?? now)))
    lastRead[channel] = now
    let rate = target > current ? 18.0 : 5.0
    let next = current + (target - current) * (1 - exp(-rate * elapsed))
    values[channel] = next
    return next
  }
}
