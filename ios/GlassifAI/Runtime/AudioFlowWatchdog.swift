import AVFoundation
import Foundation

/// The audio session as it really is after WebRTC started its audio unit
/// (WebRTC re-applies its own configuration then), for diagnostics.
enum EffectiveAudioSession {
  static func describe(
    category: String,
    mode: String,
    options: AVAudioSession.CategoryOptions,
    sampleRate: Double,
    ioBufferDuration: TimeInterval
  ) -> String {
    let rate = Int(sampleRate.rounded())
    let buffer = Int((ioBufferDuration * 1_000).rounded())
    return "\(short(category, prefix: "AVAudioSessionCategory"))/\(short(mode, prefix: "AVAudioSessionMode"))"
      + " options \(optionNames(options)) \(rate) Hz \(buffer) ms"
  }

  static func optionNames(_ options: AVAudioSession.CategoryOptions) -> String {
    let known: [(AVAudioSession.CategoryOptions, String)] = [
      (.mixWithOthers, "mixWithOthers"),
      (.duckOthers, "duckOthers"),
      (.allowBluetoothHFP, "allowBluetoothHFP"),
      (.defaultToSpeaker, "defaultToSpeaker"),
      (.interruptSpokenAudioAndMixWithOthers, "interruptSpokenAudio"),
      (.allowBluetoothA2DP, "allowBluetoothA2DP"),
      (.allowAirPlay, "allowAirPlay"),
    ]
    let names = known.filter { options.contains($0.0) }.map { $0.1 }
    return names.isEmpty ? "none" : names.joined(separator: ",")
  }

  @MainActor
  static func current() -> String {
    let session = AVAudioSession.sharedInstance()
    return describe(
      category: session.category.rawValue,
      mode: session.mode.rawValue,
      options: session.categoryOptions,
      sampleRate: session.sampleRate,
      ioBufferDuration: session.ioBufferDuration)
  }

  private static func short(_ name: String, prefix: String) -> String {
    name.hasPrefix(prefix) ? String(name.dropFirst(prefix.count)) : name
  }
}

/// After a conversation becomes ready, checks that audio really flows: the
/// microphone delivers samples, the phone sends audio packets, and the
/// assistant's packets arrive while it is speaking. WebRTC can report a
/// connected call while one of these is stuck (a Bluetooth route that never
/// opened, an audio unit that did not start), which the user only hears as
/// silence. Pure functions, so the decision can be unit tested; the session
/// supplies the statistics.
enum AudioFlowWatchdog {
  /// Cumulative audio counters from one WebRTC statistics report. nil when the
  /// report did not carry the counter (nothing is judged from a missing one).
  struct Snapshot: Equatable, Sendable {
    /// `outbound-rtp` (audio) `packetsSent`.
    var packetsSent: Int?
    /// `inbound-rtp` (audio) `packetsReceived`.
    var packetsReceived: Int?
    /// `media-source` (audio) `totalSamplesDuration`: seconds of captured audio.
    var capturedSeconds: Double?
  }

  enum Verdict: String, Equatable {
    case flowing
    /// The microphone delivered (almost) no audio during the check.
    case microphoneSilent = "microphone delivered no audio"
    /// Captured audio did not leave the phone.
    case notSending = "no audio packets sent"
    /// The assistant was speaking, but none of its audio arrived.
    case notReceiving = "no audio packets received while the assistant spoke"
    /// The statistics lacked the counters: nothing can be said.
    case unknown

    var isProblem: Bool {
      switch self {
      case .microphoneSilent, .notSending, .notReceiving: true
      case .flowing, .unknown: false
      }
    }
  }

  /// The first statistics are read this long after Ready…
  static let settleSeconds: TimeInterval = 1
  /// …and the second this long after the first.
  static let windowSeconds: TimeInterval = 4
  /// The assistant must have been speaking at least this long in the window
  /// before missing audio counts (its words can arrive before its audio).
  static let minimumSpeakingSeconds: TimeInterval = 1

