import AVFoundation
import Foundation
import XCTest

@testable import GlassifAI

/// JARVIS plan 1.6: after Ready the app checks that audio really flows.
final class AutoLoomRealtimeReliabilityTests: XCTestCase {
  private typealias Snapshot = AudioFlowWatchdog.Snapshot

  private func verdict(
    _ first: Snapshot, _ second: Snapshot, muted: Bool = false, spoke: TimeInterval = 0
  ) -> AudioFlowWatchdog.Verdict {
    AudioFlowWatchdog.verdict(
      first: first, second: second, elapsed: 4, microphoneMuted: muted, assistantSpokeSeconds: spoke)
  }

  func testFlowingAudioPassesAndEachStuckDirectionIsNamed() {
    let first = Snapshot(packetsSent: 50, packetsReceived: 40, capturedSeconds: 1.0)
    let healthy = Snapshot(packetsSent: 250, packetsReceived: 240, capturedSeconds: 5.0)
    XCTAssertEqual(verdict(first, healthy, spoke: 2), .flowing)

    // The microphone captured almost nothing in four seconds.
    XCTAssertEqual(verdict(first, Snapshot(packetsSent: 250, packetsReceived: 240, capturedSeconds: 1.2)),
                   .microphoneSilent)
    // Captured, but no packet left the phone.
    XCTAssertEqual(verdict(first, Snapshot(packetsSent: 50, packetsReceived: 240, capturedSeconds: 5.0)),
                   .notSending)
    // The assistant spoke for two seconds and not one packet ever arrived.
    let nothingIn = Snapshot(packetsSent: 0, packetsReceived: 0, capturedSeconds: 1.0)
    XCTAssertEqual(verdict(nothingIn, Snapshot(packetsSent: 200, packetsReceived: 0, capturedSeconds: 5.0), spoke: 2),
                   .notReceiving)
  }

  func testTheWatchdogDoesNotGuess() {
    let first = Snapshot(packetsSent: 50, packetsReceived: 0, capturedSeconds: 1.0)
    let quietAssistant = Snapshot(packetsSent: 250, packetsReceived: 0, capturedSeconds: 5.0)
    // Whether the service sends audio while silent is not documented: an
    // assistant that has not spoken proves nothing about the downlink.
    XCTAssertEqual(verdict(first, quietAssistant, spoke: 0), .flowing)
    // Its words can arrive before its audio: a brief moment is not enough.
    XCTAssertEqual(verdict(first, quietAssistant, spoke: 0.5), .flowing)
    // A muted microphone is not judged (and a silent assistant proves nothing).
    XCTAssertEqual(verdict(first, Snapshot(packetsSent: 50, packetsReceived: 0, capturedSeconds: 1.0), muted: true),
                   .unknown)
    // No counters at all: unknown, which triggers nothing.
    XCTAssertEqual(verdict(Snapshot(), Snapshot()), .unknown)
    XCTAssertFalse(AudioFlowWatchdog.Verdict.unknown.isProblem)
    XCTAssertFalse(AudioFlowWatchdog.Verdict.flowing.isProblem)
    XCTAssertTrue(AudioFlowWatchdog.Verdict.notReceiving.isProblem)
  }

  func testOnlyAudioCountersAreReadFromTheStatistics() {
    let snapshot = AudioFlowWatchdog.snapshot(from: [
      .init(type: "outbound-rtp", values: ["kind": "audio", "packetsSent": NSNumber(value: 120)]),
      // The camera's video sender must not count as audio.
      .init(type: "outbound-rtp", values: ["kind": "video", "packetsSent": NSNumber(value: 9_000)]),
      .init(type: "inbound-rtp", values: ["kind": "audio", "packetsReceived": NSNumber(value: 80)]),
      .init(type: "media-source", values: ["kind": "audio", "totalSamplesDuration": NSNumber(value: 2.5)]),
      .init(type: "media-source", values: ["kind": "video", "frames": NSNumber(value: 30)]),
      .init(type: "transport", values: ["bytesSent": NSNumber(value: 1)]),
    ])
    XCTAssertEqual(snapshot, Snapshot(packetsSent: 120, packetsReceived: 80, capturedSeconds: 2.5))
    XCTAssertEqual(AudioFlowWatchdog.snapshot(from: []), Snapshot())
  }

  /// Plan 1.7: the diagnostics show whether WebRTC dropped the app's options.
  func testTheEffectiveAudioSessionNamesEveryOption() {
    let line = EffectiveAudioSession.describe(
      category: AVAudioSession.Category.playAndRecord.rawValue,
      mode: AVAudioSession.Mode.voiceChat.rawValue,
      options: [.allowBluetoothHFP, .mixWithOthers, .defaultToSpeaker],
      sampleRate: 48_000,
      ioBufferDuration: 0.02)
    XCTAssertEqual(line, "PlayAndRecord/VoiceChat options mixWithOthers,allowBluetoothHFP,defaultToSpeaker 48000 Hz 20 ms")
    // WebRTC's own iOS 26 default would show up as HFP only.
    XCTAssertEqual(EffectiveAudioSession.optionNames([.allowBluetoothHFP]), "allowBluetoothHFP")
    XCTAssertEqual(EffectiveAudioSession.optionNames([]), "none")
  }

  func testTheExplanationIsSpokenOnlyForRealProblems() {
    XCTAssertTrue(AudioFlowWatchdog.spokenText(.microphoneSilent, retrying: true, turkish: true).contains("yeniliyorum"))
    XCTAssertTrue(AudioFlowWatchdog.spokenText(.notReceiving, retrying: false, turkish: false).contains("Settings"))
    XCTAssertEqual(AudioFlowWatchdog.spokenText(.flowing, retrying: true, turkish: true), "")
    XCTAssertEqual(AudioFlowWatchdog.spokenText(.unknown, retrying: true, turkish: false), "")
  }
}
