import Foundation

/// What the assistant knows about "now": the vehicle, person, place,
/// product and document being talked about, the open task, a running
/// recording, the mode, the last action and answer, the camera and the
/// connected providers. It makes "bunu", "ona", "o araç", "az önceki",
/// "buraya" resolvable, feeds the context chips on screen, the command lab
/// and the on-device model. Built from the stores on demand; nothing new is
/// stored.
@MainActor
enum JarvisSession {
  struct Snapshot: Equatable {
    var vehicle: String?
    /// The active Dealer Mode vehicle, when there is one.
    var vehicleID: UUID?
    var person: String?
    var place: String?
    var product: String?
    var document: String?
    var task: String?
    /// "Kayıt 01:42" while recording.
    var recording: String?
    var mode: AssistantMode
    var recentAction: String?
    var recentAnswer: String?
    var cameraSource: CaptureSource
    var providers: [String]
    var liveVision: Bool
    var remoteAssist: Bool
    var timer: String?
    /// The opt-in Scene Timeline is recording lines of text.
    var sceneTimeline = false

    /// Short labels for the context chips ("Honda Civic", "Canlı görüş"…).
    var chips: [String] {
      var chips: [String] = []
      if let vehicle { chips.append(vehicle) }
      if let recording { chips.append(recording) }
      if liveVision { chips.append(L.t("Live Vision", "Canlı görüş")) }
      if remoteAssist { chips.append(L.t("Sharing view", "Görüntü paylaşılıyor")) }
      if let timer { chips.append(timer) }
      if sceneTimeline { chips.append(L.t("Scene Timeline", "Sahne zaman çizelgesi")) }
      return chips
    }

    /// One line for a model's context: names only, no note or message text.
    var contextLine: String {
      var parts: [String] = ["Mode: \(mode.rawValue)."]
      if let vehicle { parts.append("Current vehicle: \(vehicle).") }
      if let person { parts.append("Current person: \(person).") }
      if let place { parts.append("Current place: \(place).") }
      if let product { parts.append("Current product: \(product).") }
      if let document { parts.append("Current document: \(document).") }
      if let task { parts.append("Newest open task: \(task).") }
      if recording != nil { parts.append("A Ray-Ban video recording is running.") }
      if liveVision { parts.append("Live Vision is on.") }
      if remoteAssist { parts.append("The user's view is being shared (Remote Assist).") }
      if sceneTimeline { parts.append("Scene Timeline is on (text lines only).") }
      if let recentAction { parts.append("Last action: \(recentAction).") }
      parts.append("Camera: \(cameraSource.rawValue).")
      return parts.joined(separator: " ")
    }
  }

  static func snapshot(now: Date = Date()) -> Snapshot {
    let entities = EntityContext.shared
    let dealer = DealerStore.shared.active
    let orchestrator = AssistantOrchestrator.shared
    let media = RayBanMediaCoordinator.shared
    var recording: String?
    if media.isRecording, let elapsed = media.elapsed {
      recording = L.t("Recording ", "Kayıt ") + RecordingChip.clock(elapsed)
    }
    var timer: String?
    if let first = TimerCenter.shared.timers.first {
      timer = "⏱ " + RecordingChip.clock(first.remaining(now: now))
    }
    let lastTrace = ActionTraceLog.shared.entries.last
    let answer = orchestrator.context.turns.last(where: { $0.role == .assistant })?.text
    let providers = ProviderID.allCases.filter { ProviderRegistry.shared.isConnected($0) }.map(\.displayName)
    return Snapshot(
      vehicle: dealer?.title ?? entities.current(.vehicle, now: now)?.name,
      vehicleID: dealer?.id,
      person: entities.current(.person, now: now)?.name ?? orchestrator.recentContact.flatMap {
        now.timeIntervalSince($0.at) < 600 ? $0.name : nil
      },
      place: entities.current(.place, now: now)?.name,
      product: entities.current(.product, now: now)?.name,
      document: entities.current(.document, now: now)?.name,
      task: MemoryStore.shared.tasks.first(where: { !$0.completed })?.title,
      recording: recording,
      mode: AssistantMode.effective,
      recentAction: lastTrace.map { "\($0.canonical) (\($0.result))" },
      recentAnswer: answer.map { String($0.prefix(160)) },
      cameraSource: CaptureSource(rawValue: UserDefaults.standard.string(forKey: CaptureSource.defaultsKey) ?? "")
        ?? .iPhoneCamera,
      providers: providers,
      liveVision: LiveVisionController.shared.isActive,
      remoteAssist: MediaResourceCoordinator.shared.isActive(.remoteAssist),
      timer: timer,
      sceneTimeline: SceneTimeline.isEnabled && LiveVisionController.shared.isActive)
  }
}
