import Foundation

/// Who may use the Ray-Ban stream, the camera and the audio session at the
/// same time. Features ask before they start and report when they end, so two
/// features never fight over the DAT stream or `AVAudioSession`. A refusal
/// comes with a short sentence the assistant can say.
@MainActor
final class MediaResourceCoordinator: ObservableObject {
  static let shared = MediaResourceCoordinator()

  enum Activity: String, CaseIterable, Hashable {
    /// The camera stream itself (Ray-Ban or iPhone).
    case cameraStream
    /// AI looks at sampled frames ("bakmaya devam et").
    case liveVision
    /// Continuous sign translation (a Live Vision variant).
    case liveTranslation
    /// The stream is written to a video file.
    case videoRecording
    /// The point of view is shared with a trusted viewer.
    case remoteAssist
    /// Two-way audio with the Remote Assist viewer.
    case remoteAssistAudio
    /// The conversation: owns the microphone and `AVAudioSession`.
    case realtimeVoice
    /// A deliberate still photo.
    case photo
    /// System music playback (the Music app plays it, not this app).
    case music

    var title: String {
      switch self {
      case .cameraStream: L.t("Camera", "Kamera")
      case .liveVision: L.t("Live Vision", "Canlı görüş")
      case .liveTranslation: L.t("Live translation", "Canlı çeviri")
      case .videoRecording: L.t("Recording", "Kayıt")
      case .remoteAssist: L.t("Remote Assist", "Uzaktan yardım")
      case .remoteAssistAudio: L.t("Remote Assist audio", "Uzaktan yardım sesi")
      case .realtimeVoice: L.t("Conversation", "Konuşma")
      case .photo: L.t("Photo", "Fotoğraf")
      case .music: L.t("Music", "Müzik")
      }
    }
  }

  struct Decision: Equatable {
    let allowed: Bool
    /// Why not (for the trace), nil when allowed.
    let reason: String?
    /// What to tell the user when refused.
    let tr: String?
    let en: String?

    static let ok = Decision(allowed: true, reason: nil, tr: nil, en: nil)

    var spoken: String? { tr.map { L.t(en ?? $0, $0) } }
  }

  struct Conflict {
    let pair: Set<Activity>
    let reason: String
    let tr: String
    let en: String
  }

  /// Pairs that cannot run together. Everything else can: frames are fanned
  /// out to vision, recording and sharing from the one stream.
  nonisolated static let conflicts: [Conflict] = [
    Conflict(
      pair: [.remoteAssistAudio, .realtimeVoice], reason: "both need the microphone and the audio route",
      tr: "Uzaktan yardımda sesli görüşme açıkken seni dinleyemem; paylaşım yalnız görüntüyle sürebilir.",
      en: "While Remote Assist has two-way audio I can't listen; sharing can continue with video only."),
    Conflict(
      pair: [.liveVision, .liveTranslation], reason: "both sample frames for the model",
      tr: "Canlı çeviri açıkken canlı görüş ayrıca çalışmaz; biri yeter.",
      en: "Live translation already watches the view; Live Vision can't run at the same time."),
  ]

  /// What must already run for an activity to start.
  nonisolated static let requirements: [Activity: Activity] = [
    .liveVision: .cameraStream,
    .liveTranslation: .cameraStream,
    .videoRecording: .cameraStream,
    .remoteAssist: .cameraStream,
    .remoteAssistAudio: .remoteAssist,
  ]

  @Published private(set) var active: Set<Activity> = []

  /// The decision for starting `activity` while `active` run (pure; tested).
  nonisolated static func decide(_ activity: Activity, active: Set<Activity>) -> Decision {
    if let needed = requirements[activity], !active.contains(needed) {
      return Decision(
        allowed: false, reason: "needs \(needed.rawValue)",
        tr: needed == .cameraStream ? "Önce kameranın açık olması gerekiyor." : "Önce paylaşımın açık olması gerekiyor.",
        en: needed == .cameraStream ? "The camera needs to be on first." : "Sharing needs to be on first.")
    }
    for conflict in conflicts where conflict.pair.contains(activity) {
      let others = conflict.pair.subtracting([activity])
      if !others.isDisjoint(with: active) {
        return Decision(allowed: false, reason: conflict.reason, tr: conflict.tr, en: conflict.en)
      }
    }
    return .ok
  }

  func canStart(_ activity: Activity) -> Decision {
    Self.decide(activity, active: active)
  }

  /// Records the activity when it may start; returns the decision.
  @discardableResult
  func begin(_ activity: Activity) -> Decision {
    let decision = canStart(activity)
    if decision.allowed { active.insert(activity) }
    return decision
  }

  /// Marks the activity as running whatever the table says (the feature
  /// already started, e.g. the stream came up on its own).
  func note(_ activity: Activity, running: Bool) {
    if running { active.insert(activity) } else { end(activity) }
  }

  func end(_ activity: Activity) {
    active.remove(activity)
    // Anything that needed it stops counting too.
    for (dependent, needed) in Self.requirements where needed == activity {
      active.remove(dependent)
    }
  }

  func isActive(_ activity: Activity) -> Bool { active.contains(activity) }

  /// One line for diagnostics and the privacy screen.
  var summary: String {
    let names = Activity.allCases.filter { active.contains($0) }.map(\.title)
    return names.isEmpty ? L.t("Nothing running", "Çalışan bir şey yok") : names.joined(separator: " · ")
  }
}