  /// - Parameters:
  ///   - elapsed: seconds between the two snapshots.
  ///   - microphoneMuted: the user muted the microphone at any time in the
  ///     window (a muted track is not judged).
  ///   - assistantSpokeSeconds: how long the session showed the assistant
  ///     speaking during the window.
  static func verdict(
    first: Snapshot,
    second: Snapshot,
    elapsed: TimeInterval,
    microphoneMuted: Bool,
    assistantSpokeSeconds: TimeInterval
  ) -> Verdict {
    var judged = false
    if !microphoneMuted {
      if let before = first.capturedSeconds, let after = second.capturedSeconds {
        judged = true
        // A running microphone captures about as many seconds as pass.
        if after - before < elapsed * 0.25 { return .microphoneSilent }
      }
      if let before = first.packetsSent, let after = second.packetsSent {
        judged = true
        // Opus sends 50 packets a second (a few even when silent with DTX).
        if after <= before { return .notSending }
      }
    }
    if assistantSpokeSeconds >= minimumSpeakingSeconds, let received = second.packetsReceived {
      judged = true
      // Whether the service sends audio while the assistant is silent is not
      // documented, so only "nothing at all, although it spoke" counts.
      if received == 0 { return .notReceiving }
    }
    return judged ? .flowing : .unknown
  }

  /// One statistics entry: its `type` and `values` (as WebRTC reports them).
  struct Statistic {
    var type: String
    var values: [String: Any]
  }

  /// Reads the audio counters from a WebRTC statistics report. The video
  /// sender (camera frames) is ignored.
  static func snapshot(from statistics: [Statistic]) -> Snapshot {
    var snapshot = Snapshot()
    for stat in statistics {
      let kind = (stat.values["kind"] as? String) ?? (stat.values["mediaType"] as? String)
      guard kind == "audio" else { continue }
      switch stat.type {
      case "outbound-rtp":
        if let value = number(stat.values["packetsSent"]) {
          snapshot.packetsSent = (snapshot.packetsSent ?? 0) + Int(value)
        }
      case "inbound-rtp":
        if let value = number(stat.values["packetsReceived"]) {
          snapshot.packetsReceived = (snapshot.packetsReceived ?? 0) + Int(value)
        }
      case "media-source":
        if let value = number(stat.values["totalSamplesDuration"]) {
          snapshot.capturedSeconds = max(snapshot.capturedSeconds ?? 0, value)
        }
      default:
        break
      }
    }
    return snapshot
  }

  private static func number(_ value: Any?) -> Double? {
    if let number = value as? NSNumber { return number.doubleValue }
    if let double = value as? Double { return double }
    if let int = value as? Int { return Double(int) }
    return nil
  }

  /// What the user hears. The first time a reconnect follows; after that the
  /// call is left as it is and the details are in Settings → Developer.
  static func spokenText(_ verdict: Verdict, retrying: Bool, turkish: Bool) -> String {
    let problem: String
    switch verdict {
    case .microphoneSilent:
      problem = turkish ? "Mikrofondan ses alınamıyor." : "The microphone is not picking up any audio."
    case .notSending:
      problem = turkish ? "Sesiniz gönderilemiyor." : "Your voice is not getting through."
    case .notReceiving:
      problem = turkish ? "Asistanın sesi gelmiyor." : "The assistant's voice is not arriving."
    case .flowing, .unknown:
      return ""
    }
    let next = retrying
      ? (turkish ? " Bağlantıyı yeniliyorum." : " Reconnecting.")
      : (turkish ? " Ayrıntılar Ayarlar, Geliştirici bölümünde." : " Details are in Settings, Developer.")
    return problem + next
  }
}

/// Resumes a statistics read exactly once: with the counters, or with nil
/// when WebRTC does not answer in time (for example a peer closing).
final class AudioFlowStatisticsRequest: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<AudioFlowWatchdog.Snapshot?, Never>?

  init(_ continuation: CheckedContinuation<AudioFlowWatchdog.Snapshot?, Never>) {
    self.continuation = continuation
  }

  func finish(_ snapshot: AudioFlowWatchdog.Snapshot?) {
    lock.lock()
    let pending = continuation
    continuation = nil
    lock.unlock()
    pending?.resume(returning: snapshot)
  }
}
